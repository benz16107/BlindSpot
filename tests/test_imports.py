import importlib

import pytest


@pytest.mark.parametrize(
    "module", ["agent", "navigation", "obstacle", "google_maps", "agent_config", "backboard_store"]
)
def test_module_imports_without_api_keys(module, monkeypatch):
    for key in ("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "GOOGLE_API_KEY", "GOOGLE_MAPS_API_KEY",
                "OPENAI_API_KEY", "ELEVEN_API_KEY", "BACKBOARD_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    importlib.import_module(module)
