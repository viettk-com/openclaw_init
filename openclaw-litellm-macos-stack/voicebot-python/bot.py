#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import requests
except ModuleNotFoundError:  # pragma: no cover - only hit on host-side self-tests without deps installed
    requests = None


SUPPORTED_PHRASES = [
    "trang thai",
    "tro giup",
    "chi phi",
    "token",
    "toi la ai",
    "model hien tai",
]


def log(message: str, *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    print(f"[voicebot] {message}", file=stream, flush=True)


def parse_bool(raw: str | None, default: bool = False) -> bool:
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    return default


def strip_accents(text: str) -> str:
    normalized = unicodedata.normalize("NFD", text)
    return "".join(ch for ch in normalized if unicodedata.category(ch) != "Mn")


def normalize_text(text: str) -> str:
    lowered = strip_accents(text).lower()
    lowered = re.sub(r"[^\w\s/.-]", " ", lowered)
    return re.sub(r"\s+", " ", lowered).strip()


@dataclass(frozen=True)
class Settings:
    telegram_bot_token: str
    telegram_allowlist: set[int]
    openclaw_base_url: str
    openclaw_gateway_token: str
    openclaw_agent_id: str
    openclaw_model: str
    openclaw_session_key_prefix: str
    whisper_infer_url: str
    transcribe_language: str
    forward_unknown_to_chat: bool
    send_transcript_debug: bool
    max_duration_seconds: int
    max_file_bytes: int
    poll_timeout_seconds: int
    transcode_to_wav: bool
    ffmpeg_sample_rate: int
    ffmpeg_channels: int

    @classmethod
    def from_env(cls) -> "Settings":
        allowlist = {
            int(item.strip())
            for item in os.getenv("VOICEBOT_TELEGRAM_ALLOWLIST", "").split(",")
            if item.strip().isdigit()
        }
        return cls(
            telegram_bot_token=os.environ["VOICEBOT_TELEGRAM_BOT_TOKEN"],
            telegram_allowlist=allowlist,
            openclaw_base_url=os.getenv("VOICEBOT_OPENCLAW_BASE_URL", "http://openclaw-gateway:18789").rstrip("/"),
            openclaw_gateway_token=os.environ["VOICEBOT_OPENCLAW_GATEWAY_TOKEN"],
            openclaw_agent_id=os.getenv("VOICEBOT_OPENCLAW_AGENT_ID", "main"),
            openclaw_model=os.getenv("VOICEBOT_OPENCLAW_MODEL", "openclaw:main"),
            openclaw_session_key_prefix=os.getenv("VOICEBOT_OPENCLAW_SESSION_KEY_PREFIX", "voicebot"),
            whisper_infer_url=os.getenv("VOICEBOT_WHISPER_INFER_URL", "http://whisper:8080/inference"),
            transcribe_language=os.getenv("VOICEBOT_TRANSCRIBE_LANGUAGE", "vi"),
            forward_unknown_to_chat=parse_bool(os.getenv("VOICEBOT_FORWARD_UNKNOWN_TO_CHAT"), False),
            send_transcript_debug=parse_bool(os.getenv("VOICEBOT_SEND_TRANSCRIPT_DEBUG"), False),
            max_duration_seconds=int(os.getenv("VOICEBOT_MAX_DURATION_SECONDS", "30")),
            max_file_bytes=int(os.getenv("VOICEBOT_MAX_FILE_BYTES", str(20 * 1024 * 1024))),
            poll_timeout_seconds=int(os.getenv("VOICEBOT_POLL_TIMEOUT_SECONDS", "30")),
            transcode_to_wav=parse_bool(os.getenv("VOICEBOT_TRANSCODE_TO_WAV"), False),
            ffmpeg_sample_rate=int(os.getenv("VOICEBOT_FFMPEG_SAMPLE_RATE", "16000")),
            ffmpeg_channels=int(os.getenv("VOICEBOT_FFMPEG_CHANNELS", "1")),
        )


def http_with_retry(method: str, url: str, *, timeout: int = 30, max_attempts: int = 5, **kwargs: Any) -> requests.Response:
    if requests is None:
        raise RuntimeError("The 'requests' package is required to run the voice bot.")
    last_error: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            response = requests.request(method, url, timeout=timeout, **kwargs)
            if response.status_code == 429:
                retry_after = response.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    time.sleep(int(retry_after))
                else:
                    time.sleep(min(2**attempt, 30))
                continue
            if response.status_code >= 500:
                time.sleep(min(2**attempt, 30))
                continue
            return response
        except Exception as exc:  # pragma: no cover - network failures are environment-driven
            last_error = exc
            time.sleep(min(2**attempt, 30))
    raise RuntimeError(f"HTTP failed after retries for {method} {url}: {last_error}")


def tg_api_url(settings: Settings, suffix: str) -> str:
    return f"https://api.telegram.org/bot{settings.telegram_bot_token}/{suffix.lstrip('/')}"


def tg_file_url(settings: Settings, file_path: str) -> str:
    return f"https://api.telegram.org/file/bot{settings.telegram_bot_token}/{file_path.lstrip('/')}"


def tg_send_message(settings: Settings, chat_id: int, text: str) -> None:
    http_with_retry(
        "POST",
        tg_api_url(settings, "sendMessage"),
        json={"chat_id": chat_id, "text": text[:3500]},
        timeout=30,
    ).raise_for_status()


def tg_send_chat_action(settings: Settings, chat_id: int, action: str = "typing") -> None:
    http_with_retry(
        "POST",
        tg_api_url(settings, "sendChatAction"),
        json={"chat_id": chat_id, "action": action},
        timeout=15,
    ).raise_for_status()


def tg_get_updates(settings: Settings, offset: int | None) -> list[dict[str, Any]]:
    params: dict[str, Any] = {"timeout": settings.poll_timeout_seconds, "allowed_updates": json.dumps(["message"])}
    if offset is not None:
        params["offset"] = offset
    response = http_with_retry("GET", tg_api_url(settings, "getUpdates"), params=params, timeout=settings.poll_timeout_seconds + 5)
    response.raise_for_status()
    payload = response.json()
    if not payload.get("ok"):
        raise RuntimeError(f"getUpdates returned ok=false: {payload}")
    return payload.get("result", [])


def tg_get_file_info(settings: Settings, file_id: str) -> dict[str, Any]:
    response = http_with_retry("GET", tg_api_url(settings, "getFile"), params={"file_id": file_id}, timeout=30)
    response.raise_for_status()
    payload = response.json()
    if not payload.get("ok"):
        raise RuntimeError(f"getFile returned ok=false: {payload}")
    return payload["result"]


def download_file(settings: Settings, file_path: str, destination: Path) -> None:
    response = http_with_retry("GET", tg_file_url(settings, file_path), timeout=60)
    response.raise_for_status()
    destination.write_bytes(response.content)


def ffmpeg_to_wav(input_path: Path, output_path: Path, sample_rate: int, channels: int) -> None:
    command = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(input_path),
        "-ar",
        str(sample_rate),
        "-ac",
        str(channels),
        str(output_path),
    ]
    subprocess.run(command, check=True)


