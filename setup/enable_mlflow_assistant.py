"""Make MLflow's beta AI Assistant usable from a Docker-published port.

MLflow serves the Assistant API only when the request arrives from loopback, and
a port published by Docker always arrives from the bridge gateway instead, so the
panel answers 403 "Assistant API is only accessible from the same host where the
MLflow server is running." Two things have to give, both at image build time:

1. ``OllamaProvider.allows_remote_access`` is hardcoded ``False`` upstream, so
   even ``MLFLOW_ENABLE_REMOTE_ASSISTANT=true`` does not unblock Ollama. Patch it.
2. ``PUT /assistant/config`` is a DENY route, refused for every non-loopback
   client, so the UI setup wizard cannot save its settings from the host browser.
   Seed the config file instead.

Both steps depend on the pinned MLflow version and fail loudly if upstream moves
the code, so a rebuild never silently ships an unpatched assistant.
"""

import json
import os
import sys
from pathlib import Path

import mlflow

DEFAULT_MODEL = os.environ.get("MLFLOW_ASSISTANT_MODEL", "qwen2.5-coder:3b")
DEFAULT_OLLAMA_URL = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434")

def patch_ollama_provider() -> None:
    path = Path(mlflow.__file__).parent / "assistant" / "providers" / "ollama.py"
    source = path.read_text()
    if "def allows_remote_access" in source:
        print(f"assistant: {path.name} already patched")
        return

    anchor = "    def __init__(self) -> None:"
    if anchor not in source:
        sys.exit(f"assistant: unexpected layout in {path}, patch needs updating")

    source = source.replace(
        anchor,
        "    @property\n"
        "    def allows_remote_access(self) -> bool:\n"
        "        # Patched for Docker: the browser never reaches us from 127.0.0.1.\n"
        "        return True\n\n" + anchor,
        1,
    )
    path.write_text(source)
    print(f"assistant: patched {path}")


def seed_config() -> None:
    home = Path.home() / ".mlflow" / "assistant"
    home.mkdir(parents=True, exist_ok=True)
    config = {
        "projects": {},
        "providers": {
            "ollama": {
                "model": DEFAULT_MODEL,
                "selected": True,
                "base_url": DEFAULT_OLLAMA_URL,
            }
        },
    }
    target = home / "config.json"
    target.write_text(json.dumps(config, indent=2))
    print(f"assistant: seeded {target} (model {DEFAULT_MODEL})")


patch_ollama_provider()
seed_config()
