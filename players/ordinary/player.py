"""Lighthouse decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import baseline, prompts
from prompt_selection import BANK, PromptSelection


def _try_parse_json_object(candidate: str) -> dict | None:
    s = candidate.strip()
    if not (s.startswith("{") and s.endswith("}")):
        return None
    try:
        parsed = json.loads(s)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _contains_json_object(text: str) -> bool:
    decoder = json.JSONDecoder()
    idx = 0
    while True:
        pos = text.find("{", idx)
        if pos < 0:
            return False
        try:
            obj, _ = decoder.raw_decode(text, pos)
            if isinstance(obj, dict):
                return True
        except ValueError:
            pass
        idx = pos + 1


def parse_json_object(text: str) -> dict:
    trimmed = text.strip()
    if not trimmed:
        raise ValueError("empty response")

    bare = _try_parse_json_object(trimmed)
    if bare is not None:
        return bare

    blocks: list[tuple[str, str]] = []
    outside_parts: list[str] = []
    pos = 0
    last_close_end = 0
    while True:
        open_idx = trimmed.find("```", pos)
        if open_idx < 0:
            outside_parts.append(trimmed[pos:])
            break
        outside_parts.append(trimmed[pos:open_idx])
        outside_parts.append("\n")
        close_idx = trimmed.find("```", open_idx + 3)
        if close_idx < 0:
            raise ValueError("incomplete markdown code fence")
        raw_block = trimmed[open_idx + 3 : close_idx]
        nl = raw_block.find("\n")
        if nl >= 0:
            header = raw_block[:nl].strip()
            header_lower = header.lower()
            if not header:
                lang, body = "", raw_block[nl + 1 :].strip()
            elif header_lower == "json":
                lang, body = "json", raw_block[nl + 1 :].strip()
            elif header.startswith("{"):
                lang, body = "", raw_block.strip()
            elif header_lower.startswith("json") and (
                len(header_lower) == 4 or header_lower[4] in (" ", "\t")
            ):
                lang, body = "json", raw_block.strip()[4:].strip()
            else:
                lang, body = header_lower, raw_block[nl + 1 :].strip()
        else:
            single = raw_block.strip()
            single_lower = single.lower()
            if single.startswith("{"):
                lang, body = "", single
            elif single_lower.startswith("json") and (
                len(single_lower) == 4 or single_lower[4] in (" ", "\t")
            ):
                lang, body = "json", single[4:].strip()
            else:
                lang, body = single_lower, ""
        blocks.append((lang, body))
        pos = close_idx + 3
        last_close_end = pos

    outside = "".join(outside_parts)
    json_tagged = [body for lang, body in blocks if lang == "json"]
    unmarked_json = [
        parsed
        for lang, body in blocks
        if lang == ""
        for parsed in (_try_parse_json_object(body),)
        if parsed is not None
    ]

    if (
        len(json_tagged) > 1
        or (len(json_tagged) == 1 and unmarked_json)
        or len(unmarked_json) > 1
    ):
        raise ValueError("multiple competing JSON blocks")

    if len(json_tagged) == 1:
        if _contains_json_object(outside):
            raise ValueError("multiple competing JSON objects")
        action = json.loads(json_tagged[0])
        if not isinstance(action, dict):
            raise ValueError("trained Lighthouse decision must be a JSON object")
        return action

    if len(unmarked_json) == 1:
        if _contains_json_object(outside):
            raise ValueError("multiple competing JSON objects")
        return unmarked_json[0]

    tail_raw = trimmed[last_close_end:]
    tail = tail_raw.strip()
    if tail.endswith("}"):
        line_start = 0
        while line_start < len(tail):
            trimmed_start = line_start
            while trimmed_start < len(tail) and tail[trimmed_start] in (" ", "\t"):
                trimmed_start += 1
            if trimmed_start < len(tail) and tail[trimmed_start] == "{":
                parsed = _try_parse_json_object(tail[trimmed_start:])
                if parsed is not None:
                    before_final = (
                        outside[: max(0, len(outside) - len(tail_raw))]
                        + tail[:trimmed_start]
                    )
                    if _contains_json_object(before_final):
                        raise ValueError("multiple competing JSON objects")
                    return parsed
            next_nl = tail.find("\n", line_start)
            if next_nl < 0:
                break
            line_start = next_nl + 1

    action = json.loads(trimmed)
    if not isinstance(action, dict):
        raise ValueError("trained Lighthouse decision must be a JSON object")
    return action


def choose(turn: dict, generator, selection: PromptSelection) -> tuple[dict, str]:
    view = turn["view"]
    system, user = prompts(selection, view, os.environ.get("PLAYER_PROMPT", ""))
    if generator:
        completion = generator(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ]
        )
        return parse_json_object(completion), "trained"
    return baseline(view), "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("LIGHTHOUSE_ADAPTER_DIR")
    generator = None
    if adapter:
        from pathlib import Path

        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = (
        Capture(slot, backend)
        if os.environ.get("LIGHTHOUSE_CAPTURE_TRAINING") == "1"
        else None
    )
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict, str]] = {}
    episode_selection: PromptSelection | None = None
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Lighthouse closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            selection = PromptSelection.model_validate(frame["prompt_configuration"])
            if selection.bank != BANK.version:
                raise ValueError("game and player prompt banks differ")
            if episode_selection is not None and selection != episode_selection:
                raise ValueError("prompt selection changed during episode")
            episode_selection = selection
            action, source = choose(frame, generator, selection)
            pending[frame["tick"]] = (frame, action, source)
            socket.send(
                json.dumps(
                    {
                        "type": "decision",
                        "tick": frame["tick"],
                        "source": source,
                        "action": action,
                    }
                )
            )
        elif kind == "decision_result":
            turn, action, source = pending.pop(frame["tick"])
            if not frame["accepted"]:
                raise RuntimeError(f"Lighthouse rejected tick {frame['tick']}")
            if artifact:
                system, user = prompts(
                    PromptSelection.model_validate(turn["prompt_configuration"]),
                    turn["view"],
                    os.environ.get("PLAYER_PROMPT", ""),
                )
                artifact.record(
                    system,
                    user,
                    action,
                    source,
                    frame["tick"],
                    PromptSelection.model_validate(turn["prompt_configuration"]),
                )
        elif kind == "final":
            if pending:
                raise RuntimeError("Lighthouse ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"], frame["reason"])
            break
    socket.close()
    print(
        f"Lighthouse ordinary player finished: slot={slot} backend={backend}",
        flush=True,
    )


if __name__ == "__main__":
    main()