def guess_content_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".ogg", ".oga", ".opus"}:
        return "audio/ogg"
    if suffix == ".wav":
        return "audio/wav"
    if suffix == ".mp3":
        return "audio/mpeg"
    return "application/octet-stream"


def whisper_transcribe(settings: Settings, audio_path: Path) -> str:
    with audio_path.open("rb") as handle:
        files = {"file": (audio_path.name, handle, guess_content_type(audio_path))}
        data = {
            "response_format": "text",
            "language": settings.transcribe_language,
            "temperature": "0.0",
        }
        response = http_with_retry("POST", settings.whisper_infer_url, files=files, data=data, timeout=120)
    response.raise_for_status()
    return response.text.strip()


def validate_intent(intent: dict[str, Any]) -> None:
    if not isinstance(intent.get("intent"), str):
        raise ValueError("intent must be a string")
    if not isinstance(intent.get("confidence"), (int, float)):
        raise ValueError("confidence must be numeric")
    if not isinstance(intent.get("slots"), dict):
        raise ValueError("slots must be a dict")


def parse_intent_vi(text: str) -> dict[str, Any]:
    normalized = normalize_text(text)

    intent_patterns: list[tuple[str, str, float]] = [
        ("status", r"\b(trang thai|tinh trang|status)\b", 0.95),
        ("help", r"\b(tro giup|huong dan|help)\b", 0.95),
        ("usage_cost", r"\b(chi phi|cost)\b", 0.9),
        ("usage_tokens", r"\b(token|tokens|usage)\b", 0.9),
        ("whoami", r"\b(toi la ai|who am i|whoami|id cua toi)\b", 0.9),
        ("model_status", r"\b(model hien tai|mo hinh hien tai|model dang dung|mo hinh dang dung|model)\b", 0.85),
    ]

    for name, pattern, confidence in intent_patterns:
        if re.search(pattern, normalized):
            result = {"intent": name, "confidence": confidence, "slots": {}}
            validate_intent(result)
            return result

    result = {"intent": "chat", "confidence": 0.25, "slots": {"text": text.strip()}}
    validate_intent(result)
    return result


