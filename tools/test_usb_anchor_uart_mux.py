"""Host-side USB UART mux registration contract."""

import struct
import os
import socket
import threading
import time
from types import SimpleNamespace

import serial
import usb_anchor_uart_mux as mux

from usb_anchor_uart_mux import (
    Decoder,
    HostFlowControl,
    REGISTER,
    ROLE_ANCHOR,
    ROLE_CONSOLE,
    ROLE_UART,
    VIRTUAL_UART,
    CREDIT,
    DATA,
    find_mux_port,
    frame,
    registration_label,
    run_session,
)


def test_firmware_registration_can_create_console_without_host_open():
    payload = bytes((1, ROLE_CONSOLE, VIRTUAL_UART)) + struct.pack("<I", 0)
    decoded = Decoder().feed(frame(REGISTER, 3, payload))
    assert decoded == [(REGISTER, 3, payload)]
    assert registration_label(3, payload) == "App console (USB)"


def test_firmware_registration_identifies_selected_uart():
    payload = bytes((1, ROLE_CONSOLE, 2)) + struct.pack("<I", 230400)
    assert registration_label(3, payload) == "App console (UART2, 230400 baud)"
    payload = bytes((1, ROLE_UART, 1)) + struct.pack("<I", 115200)
    assert registration_label(1, payload) == "UART1 (115200 baud)"


def test_registration_rejects_unknown_versions_and_roles():
    assert registration_label(0, bytes((1, ROLE_ANCHOR, VIRTUAL_UART)) + bytes(4)) == "Anchor console/flash"
    assert registration_label(3, bytes((2, ROLE_CONSOLE, VIRTUAL_UART)) + bytes(4)) is None
    assert registration_label(3, bytes((1, 99, VIRTUAL_UART)) + bytes(4)) is None
    assert registration_label(3, b"\x01") is None


def test_legacy_empty_registration_remains_supported():
    assert registration_label(0, b"") == "Anchor console/flash"
    assert registration_label(2, b"") == "UART2"


def test_reconnect_finds_same_anchor_after_device_path_changes():
    old = SimpleNamespace(device="/dev/cu.usbmodem-old", vid=0x1209, pid=0xB808,
                          serial_number="BL808-ANCHOR", location="1-3")
    new = SimpleNamespace(device="/dev/cu.usbmodem-new", vid=0x1209, pid=0xB808,
                          serial_number="BL808-ANCHOR", location="1-3")
    other = SimpleNamespace(device="/dev/cu.usbmodem-other", vid=0x1209,
                            pid=0xB808, serial_number="BL808-ANCHOR",
                            location="1-4")
    assert find_mux_port(old.device, (old.serial_number, old.location),
                         [other, new]) == new.device


def test_host_sends_only_device_granted_app_input():
    flow = HostFlowControl()
    registration = bytes((1, ROLE_CONSOLE, 0)) + struct.pack("<I", 230400)
    flow.register(3, registration)
    assert flow.allowance(3) == 0
    flow.grant(3, struct.pack("<H", 53))
    assert flow.allowance(3) == 48
    flow.sent(3, 48)
    assert flow.allowance(3) == 5
    flow.sent(3, 5)
    assert flow.allowance(3) == 0
    flow.grant(3, struct.pack("<H", 7))
    assert flow.allowance(3) == 7
    flow.unregister(3)
    assert flow.allowance(3) == 48


def test_unsolicited_console_registration_and_credit_over_live_mux(monkeypatch):
    host, device = socket.socketpair()
    device.settimeout(1)
    opened = []
    real_openpty = os.openpty
    real_setraw = mux.tty.setraw
    raw_ready = threading.Event()

    def record_openpty():
        pair = real_openpty()
        opened.append(pair)
        return pair

    monkeypatch.setattr(os, "openpty", record_openpty)

    def record_setraw(fd):
        real_setraw(fd)
        raw_ready.set()

    monkeypatch.setattr(mux.tty, "setraw", record_setraw)

    class Link:
        def fileno(self):
            return host.fileno()

        def read(self, length):
            return host.recv(length)

        def write(self, data):
            host.sendall(data)
            return len(data)

    errors = []

    def serve():
        try:
            run_session(Link(), {0: 0})
        except serial.SerialException as exc:
            errors.append(str(exc))

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    decoder = Decoder()
    registration = bytes((1, ROLE_CONSOLE, 0)) + struct.pack("<I", 230400)
    try:
        device.sendall(frame(REGISTER, 3, registration) +
                       frame(CREDIT, 3, struct.pack("<H", 5)))
        assert raw_ready.wait(timeout=1)
        assert opened
        os.write(opened[0][1], b"abcdefgh")

        def next_data():
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                for kind, channel, payload in decoder.feed(device.recv(256)):
                    if kind == DATA and channel == 3:
                        return payload
            raise AssertionError("console data was not forwarded")

        assert next_data() == b"abcde"
        device.sendall(frame(CREDIT, 3, struct.pack("<H", 3)))
        assert next_data() == b"fgh"
    finally:
        device.close()
        worker.join(timeout=2)
        host.close()
    assert errors == ["USB anchor disconnected"]
