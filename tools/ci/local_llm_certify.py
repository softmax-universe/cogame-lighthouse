#!/usr/bin/env python3
"""Deterministic local HTTP LLM fixture for credential-free certification.

The published manifest (dist/coworld_manifest.json) declares
COWORLD_LLM_ENABLED=true and COWORLD_LLM_MODEL, never a local endpoint.
This helper starts an ephemeral local Anthropic Messages (/v1/messages)
server, injects COWORLD_LLM_ENDPOINT only into a temporary certification copy
of the manifest, runs the certification command, and asserts that the model
player actually made HTTP /v1/messages calls with its configured model.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def docker_host_for_containers() -> str:
    if sys.platform == "darwin":
        return "host.docker.internal"
    try:
        out = subprocess.check_output(
            [
                "docker",
                "network",
                "inspect",
                "bridge",
                "--format",
                "{{(index .IPAM.Config 0).Gateway}}",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return "172.17.0.1"


def make_handler(calls: list[dict], calls_log: Path | None = None):
    lock = threading.Lock()

    class FixtureHandler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            body = json.loads(raw.decode("utf-8"))
            slot = self.headers.get("X-Coworld-Player-Slot", "")
            model = body.get("model", "")
            messages = body.get("messages") or []
            user_text = ""
            if messages and isinstance(messages[0], dict):
                user_text = str(messages[0].get("content", ""))

            if self.path != "/v1/messages":
                self.send_response(404)
                self.end_headers()
                return

            if "You are the KEEPER." in user_text or slot == "0":
                reply_text = json.dumps(
                    {"transmit": False, "message": "", "notes": "local-certify-fixture"}
                )
            else:
                reply_text = json.dumps(
                    {"move": "WAIT", "notes": "local-certify-fixture"}
                )

            record = {"path": self.path, "slot": slot, "model": model}
            with lock:
                calls.append(record)
                if calls_log is not None:
                    with calls_log.open("a", encoding="utf-8") as fh:
                        fh.write(json.dumps(record) + "\n")

            payload = {
                "id": f"msg_local_{len(calls)}",
                "type": "message",
                "role": "assistant",
                "model": model,
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": reply_text}],
            }
            data = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_args: object) -> None:
            pass

    return FixtureHandler


def serve_only(state_path: Path) -> int:
    calls: list[dict] = []
    calls_log = Path(f"{state_path}.calls.jsonl")
    server = ThreadingHTTPServer(("0.0.0.0", 0), make_handler(calls, calls_log))
    port = server.server_port
    host = docker_host_for_containers()
    info = {
        "host": host,
        "port": port,
        "url": f"http://{host}:{port}",
        "docker_internal_url": f"http://host.docker.internal:{port}",
        "calls_log": str(calls_log),
    }
    tmp = state_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(info), encoding="utf-8")
    tmp.replace(state_path)

    def _stop(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


def run_certify(manifest_path: Path, cmd_template: list[str]) -> int:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    players = manifest.get("player") or []
    by_id = {p.get("id"): p for p in players if isinstance(p, dict)}

    expected_models: set[str] = set()
    for p in players:
        env = p.get("env") or {}
        if "COWORLD_LLM_ENDPOINT" in env:
            raise SystemExit(
                f"FAIL: published manifest player {p.get('id')!r} must NOT set COWORLD_LLM_ENDPOINT"
            )
        if env.get("COWORLD_LLM_ENABLED") == "true":
            model = (env.get("COWORLD_LLM_MODEL") or "").strip()
            if not model:
                raise SystemExit(
                    f"FAIL: model player {p.get('id')!r} must set COWORLD_LLM_MODEL"
                )
            expected_models.add(model)

    if not expected_models:
        raise SystemExit(
            "FAIL: manifest must declare at least one model player with COWORLD_LLM_ENABLED=true"
        )

    cert_players = (manifest.get("certification") or {}).get("players") or []
    seated_model = any(
        (by_id.get(cp.get("player_id"), {}).get("env") or {}).get("COWORLD_LLM_ENABLED")
        == "true"
        for cp in cert_players
    )
    seated_scripted = any(
        bool(
            (by_id.get(cp.get("player_id"), {}).get("env") or {}).get("PLAYER_SCRIPTED")
        )
        for cp in cert_players
    )
    if not (seated_model and seated_scripted):
        raise SystemExit(
            "FAIL: certification.players must explicitly seat both a model player and scripted baselines"
        )

    calls: list[dict] = []
    server = ThreadingHTTPServer(("0.0.0.0", 0), make_handler(calls))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host = docker_host_for_containers()
    endpoint = f"http://{host}:{server.server_port}"

    try:
        with tempfile.TemporaryDirectory(prefix="lighthouse-certify-") as tmpdir:
            temp_manifest_path = Path(tmpdir) / "coworld_manifest.json"
            temp_manifest = json.loads(json.dumps(manifest))
            for p in temp_manifest.get("player") or []:
                env = p.setdefault("env", {})
                if env.get("COWORLD_LLM_ENABLED") == "true":
                    env["COWORLD_LLM_ENDPOINT"] = endpoint
            temp_manifest_path.write_text(
                json.dumps(temp_manifest, indent=2), encoding="utf-8"
            )

            cmd = [
                str(temp_manifest_path) if token == "{MANIFEST}" else token
                for token in cmd_template
            ]
            if "{MANIFEST}" not in cmd_template:
                cmd.append(str(temp_manifest_path))

            proc = subprocess.run(cmd, env=os.environ.copy())
            if proc.returncode != 0:
                return proc.returncode
    finally:
        server.shutdown()
        server.server_close()

    if not calls:
        print(
            "FAIL: local_llm_certify recorded 0 HTTP /v1/messages calls; model player did not invoke LLM endpoint",
            file=sys.stderr,
        )
        return 1

    seen_models = {c["model"] for c in calls}
    if not seen_models.intersection(expected_models):
        print(
            f"FAIL: expected model in {sorted(expected_models)}, saw {sorted(seen_models)}",
            file=sys.stderr,
        )
        return 1

    seen_slots = sorted({c["slot"] for c in calls})
    print(
        f"local_llm_certify: verified {len(calls)} HTTP /v1/messages calls "
        f"(models={sorted(seen_models)}, slots={seen_slots}); published manifest untouched"
    )
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--serve-only":
        return serve_only(Path(sys.argv[2]))
    if "--" not in sys.argv or len(sys.argv) < 4:
        raise SystemExit(
            "Usage:\n"
            "  local_llm_certify.py <manifest.json> -- <command... {MANIFEST} ...>\n"
            "  local_llm_certify.py --serve-only <state.json>"
        )
    sep = sys.argv.index("--")
    manifest_path = Path(sys.argv[1])
    cmd = sys.argv[sep + 1 :]
    return run_certify(manifest_path, cmd)


if __name__ == "__main__":
    raise SystemExit(main())