def build_openclaw_prompt(intent: dict[str, Any]) -> str | None:
    mapping = {
        "status": "/status",
        "help": "/help",
        "usage_cost": "/usage cost",
        "usage_tokens": "/usage tokens",
        "whoami": "/whoami",
        "model_status": "/model",
    }
    if intent["intent"] in mapping:
        return mapping[intent["intent"]]
    if intent["intent"] == "chat":
        return str(intent["slots"].get("text", "")).strip() or None
    return None


def openclaw_headers(settings: Settings, session_key: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {settings.openclaw_gateway_token}",
        "Content-Type": "application/json",
        "x-openclaw-agent-id": settings.openclaw_agent_id,
        "x-openclaw-session-key": session_key,
    }


def parse_chat_completion_content(payload: dict[str, Any]) -> str:
    try:
        message = payload["choices"][0]["message"]
    except Exception as exc:  # pragma: no cover - defensive
        raise RuntimeError(f"Unexpected OpenClaw response shape: {payload}") from exc

    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") in {"text", "output_text"} and isinstance(item.get("text"), str):
                parts.append(item["text"].strip())
        if parts:
            return "\n".join(part for part in parts if part)
    return json.dumps(payload, ensure_ascii=False)[:3000]


def openclaw_chat(settings: Settings, prompt: str, session_key: str) -> str:
    payload = {
        "model": settings.openclaw_model,
        "messages": [{"role": "user", "content": prompt}],
    }
    response = http_with_retry(
        "POST",
        f"{settings.openclaw_base_url}/v1/chat/completions",
        headers=openclaw_headers(settings, session_key),
        json=payload,
        timeout=90,
    )
    if response.status_code in {401, 403}:
        raise RuntimeError("OpenClaw rejected the voice bot token. Check OPENCLAW_GATEWAY_TOKEN.")
    if response.status_code == 404:
        raise RuntimeError("OpenClaw chat completions endpoint is not enabled yet. Run ./scripts/apply-voice-control.sh.")
    response.raise_for_status()
    return parse_chat_completion_content(response.json())


def build_local_help() -> str:
    phrases = ", ".join(SUPPORTED_PHRASES)
    return (
        "Voice bot da san sang.\n"
        "Hay gui voice note hoac text voi cac cum tu nhu: "
        f"{phrases}.\n"
        "Ban nen dung voice bot token rieng va allowlist Telegram user id."
    )


def format_transcript_debug(transcript: str, reply: str) -> str:
    return f"Transcript: {transcript}\n\n{reply}".strip()


def is_allowed_user(settings: Settings, user_id: int | None) -> bool:
    if not settings.telegram_allowlist:
        return True
    if user_id is None:
        return False
    return user_id in settings.telegram_allowlist


def build_session_key(settings: Settings, user_id: int | None) -> str:
    if user_id is None:
        return settings.openclaw_session_key_prefix
    return f"{settings.openclaw_session_key_prefix}:{user_id}"


def execute_intent(settings: Settings, transcript: str, intent: dict[str, Any], session_key: str) -> str:
    prompt = build_openclaw_prompt(intent)
    if prompt is None:
        return "Intent hien tai chua duoc ho tro."

    if intent["intent"] == "chat" and not settings.forward_unknown_to_chat:
        return (
            f'Toi nghe duoc: "{transcript}".\n'
            "Chua map duoc intent nay. Hay thu: trang thai, tro giup, chi phi, token, toi la ai, model hien tai."
        )

    return openclaw_chat(settings, prompt, session_key)


def extract_voice_descriptor(message: dict[str, Any]) -> dict[str, Any] | None:
    voice = message.get("voice")
    if voice:
        return {
            "file_id": voice.get("file_id"),
            "duration": voice.get("duration", 0),
            "file_size": voice.get("file_size", 0),
            "default_name": "voice.ogg",
        }

    audio = message.get("audio")
    if audio:
        original_name = audio.get("file_name") or "audio.bin"
        return {
            "file_id": audio.get("file_id"),
            "duration": audio.get("duration", 0),
            "file_size": audio.get("file_size", 0),
            "default_name": original_name,
        }

    return None


def choose_download_name(file_path: str, default_name: str) -> str:
    suffix = Path(file_path).suffix
    if suffix:
        return f"telegram-audio{suffix}"
    return default_name


