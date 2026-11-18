"""Resolve only exact, recent Hermes message matches. No prompts are retained."""
import json
from pathlib import Path
import sqlite3
import time


def text_content(value):
    if isinstance(value, str):
        if value.lstrip().startswith("["):
            try:
                decoded = json.loads(value)
                if isinstance(decoded, list):
                    return text_content(decoded)
            except ValueError:
                pass
        return value.strip()
    if isinstance(value, list):
        return "\n".join(part.get("text", "") for part in value
                         if isinstance(part, dict) and part.get("type") in {"text", "input_text"}
                         and isinstance(part.get("text"), str)).strip()
    return ""


def homes(base):
    yield "default", "profiles", base
    for scope, folder in (("profiles", base / "profiles"),
                          ("office", base / "office-runtime/profiles")):
        for path in folder.glob("*"):
            if path.name.startswith(".") or not path.is_dir():
                continue
            if (base / "profiles/.deleted" / path.name).exists():
                continue
            yield path.name, scope, path


def match_request(body, base=None):
    # A short common instruction is insufficient evidence of the caller.
    messages = body.get("messages") or body.get("input")
    if not isinstance(messages, list):
        return {}
    needle = next((text_content(message.get("content")) for message in reversed(messages)
                   if isinstance(message, dict) and message.get("role") == "user"), "")
    if not 24 <= len(needle) <= 1_000_000:
        return {}
    base = base or Path.home() / ".hermes"
    cutoff, deadline = time.time() - 900, time.monotonic() + 0.7
    matches, seen = [], set()
    candidates = list(homes(base))
    candidates.sort(key=lambda item: (item[2] / "state.db").stat().st_mtime
                    if (item[2] / "state.db").exists() else 0, reverse=True)
    for profile, scope, home in candidates:
        if time.monotonic() > deadline:
            return {}  # Never pick the first match from an incomplete search.
        database = (home / "state.db").resolve()
        if database in seen or not database.is_file():
            continue
        seen.add(database)
        try:
            with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.02) as db:
                rows = db.execute("""
                    SELECT s.id, m.content, s.source, s.model FROM messages m
                    JOIN sessions s ON s.id=m.session_id
                    WHERE m.role='user' AND m.timestamp>=? AND s.ended_at IS NULL
                      AND (s.profile_name=? OR s.profile_name IS NULL OR (?='office' AND s.profile_name='custom'))
                    ORDER BY m.timestamp DESC LIMIT 8
                """, (cutoff, profile, scope)).fetchall()
                for session, content, source, model in rows:
                    if text_content(content) != needle:
                        continue
                    requested = str(body.get("model") or "").removeprefix("local/")
                    saved = str(model or "").removeprefix("local/")
                    if requested and saved and requested != saved:
                        continue
                    match = dict(profile=profile, session=session, scope=scope,
                                 client="Paperclip → Hermes" if scope == "office" else "Hermes",
                                 source="cron" if source == "cron" else "chat",
                                 attribution="message_match")
                    if not any(m["profile"] == profile and m["session"] == session and m["scope"] == scope for m in matches):
                        matches.append(match)
        except (OSError, sqlite3.Error):
            continue
    return matches[0] if len(matches) == 1 else {}
