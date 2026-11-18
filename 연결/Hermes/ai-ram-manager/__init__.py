"""Attach attribution only to the local Splash session gate."""

import base64
import os
from pathlib import Path
from urllib.parse import urlsplit


def encode(value):
    return base64.urlsafe_b64encode(str(value or "")[:120].encode()).decode().rstrip("=")


def attach_identity(request, base_url="", session_id="", turn_id="", platform="", **kwargs):
    from hermes_constants import get_hermes_home

    try:
        url = urlsplit(base_url or "")
        if url.scheme != "http" or url.hostname not in {"127.0.0.1", "localhost"}:
            return None
        if url.port not in {8000, 8002} or url.username or url.password:
            return None
        if url.path.rstrip("/") not in {"", "/v1", "/user", "/bot", "/user/v1", "/bot/v1"}:
            return None
    except ValueError:
        return None

    home = Path(get_hermes_home()).resolve()
    base = Path.home() / ".hermes"
    if home == base.resolve():
        profile, scope = "default", "profiles"
    elif home.parent == (base / "profiles").resolve():
        profile, scope = home.name, "profiles"
    elif home.parent == (base / "office-runtime/profiles").resolve():
        profile, scope = home.name, "office"
    else:
        # Custom test homes cannot be mistaken for the default profile.
        profile, scope = home.name, "custom"

    headers = dict(request.get("extra_headers") or {})
    headers["X-AIRAM-Profile"] = encode(profile)
    headers["X-AIRAM-Session"] = encode(session_id)
    headers["X-AIRAM-Turn"] = encode(turn_id)
    headers["X-AIRAM-Scope"] = encode(scope)
    headers["X-AIRAM-Client"] = encode("Paperclip → Hermes" if os.environ.get("PAPERCLIP_RUN_ID") else "Hermes")
    headers["X-AIRAM-Source"] = encode("cron" if platform == "cron" else "chat")
    return {"request": {**request, "extra_headers": headers}, "source": "ai-ram-manager"}


def register(context):
    from hermes_cli.middleware import LLM_REQUEST_MIDDLEWARE
    context.register_middleware(LLM_REQUEST_MIDDLEWARE, attach_identity)