def process_voice_message(settings: Settings, chat_id: int, user_id: int | None, message: dict[str, Any]) -> str | None:
    descriptor = extract_voice_descriptor(message)
    if descriptor is None:
        return None

    duration = int(descriptor.get("duration") or 0)
    file_size = int(descriptor.get("file_size") or 0)
    file_id = descriptor.get("file_id")
    if not file_id:
        return "Khong tim thay file_id cho voice message."

    if duration and duration > settings.max_duration_seconds:
        return f"Voice qua dai (>{settings.max_duration_seconds}s). Vui long noi lenh ngan."
    if file_size and file_size > settings.max_file_bytes:
        return "Voice vuot gioi han dung luong cho phep."

    file_info = tg_get_file_info(settings, file_id)
    file_path = file_info.get("file_path")
    if not file_path:
        return "Telegram khong tra ve duong dan file."

    session_key = build_session_key(settings, user_id)

    with tempfile.TemporaryDirectory() as tmp_dir_raw:
        tmp_dir = Path(tmp_dir_raw)
        download_name = choose_download_name(file_path, str(descriptor["default_name"]))
        source_path = tmp_dir / download_name
        download_file(settings, file_path, source_path)

        transcribe_path = source_path
        if settings.transcode_to_wav:
            transcribe_path = tmp_dir / "voice.wav"
            ffmpeg_to_wav(source_path, transcribe_path, settings.ffmpeg_sample_rate, settings.ffmpeg_channels)

        transcript = whisper_transcribe(settings, transcribe_path)
        if not transcript:
            return "Khong nhan duoc transcript tu STT."

        log(f"voice transcript chat_id={chat_id} user_id={user_id} transcript={transcript!r}")
        intent = parse_intent_vi(transcript)
        reply = execute_intent(settings, transcript, intent, session_key)
        if settings.send_transcript_debug:
            reply = format_transcript_debug(transcript, reply)
        return reply


def process_text_message(settings: Settings, user_id: int | None, text: str) -> str:
    normalized = normalize_text(text)
    if normalized in {"/start", "/help", "/voicehelp"}:
        return build_local_help()

    session_key = build_session_key(settings, user_id)
    log(f"text command user_id={user_id} text={text!r}")
    intent = parse_intent_vi(text)
    reply = execute_intent(settings, text, intent, session_key)
    if settings.send_transcript_debug:
        reply = format_transcript_debug(text, reply)
    return reply


def run_loop(settings: Settings) -> None:
    log(
        "starting poll loop "
        f"agent_id={settings.openclaw_agent_id} "
        f"model={settings.openclaw_model} "
        f"allowlist_size={len(settings.telegram_allowlist)} "
        f"transcode_to_wav={settings.transcode_to_wav} "
        f"whisper_url={settings.whisper_infer_url}"
    )
    offset: int | None = None
    while True:
        try:
            for update in tg_get_updates(settings, offset):
                offset = int(update["update_id"]) + 1
                message = update.get("message") or {}
                chat = message.get("chat") or {}
                chat_id = chat.get("id")
                if chat_id is None:
                    continue

                user_id = (message.get("from") or {}).get("id")
                if not is_allowed_user(settings, user_id):
                    log(f"ignored message from user_id={user_id} because it is not in allowlist")
                    continue

                text = message.get("text")
                try:
                    tg_send_chat_action(settings, int(chat_id), "typing")
                    if isinstance(text, str) and text.strip():
                        reply = process_text_message(settings, user_id, text.strip())
                    else:
                        reply = process_voice_message(settings, int(chat_id), user_id, message)

                    if reply:
                        tg_send_message(settings, int(chat_id), reply)
                except Exception as exc:
                    log(f"message handling failed for chat_id={chat_id} user_id={user_id}: {exc}", error=True)
                    tg_send_message(settings, int(chat_id), f"Voice bot gap loi: {exc}")
        except Exception as exc:
            log(f"poll loop error: {exc}", error=True)
            time.sleep(2)


def run_self_test() -> int:
    cases = {
        "trang thai he thong": "status",
        "tro giup cho toi": "help",
        "chi phi thang nay": "usage_cost",
        "token da dung": "usage_tokens",
        "toi la ai": "whoami",
        "model hien tai la gi": "model_status",
        "hay ke chuyen vui": "chat",
    }
    for text, expected in cases.items():
        actual = parse_intent_vi(text)["intent"]
        if actual != expected:
            raise SystemExit(f"Self-test failed for {text!r}: expected {expected}, got {actual}")

    if normalize_text("Trạng thái!!!") != "trang thai":
        raise SystemExit("Self-test failed for normalize_text accent stripping")

    print("voicebot self-test: ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Telegram voice bot for OpenClaw.")
    parser.add_argument("--self-test", action="store_true", help="Run parser and wiring self-tests, then exit.")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    settings = Settings.from_env()
    run_loop(settings)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
