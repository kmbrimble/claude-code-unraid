"""Minimal real-HA test run inside a uv-managed Python 3.14 venv.

Proves pytest-homeassistant-custom-component actually works against the
3.14 interpreter this image bakes in (issue #18), not against stubs — the
`hass` fixture boots a real, minimal Home Assistant core.
"""
from homeassistant.core import CoreState, HomeAssistant


async def test_hass_state_and_roundtrip(hass: HomeAssistant) -> None:
    assert hass.state is CoreState.running
    hass.states.async_set("test.ha_smoke", "hello")
    await hass.async_block_till_done()
    state = hass.states.get("test.ha_smoke")
    assert state is not None
    assert state.state == "hello"
