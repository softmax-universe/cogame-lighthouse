"""One native Lighthouse game with canned, prompt, and scripted player processes."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar


class ModelStub(BaseHTTPRequestHandler):
    calls: ClassVar[list[tuple[str, str]]] = []
    invalid: ClassVar[bool] = False
    briefing: ClassVar[str] = json.loads(
        (
            Path(__file__).resolve().parents[2] / "players/ordinary/prompt_bank.json"
        ).read_text()
    )["briefings"]["reordered"]

    def do_POST(self) -> None:
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        slot = self.headers["X-Coworld-Player-Slot"]
        self.calls.append((self.path, slot))
        assert self.path == "/v1/messages"
        assert self.briefing in request["system"]
        reply = (
            '```json\n{"move":"WAIT","notes":""}\n```'
            if len(self.calls) % 2 == 1
            else '{"move":"WAIT","notes":""}'
        )
        if self.invalid:
            reply = "malformed"
        payload = {"content": [{"type": "text", "text": reply}]}
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args: object) -> None:
        pass


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def verify_model_episode(*, invalid: bool = False) -> None:
    ModelStub.invalid = invalid
    ModelStub.calls.clear()
    game_bin, player_bin = map(Path, sys.argv[1:3])
    game_port = free_port()
    stub = ThreadingHTTPServer(("127.0.0.1", 0), ModelStub)
    stub_url = f"http://127.0.0.1:{stub.server_port}"
    thread = threading.Thread(target=stub.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="lighthouse-mixed-") as temp:
        work = Path(temp)
        config = {
            "promptVariant": "mixed",
            "promptSeed": 4,
            "seed": 7,
            "maxTicks": 6,
            "turnDelayMs": 0,
            "decisionTimeoutSeconds": 5,
            "player_connect_timeout_seconds": 15,
            "episodeTimeoutSeconds": 120,
            "players": [{"name": f"P{seat}"} for seat in range(4)],
            "tokens": [f"t{seat}" for seat in range(4)],
        }
        (work / "config.json").write_text(json.dumps(config))
        game_env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "COWORLD_LLM_ENDPOINT",
        ):
            game_env.pop(key, None)
        game_env.update(
            {
                "COGAME_HOST": "127.0.0.1",
                "COGAME_PORT": str(game_port),
                "COGAME_CONFIG_URI": (work / "config.json").as_uri(),
                "COGAME_RESULTS_URI": (work / "results.json").as_uri(),
                "COGAME_PLAYER_FAILURE_URI": (work / "player_failure.json").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (work / "replay.json").as_uri(),
            }
        )
        processes = []
        logs = []
        try:
            game_log = (work / "game.log").open("w+")
            logs.append(game_log)
            game = subprocess.Popen(
                [str(game_bin)], env=game_env, stdout=game_log, stderr=subprocess.STDOUT
            )
            processes.append(game)
            for _ in range(100):
                if game.poll() is not None:
                    raise RuntimeError("game exited before healthz")
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    ready = probe.connect_ex(("127.0.0.1", game_port)) == 0
                if ready:
                    urllib.request.urlopen(
                        f"http://127.0.0.1:{game_port}/healthz", timeout=0.2
                    )
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("game healthz did not start")
            for seat in range(4):
                env = game_env.copy()
                env["COWORLD_PLAYER_WS_URL"] = (
                    f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=t{seat}"
                )
                if seat < 2:
                    env["COWORLD_LLM_ENDPOINT"] = stub_url
                if seat == 0:
                    env["LIGHTHOUSE_CAPTURE_TRAINING"] = "1"
                    env["LIGHTHOUSE_SOURCE_REVISION"] = subprocess.check_output(
                        ["git", "rev-parse", "HEAD"], text=True
                    ).strip()
                    env["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"] = (
                        work / "ordinary.zip"
                    ).as_uri()
                    argv = [
                        sys.executable,
                        str(Path(__file__).parents[2] / "players/ordinary/player.py"),
                    ]
                else:
                    if seat >= 2:
                        env["PLAYER_SCRIPTED"] = "1"
                    argv = [str(player_bin)]
                handle = (work / f"player-{seat}.log").open("w+")
                logs.append(handle)
                processes.append(
                    subprocess.Popen(
                        argv, env=env, stdout=handle, stderr=subprocess.STDOUT
                    )
                )
            if invalid:
                assert game.wait(timeout=60) != 0
                assert ModelStub.calls == [("/v1/messages", "1")]
                assert not (work / "results.json").exists()
                failure = (work / "player_failure.json").read_text()
                assert "could not produce a decision" in failure, failure
                print("malformed model reply: one HTTP call, player failure, no scores")
                return
            assert game.wait(timeout=60) == 0, (work / "game.log").read_text()
            for player in processes[1:]:
                assert player.wait(timeout=10) == 0
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            assert results["ticks"] == 6 and replay["events"]
            with zipfile.ZipFile(work / "ordinary.zip") as archive:
                capture = json.loads(archive.read("trajectory.json"))
            assert capture["complete"] and capture["schema_version"] == 1
            assert len(capture["decisions"]) == 6
            assert all(
                row["prompt_template"]["bank"] == "lighthouse-rules-v3"
                and row["prompt_template"]["variant"] == "reordered"
                for row in capture["decisions"]
            )
            assert (work / "ordinary.zip").stat().st_mode & 0o777 == 0o600
            game_text = (work / "game.log").read_text()
            assert "player failure on slot" not in game_text
            prompt = [call for call in ModelStub.calls if call[0] == "/v1/messages"]
            assert len(prompt) == 6 and all(slot == "1" for _, slot in prompt)
            print(
                "mixed episode: 6 canned, 6 prompt, 12 scripted decisions; zero player failures"
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for handle in logs:
                handle.close()
            stub.shutdown()


def verify_invalid_action_fails_terminally(game_bin: Path, player_bin: Path) -> None:
    """An invalid player action must terminate with player_failure.json and no scores."""
    import websocket

    game_port = free_port()
    with tempfile.TemporaryDirectory(prefix="lighthouse-fail-") as temp:
        work = Path(temp)
        config = {
            "seed": 7,
            "maxTicks": 6,
            "turnDelayMs": 0,
            "decisionTimeoutSeconds": 5,
            "player_connect_timeout_seconds": 15,
            "episodeTimeoutSeconds": 120,
            "players": [{"name": f"P{seat}"} for seat in range(4)],
            "tokens": [f"t{seat}" for seat in range(4)],
        }
        (work / "config.json").write_text(json.dumps(config))
        game_env = os.environ.copy()
        game_env.update(
            {
                "COGAME_HOST": "127.0.0.1",
                "COGAME_PORT": str(game_port),
                "COGAME_CONFIG_URI": (work / "config.json").as_uri(),
                "COGAME_RESULTS_URI": (work / "results.json").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (work / "replay.json").as_uri(),
                "COGAME_PLAYER_FAILURE_URI": (work / "player_failure.json").as_uri(),
            }
        )
        processes = []
        logs = []
        try:
            game_log = (work / "game.log").open("w+")
            logs.append(game_log)
            game = subprocess.Popen(
                [str(game_bin)], env=game_env, stdout=game_log, stderr=subprocess.STDOUT
            )
            processes.append(game)
            for _ in range(100):
                if game.poll() is not None:
                    raise RuntimeError("game exited before healthz")
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    ready = probe.connect_ex(("127.0.0.1", game_port)) == 0
                if ready:
                    urllib.request.urlopen(
                        f"http://127.0.0.1:{game_port}/healthz", timeout=0.2
                    )
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("game healthz did not start")
            for seat in (0, 2, 3):
                env = game_env.copy()
                env["COWORLD_PLAYER_WS_URL"] = (
                    f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=t{seat}"
                )
                env["PLAYER_SCRIPTED"] = "1"
                handle = (work / f"player-{seat}.log").open("w+")
                logs.append(handle)
                processes.append(
                    subprocess.Popen(
                        [str(player_bin)],
                        env=env,
                        stdout=handle,
                        stderr=subprocess.STDOUT,
                    )
                )
            bad_ws = websocket.create_connection(
                f"ws://127.0.0.1:{game_port}/player?slot=1&token=t1", timeout=10
            )
            try:
                while True:
                    frame = json.loads(bad_ws.recv())
                    if frame.get("type") == "turn":
                        bad_ws.send(
                            json.dumps(
                                {
                                    "type": "decision",
                                    "tick": frame["tick"],
                                    "source": "player",
                                    "action": {"move": "north", "notes": ""},
                                }
                            )
                        )
                        break
            finally:
                bad_ws.close()
            assert game.wait(timeout=15) != 0
            assert not (work / "results.json").exists()
            failure = json.loads((work / "player_failure.json").read_text())
            assert failure["kind"] == "player_error"
            assert failure["failed_policy_index"] == 1
            assert "not a move token: north" in failure["message"]
            print("terminal failure check: invalid alias rejected with player_error and no scores")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for handle in logs:
                handle.close()


if __name__ == "__main__":
    verify_model_episode()
    verify_model_episode(invalid=True)
    verify_invalid_action_fails_terminally(*map(Path, sys.argv[1:3]))
