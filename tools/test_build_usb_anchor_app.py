"""Resident USB UART anchor application image checks."""

import struct

import pytest

import build_usb_anchor_app as app


def test_package_header_matches_resident_loader_contract():
    payload = b"\x11\x22\x33\x44"
    image = app.package_app(payload, {
        "anchor_app_init": app.APP_RAM_BASE,
        "anchor_app_poll": app.APP_RAM_BASE + 2,
        "_ebss": app.APP_RAM_BASE + 8,
    })
    assert len(image) == app.APP_HEADER_SIZE + len(payload)
    assert struct.unpack_from("<IHHIIIIII", image) == (
        app.APP_MAGIC, app.APP_VERSION, app.APP_HEADER_SIZE,
        4, 8, 0, 2, app.checksum(payload), 0,
    )
    assert image[app.APP_HEADER_SIZE:] == payload


@pytest.mark.parametrize("symbols", [
    {"anchor_app_poll": app.APP_RAM_BASE, "_ebss": app.APP_RAM_BASE + 4},
    {"anchor_app_init": app.APP_RAM_BASE + 1,
     "anchor_app_poll": app.APP_RAM_BASE + 2, "_ebss": app.APP_RAM_BASE + 4},
    {"anchor_app_init": app.APP_RAM_BASE,
     "anchor_app_poll": app.APP_RAM_BASE + 4, "_ebss": app.APP_RAM_BASE + 4},
    {"anchor_app_init": app.APP_RAM_BASE,
     "anchor_app_poll": app.APP_RAM_BASE + 2,
     "_ebss": app.APP_RAM_BASE + app.APP_RAM_CAPACITY + 1},
])
def test_package_rejects_invalid_app_layout(symbols):
    with pytest.raises(ValueError):
        app.package_app(b"\x11\x22\x33\x44", symbols)
