"""Tests for UART-anchor paths in tools/hw_validate.py."""
from __future__ import annotations

import json
import hashlib
import re
import struct
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

import build_bl808_boot2_flash
import hw_validate


@pytest.mark.parametrize("offset", [False, 0xB0000, 0xE1000, 0x100000])
def test_lp_flash_offset_rejects_invalid_window(offset):
    with pytest.raises(RuntimeError, match="64 KiB-aligned"):
        hw_validate.lp_flash_offset_for_test({"lp_flash_offset": offset})


def test_allcore_flash_segments_use_manifest_lp_slot(monkeypatch, tmp_path):
    def output(core, data):
        path = tmp_path / f"{core}.bin"
        path.write_bytes(data)
        return hw_validate.BuildOutput(core, f"bl808{core}", "example.nim",
                                       path.with_suffix(".elf"), path, core)

    outputs = {core: output(core, b"image") for core in ("m0", "d0", "lp")}
    monkeypatch.setattr(hw_validate, "build_m0_jtag_flash_segments",
                        lambda item, **_: [hw_validate.JtagFlashSegment(0xDF000, item.bin, "FW")])
    args = {"args": SimpleNamespace(), "work_dir": tmp_path, "outputs": outputs}
    test = {"name": "allcore", "lp_flash_offset": 0xE0000}
    segments = hw_validate.jtag_flash_segments_for_outputs(test, **args)
    assert [(segment.label, segment.address) for segment in segments] == [
        ("FW", 0xDF000), ("lp", 0xE0000), ("d0", 0x100000)]
    m0_only = {**args, "outputs": {"m0": outputs["m0"]}}
    outputs["m0"].bin.write_bytes(bytes(0x1000))
    assert hw_validate.jtag_flash_segments_for_outputs(test, **m0_only) == segments[:1]
    outputs["m0"].bin.write_bytes(bytes(0x1001))
    with pytest.raises(RuntimeError, match="retained LP image at 0x0E0000"):
        hw_validate.jtag_flash_segments_for_outputs(test, **m0_only)
    with pytest.raises(RuntimeError, match="overlapping flash segments"):
        hw_validate.jtag_flash_segments_for_outputs(test, **args)
    outputs["lp"].bin.write_bytes(bytes(0x20001))
    with pytest.raises(RuntimeError, match="LP image exceeds its flash window below D0"):
        hw_validate.jtag_flash_segments_for_outputs(test, **args)


def test_flash_planner_rejects_disjoint_writes_to_same_erase_sector(tmp_path):
    payload = tmp_path / "byte.bin"
    payload.write_bytes(b"a")
    segments = [hw_validate.JtagFlashSegment(0x10000, payload, "first"),
                hw_validate.JtagFlashSegment(0x10001, payload, "second")]
    with pytest.raises(RuntimeError, match="overlapping flash segments \\(erase ranges\\)"):
        hw_validate.validate_flash_segments_do_not_overlap(segments)


def test_flash_planner_checks_legacy_jtag_lp_erase_block(tmp_path):
    payload = tmp_path / "byte.bin"
    payload.write_bytes(b"a")
    segments = [hw_validate.JtagFlashSegment(hw_validate.JTAG_FLASH_LP_OFFSET, payload, "LP"),
                hw_validate.JtagFlashSegment(hw_validate.JTAG_FLASH_LP_OFFSET + 0x1000, payload, "next")]
    hw_validate.validate_flash_segments_do_not_overlap(segments)
    with pytest.raises(RuntimeError, match="overlapping flash segments"):
        hw_validate.validate_flash_segments_do_not_overlap(segments, jtag_flash=True)


@pytest.mark.parametrize("ack_mode", ["uart", "jtag"])
@pytest.mark.parametrize("write_payload", [False, True])
def test_uart_anchor_command_sends_single_complete_frame(monkeypatch, ack_mode, write_payload):
    address = 0x20000
    payload = bytes(range(256)) * 16 if write_payload else b""
    length = len(payload) if payload else 8192
    command = (hw_validate.UART_FLASH_CMD_WRITE_VERIFY if payload
               else hw_validate.UART_FLASH_CMD_ERASE)
    checksum = hw_validate.jtag_flash_checksum(payload) if payload else 0
    counter = address + length
    response = bytearray(struct.pack("<IIII", hw_validate.UART_FLASH_RESP_MAGIC, 0, 0, counter))

    class FakeSerial:
        baudrate = 230400

        def __init__(self):
            self.writes = []
            self.flushes = 0

        def write(self, data):
            self.writes.append(data)
            return len(data)

        def flush(self):
            self.flushes += 1

        def read(self, size):
            data = bytes(response[:size])
            del response[:size]
            return data

    waits = []
    monkeypatch.setattr(hw_validate.time, "sleep", waits.append)
    if ack_mode == "jtag":
        debug_reads = iter([
            {"sequence": 0},
            {
                "sequence": 1, "command": command, "address": address,
                "length": length, "expected_header_checksum":
                    hw_validate.uart_flash_header_checksum(command, address, length),
                "status": 0, "result": 0, "counter": counter,
            },
        ])
        def read_debug(*_args, **_kwargs):
            debug = next(debug_reads)
            if debug["sequence"] and payload:
                assert ser.flushes == 1
                assert waits == [10 * len(ser.writes[0]) / ser.baudrate]
            return debug

        monkeypatch.setattr(hw_validate, "uart_flash_anchor_read_debug", read_debug)

    ser = FakeSerial()
    assert hw_validate.uart_flash_anchor_command_checked(
        ser, command, session=object() if ack_mode == "jtag" else None,
        ack_mode=ack_mode, address=address, length=length, checksum=checksum,
        payload=payload,
    ) == (0, counter)
    assert ser.writes == [
        struct.pack(
            "<IIIIII", hw_validate.UART_FLASH_REQ_MAGIC, hw_validate.UART_FLASH_REQ_GUARD,
            command, address, length,
            hw_validate.uart_flash_header_checksum(command, address, length),
        ) + (struct.pack("<I", checksum) + payload if payload else b"")
    ]
    assert ser.flushes == 1
    if ack_mode == "uart" or not payload:
        assert not waits


def test_jtag_uart_reboot_poll_survives_debug_reset(monkeypatch):
    writes = []

    def send_request(_serial, command, address, length, checksum, payload):
        assert command == hw_validate.UART_FLASH_CMD_REBOOT
        assert (address, length, checksum, payload) == (0, 0, 0, b"")
        writes.append(command)
        return 24

    completed = {
        "sequence": 8, "command": hw_validate.UART_FLASH_CMD_REBOOT,
        "address": 0, "length": 0,
        "expected_header_checksum": hw_validate.uart_flash_header_checksum(
            hw_validate.UART_FLASH_CMD_REBOOT, 0, 0,
        ),
        "status": 0, "result": 0, "counter": 0,
    }
    outcomes = iter([{"sequence": 7}, RuntimeError("debug module reset"), completed])

    def read_debug(*_args, **_kwargs):
        result = next(outcomes)
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(hw_validate, "uart_flash_anchor_send_request", send_request)
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_read_debug", read_debug)
    monkeypatch.setattr(hw_validate.time, "sleep", lambda _seconds: None)
    assert hw_validate.uart_flash_anchor_command_jtag_ack(
        object(), object(), hw_validate.UART_FLASH_CMD_REBOOT,
    ) == (0, 0)
    assert writes == [hw_validate.UART_FLASH_CMD_REBOOT]


def test_uart_anchor_command_rejects_short_write():
    class ShortSerial:
        def write(self, frame):
            return len(frame) - 1

        def flush(self):
            pytest.fail("incomplete frame must not be flushed")

    with pytest.raises(RuntimeError, match="completion unknown.*write was incomplete"):
        hw_validate.uart_flash_anchor_command(
            ShortSerial(), hw_validate.UART_FLASH_CMD_ERASE,
            address=0x10000, length=4096,
        )


@pytest.mark.parametrize("command", [
    hw_validate.UART_FLASH_CMD_ERASE,
    hw_validate.UART_FLASH_CMD_WRITE_VERIFY,
    hw_validate.UART_FLASH_CMD_REBOOT,
])
@pytest.mark.parametrize("stage", ["write", "flush", "ack"])
def test_uart_anchor_lost_mutation_ack_does_not_replay(monkeypatch, command, stage):
    class FaultySerial:
        def write(self, frame):
            writes.append(frame)
            if stage == "write":
                raise fault
            return len(frame)

        def flush(self):
            if stage == "flush":
                raise fault

    def read_response(*_args, **_kwargs):
        assert stage == "ack"
        raise fault

    fault = TimeoutError("ACK lost") if stage == "ack" else OSError("PTY write failed")
    writes = []
    monkeypatch.setattr(hw_validate, "serial_read_uart_anchor_response", read_response)
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet",
                        lambda *_a, **_kw: pytest.fail("a mutation must not drain and retry"))
    kwargs = {
        hw_validate.UART_FLASH_CMD_ERASE: {"address": 0x10000, "length": 4096},
        hw_validate.UART_FLASH_CMD_WRITE_VERIFY: {"address": 0x10000, "payload": b"test"},
        hw_validate.UART_FLASH_CMD_REBOOT: {},
    }[command]
    with pytest.raises(RuntimeError, match=f"command {command}.*completion unknown; not retried") as err:
        hw_validate.uart_flash_anchor_command(FaultySerial(), command, attempts=3, **kwargs)
    assert err.value.__cause__ is fault
    assert str(fault) in str(err.value)
    assert len(writes) == 1


@pytest.mark.parametrize("command", [hw_validate.UART_FLASH_CMD_PING, hw_validate.UART_FLASH_CMD_READ_ID])
@pytest.mark.parametrize("drain_fails", [False, True])
def test_uart_anchor_read_only_probe_retries_without_masking_transport_error(monkeypatch, command, drain_fails):
    fault = OSError("first transport error")
    writes = []
    drains = []

    def read_response(*_args, **_kwargs):
        if len(writes) == 1:
            raise fault
        return struct.pack("<IIII", hw_validate.UART_FLASH_RESP_MAGIC, 0, 1, 0)

    def drain(*_args, **_kwargs):
        drains.append(True)
        if drain_fails:
            raise OSError("cleanup transport error")

    monkeypatch.setattr(hw_validate, "uart_flash_anchor_send_request",
                        lambda _ser, cmd, *_args: writes.append(cmd))
    monkeypatch.setattr(hw_validate, "serial_read_uart_anchor_response", read_response)
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet", drain)
    monkeypatch.setattr(hw_validate.time, "sleep", lambda _s: None)
    if drain_fails:
        with pytest.raises(OSError) as err:
            hw_validate.uart_flash_anchor_command(object(), command, attempts=3)
        assert err.value is fault
        assert writes == [command]
    else:
        assert hw_validate.uart_flash_anchor_command(object(), command, attempts=3) == (1, 0)
        assert writes == [command, command]
    assert drains == [True]


@pytest.mark.parametrize("status", [0, 3, 4, 5])
def test_uart_anchor_mutation_ack_matches_counter_before_status(monkeypatch, status):
    command = hw_validate.UART_FLASH_CMD_WRITE_VERIFY
    responses = iter([
        struct.pack("<IIII", hw_validate.UART_FLASH_RESP_MAGIC, 5, 0, 0x10000),
        struct.pack("<IIII", hw_validate.UART_FLASH_RESP_MAGIC, status, 0, 0x10004),
    ])
    writes = []
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_send_request",
                        lambda _ser, cmd, *_args: writes.append(cmd))
    monkeypatch.setattr(hw_validate, "serial_read_uart_anchor_response",
                        lambda *_a, **_kw: next(responses))
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet",
                        lambda *_a, **_kw: pytest.fail("a mutation NACK must not trigger replay"))

    def program():
        return hw_validate.uart_flash_anchor_command(
            object(), command, address=0x10000, payload=b"test", attempts=3,
        )

    if status == 0:
        assert program() == (0, 0x10004)
    else:
        with pytest.raises(RuntimeError, match=hw_validate.UART_FLASH_STATUS_NAMES[status]) as err:
            program()
        assert "counter=0x00010004" in str(err.value)
        assert "completion unknown" not in str(err.value)
    assert writes == [command]


@pytest.mark.parametrize("lose_erase_ack", [True, False])
def test_uart_anchor_segment_reports_exact_verified_prefix(tmp_path, lose_erase_ack):
    image = tmp_path / "firmware.bin"
    image.write_bytes(bytes(0x3000))
    segment = hw_validate.JtagFlashSegment(0x10000, image, "firmware:FW")
    fault = OSError("USB PTY disconnected")
    requests = []

    class LostAckSerial:
        response = bytearray()

        def write(self, frame):
            command, address, length = struct.unpack_from("<III", frame, 8)
            requests.append((command, address, length))
            if not lose_erase_ack and len(requests) < 3:
                self.response.extend(struct.pack(
                    "<IIII", hw_validate.UART_FLASH_RESP_MAGIC, 0, 0, address + length,
                ))
            return len(frame)

        def flush(self):
            pass

        def read(self, size):
            if not self.response:
                raise fault
            data = bytes(self.response[:size])
            del self.response[:size]
            return data

    verified = 0 if lose_erase_ack else 0x1000
    with pytest.raises(RuntimeError, match=f"firmware:FW: last verified offset 0x{verified:X}/0x3000") as err:
        hw_validate.uart_anchor_flash_program_segment(
            LostAckSerial(), segment,
            args=SimpleNamespace(dry_run=False, uart_anchor_flash_chunk_size=0x1000),
        )
    assert f"exclusive flash address 0x{0x10000 + verified:06X}" in str(err.value)
    assert "completion unknown; not retried" in str(err.value)
    assert "USB PTY disconnected" in str(err.value)
    assert err.value.__cause__.__cause__ is fault
    expected = [(hw_validate.UART_FLASH_CMD_ERASE, 0x10000, 0x3000)]
    if not lose_erase_ack:
        expected += [(hw_validate.UART_FLASH_CMD_WRITE_VERIFY, addr, 0x1000)
                     for addr in (0x10000, 0x11000)]
    assert requests == expected


def test_jtag_m0_load_uses_elf_entry(monkeypatch):
    elf = Path("/tmp/csi_ram_probe.elf")
    monkeypatch.setattr(hw_validate, "elf_start_address", lambda path: 0x22030000 if path == elf else None)
    output = SimpleNamespace(core="bl808m0", elf=elf)
    assert hw_validate.jtag_load_entry(output) == 0x22030000


def test_host_action_command_expands_e2e_marker_fields():
    output = "\n".join([
        "noise",
        "MASK: 255.255 P@e2e dhcp:ok ip=0x7A01A8C0 gw=0x0101A8C0",
    ])
    cmd = hw_validate.host_action_command(
        {
            "cmd": [
                "{python}",
                "tools/probe_wifi_lwip_tcp_udp.py",
                "--ip",
                "{e2e:dhcp:ok:ip}",
            ]
        },
        output,
    )

    assert cmd == [
        sys.executable,
        "tools/probe_wifi_lwip_tcp_udp.py",
        "--ip",
        "0x7A01A8C0",
    ]


def test_host_action_command_rejects_missing_e2e_marker_field():
    with pytest.raises(RuntimeError, match="not found"):
        hw_validate.host_action_command(
            {"cmd": ["probe", "{e2e:dhcp:ok:ip}"]},
            "@e2e scan:ok items=1",
        )


def test_existing_anchor_ack_select_uses_uart_without_jtag(monkeypatch, tmp_path):
    def fake_uart_ping(_ser, *, timeout_s):
        assert timeout_s == 10
        return 1

    def fail_jtag_ping(*_args, **_kwargs):
        raise AssertionError("JTAG ack should not be used")

    monkeypatch.setattr(hw_validate, "uart_flash_anchor_ping_until_ready", fake_uart_ping)
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_ping_until_ready_jtag", fail_jtag_ping)

    log_path = tmp_path / "anchor.log"
    mode = hw_validate.select_uart_flash_anchor_ack_mode(
        SimpleNamespace(uart_anchor_ack_mode="auto"),
        object(),
        None,
        log_path=log_path,
        prefix="existing UART flash anchor",
    )

    assert mode == "uart"
    assert "using UART anchor UART ack mode" in log_path.read_text()


def test_existing_anchor_auto_ack_reports_missing_jtag_fallback(monkeypatch, tmp_path):
    def fail_uart_ping(*_args, **_kwargs):
        raise RuntimeError("no response")

    monkeypatch.setattr(hw_validate, "uart_flash_anchor_ping_until_ready", fail_uart_ping)

    with pytest.raises(RuntimeError, match="no OpenOCD session"):
        hw_validate.select_uart_flash_anchor_ack_mode(
            SimpleNamespace(uart_anchor_ack_mode="auto"),
            object(),
            None,
            log_path=tmp_path / "anchor.log",
            prefix="existing UART flash anchor",
        )


def test_existing_anchor_jtag_ack_requires_session(tmp_path):
    with pytest.raises(RuntimeError, match="requires an OpenOCD session"):
        hw_validate.select_uart_flash_anchor_ack_mode(
            SimpleNamespace(uart_anchor_ack_mode="jtag"),
            object(),
            None,
            log_path=tmp_path / "anchor.log",
            prefix="existing UART flash anchor",
        )


@pytest.mark.parametrize("no_jtag_reset", [False, True])
@pytest.mark.parametrize("reboot_requested", [False, True])
def test_ram_anchor_probe_respects_no_jtag_reset(monkeypatch, tmp_path, no_jtag_reset,
                                                 reboot_requested):
    calls = []

    class FakeSession:
        log_path = tmp_path / "probe.openocd.log"

        def command(self, command, **_kwargs):
            calls.append(command)

        def close(self):
            calls.append("close")

    class FakeSerial:
        def reset_input_buffer(self):
            pass

        def reset_output_buffer(self):
            pass

        def close(self):
            pass

    def fake_prepare(**kwargs):
        calls.append(("prepare", kwargs["reset_target"]))
        return FakeSession()

    def fake_jtag_command(_session, command, **_kwargs):
        calls.append(command)

    monkeypatch.setattr(hw_validate, "configure_sudo_askpass", lambda *_args: None)
    monkeypatch.setattr(hw_validate, "build_uart_flash_anchor", lambda **_kwargs: tmp_path / "anchor.bin")
    monkeypatch.setattr(hw_validate, "prepare_jtag_session_with_recovery", fake_prepare)
    monkeypatch.setattr(hw_validate, "initial_jtag_command_with_recovery", fake_jtag_command)
    monkeypatch.setattr(hw_validate, "open_serial_device", lambda *_args, **_kwargs: FakeSerial())
    monkeypatch.setattr(hw_validate, "wait_for_uart_flash_anchor", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(hw_validate, "select_uart_flash_anchor_ack_mode", lambda *_args, **_kwargs: "uart")
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_command_checked",
                        lambda _ser, command, **_kwargs: calls.append(command) or (0x123456, 0))

    args = SimpleNamespace(
        work_dir=tmp_path,
        no_jtag=False,
        no_jtag_reset=no_jtag_reset,
        uart_anchor_existing=False,
        flash_port=None,
        uart="/dev/fake",
        flash_baud=None,
        uart_baud=None,
        serial_dtr="off",
        serial_rts="off",
        dry_run=False,
        uart_anchor_reboot=reboot_requested,
    )
    assert hw_validate.run_uart_anchor_probe(args, {"defaults": {}}) == 0
    assert calls[0] == ("prepare", not no_jtag_reset)
    assert ("reset halt" in calls) == (not no_jtag_reset)
    assert "halt" in calls
    assert f"reg pc 0x{hw_validate.UART_FLASH_ANCHOR_ENTRY:08X}" in calls
    assert "resume" in calls
    assert (hw_validate.UART_FLASH_CMD_REBOOT in calls) == reboot_requested
    assert calls[-1] == "close"


def test_uart_anchor_request_reboot_sends_reboot_command(monkeypatch):
    calls = []

    def fake_command(ser, command, **kwargs):
        calls.append((ser, command, kwargs))
        return 0, 0

    monkeypatch.setattr(hw_validate, "uart_flash_anchor_command_checked", fake_command)

    ser = object()
    hw_validate.uart_anchor_request_reboot(
        ser,
        args=SimpleNamespace(dry_run=False),
        session=None,
        ack_mode="uart",
    )

    assert calls
    assert calls[0][0] is ser
    assert calls[0][1] == hw_validate.UART_FLASH_CMD_REBOOT
    assert calls[0][2]["ack_mode"] == "uart"


def test_target_reset_pulse_resets_ftdi_after_success(monkeypatch, tmp_path):
    calls = []
    args = SimpleNamespace(
        attach_openocd=False,
        dry_run=False,
        ftdi_srst_pulse_bin=tmp_path / "ftdi_srst_pulse",
        ftdi_srst_pulse_source=tmp_path / "ftdi_srst_pulse.c",
        ftdi_reset_vid="0x0403",
        ftdi_reset_pid="0x6014",
        ftdi_reset_serial="",
        ftdi_reset_sudo=False,
        ftdi_reset_settle=0,
        sudo_askpass=None,
    )

    def fake_run_logged(cmd, **kwargs):
        calls.append(("srst", cmd))
        return SimpleNamespace(returncode=0, stdout="")

    def fake_reset_after(_args, _log_path, *, reason):
        calls.append(("ftdi-reset-after", reason))

    monkeypatch.setattr(
        hw_validate,
        "build_ftdi_srst_pulse_helper",
        lambda _args, _log_path: tmp_path / "ftdi_srst_pulse",
    )
    monkeypatch.setattr(hw_validate, "run_logged", fake_run_logged)
    monkeypatch.setattr(
        hw_validate,
        "reset_ftdi_adapter_after_target_reset",
        fake_reset_after,
    )

    hw_validate.pulse_target_reset_via_ftdi(
        args,
        tmp_path / "reset.log",
        reason="unit reset",
    )

    assert calls == [
        ("srst", [str(tmp_path / "ftdi_srst_pulse"), "0x0403", "0x6014"]),
        ("ftdi-reset-after", "unit reset"),
    ]


def test_ftdi_reset_sudo_flag_still_tries_no_sudo_first(monkeypatch, tmp_path):
    calls = []
    args = SimpleNamespace(
        no_ftdi_reset=False,
        attach_openocd=False,
        dry_run=False,
        ftdi_reset_bin=tmp_path / "ftdi_reset",
        ftdi_reset_source=tmp_path / "ftdi_reset.c",
        ftdi_reset_vid="0x0403",
        ftdi_reset_pid="0x6014",
        ftdi_reset_serial="",
        ftdi_reset_sudo=True,
        ftdi_reset_settle=0,
        sudo_askpass=None,
        sudo_askpass_helper=None,
    )

    def fake_run_logged(cmd, **kwargs):
        calls.append((cmd, kwargs.get("env")))
        return SimpleNamespace(returncode=0, stdout="FTDI reset ok\n")

    monkeypatch.setattr(hw_validate.os, "geteuid", lambda: 501)
    monkeypatch.setattr(
        hw_validate,
        "build_ftdi_reset_helper",
        lambda _args, _log_path: tmp_path / "ftdi_reset",
    )
    monkeypatch.setattr(hw_validate, "run_logged", fake_run_logged)

    ok, message = hw_validate.probe_ftdi_reset(args, tmp_path / "reset.log", reason="unit")

    assert ok
    assert message == "FTDI reset ok"
    assert calls == [([str(tmp_path / "ftdi_reset"), "0x0403", "0x6014"], None)]


def test_ftdi_reset_failure_does_not_try_sudo_without_askpass(monkeypatch, tmp_path):
    calls = []
    args = SimpleNamespace(
        no_ftdi_reset=False,
        attach_openocd=False,
        dry_run=False,
        ftdi_reset_bin=tmp_path / "ftdi_reset",
        ftdi_reset_source=tmp_path / "ftdi_reset.c",
        ftdi_reset_vid="0x0403",
        ftdi_reset_pid="0x6014",
        ftdi_reset_serial="",
        ftdi_reset_sudo=True,
        ftdi_reset_settle=0,
        sudo_askpass=None,
        sudo_askpass_helper=None,
    )

    def fake_run_logged(cmd, **kwargs):
        calls.append((cmd, kwargs.get("env")))
        return SimpleNamespace(returncode=1, stdout="claim failed\n")

    monkeypatch.setattr(hw_validate.os, "geteuid", lambda: 501)
    monkeypatch.setattr(
        hw_validate,
        "build_ftdi_reset_helper",
        lambda _args, _log_path: tmp_path / "ftdi_reset",
    )
    monkeypatch.setattr(hw_validate, "run_logged", fake_run_logged)

    ok, message = hw_validate.probe_ftdi_reset(args, tmp_path / "reset.log", reason="unit")

    assert not ok
    assert message == "claim failed"
    assert calls == [([str(tmp_path / "ftdi_reset"), "0x0403", "0x6014"], None)]


def test_ftdi_reset_uses_sudo_askpass_only_after_no_sudo_failure(monkeypatch, tmp_path):
    calls = []
    args = SimpleNamespace(
        no_ftdi_reset=False,
        attach_openocd=False,
        dry_run=False,
        ftdi_reset_bin=tmp_path / "ftdi_reset",
        ftdi_reset_source=tmp_path / "ftdi_reset.c",
        ftdi_reset_vid="0x0403",
        ftdi_reset_pid="0x6014",
        ftdi_reset_serial="",
        ftdi_reset_sudo=True,
        ftdi_reset_settle=0,
        sudo_askpass=True,
        sudo_askpass_helper=None,
    )

    def fake_run_logged(cmd, **kwargs):
        calls.append((cmd, kwargs.get("env")))
        if len(calls) == 1:
            return SimpleNamespace(returncode=1, stdout="claim failed\n")
        return SimpleNamespace(returncode=0, stdout="FTDI reset ok\n")

    monkeypatch.setattr(hw_validate.os, "geteuid", lambda: 501)
    monkeypatch.setattr(
        hw_validate,
        "build_ftdi_reset_helper",
        lambda _args, _log_path: tmp_path / "ftdi_reset",
    )
    monkeypatch.setattr(hw_validate, "run_logged", fake_run_logged)

    ok, message = hw_validate.probe_ftdi_reset(args, tmp_path / "reset.log", reason="unit")

    assert ok
    assert message == "FTDI reset ok"
    assert calls[0] == ([str(tmp_path / "ftdi_reset"), "0x0403", "0x6014"], None)
    assert calls[1][0] == ["sudo", "-A", str(tmp_path / "ftdi_reset"), "0x0403", "0x6014"]
    assert calls[1][1]["SUDO_PROMPT"] == "BL808 hardware harness sudo password: "


def test_target_reset_sudo_flag_still_pulses_no_sudo_first(monkeypatch, tmp_path):
    calls = []
    args = SimpleNamespace(
        attach_openocd=False,
        dry_run=False,
        ftdi_srst_pulse_bin=tmp_path / "ftdi_srst_pulse",
        ftdi_srst_pulse_source=tmp_path / "ftdi_srst_pulse.c",
        ftdi_reset_vid="0x0403",
        ftdi_reset_pid="0x6014",
        ftdi_reset_serial="",
        ftdi_reset_sudo=True,
        ftdi_reset_settle=0,
        sudo_askpass=None,
        sudo_askpass_helper=None,
    )

    def fake_run_logged(cmd, **kwargs):
        calls.append(("srst", cmd, kwargs.get("env")))
        return SimpleNamespace(returncode=0, stdout="")

    def fake_reset_after(_args, _log_path, *, reason):
        calls.append(("ftdi-reset-after", reason))

    monkeypatch.setattr(hw_validate.os, "geteuid", lambda: 501)
    monkeypatch.setattr(
        hw_validate,
        "build_ftdi_srst_pulse_helper",
        lambda _args, _log_path: tmp_path / "ftdi_srst_pulse",
    )
    monkeypatch.setattr(hw_validate, "run_logged", fake_run_logged)
    monkeypatch.setattr(
        hw_validate,
        "reset_ftdi_adapter_after_target_reset",
        fake_reset_after,
    )

    hw_validate.pulse_target_reset_via_ftdi(
        args,
        tmp_path / "reset.log",
        reason="unit reset",
    )

    assert calls == [
        ("srst", [str(tmp_path / "ftdi_srst_pulse"), "0x0403", "0x6014"], None),
        ("ftdi-reset-after", "unit reset"),
    ]


def test_uart_ftdi_reset_conflict_detects_jtag_adapter(monkeypatch):
    args = SimpleNamespace(ftdi_reset_vid="0x0403", ftdi_reset_pid="0x6014")

    monkeypatch.setattr(
        hw_validate,
        "serial_port_usb_ids",
        lambda port: (0x0403, 0x6014, "Single RS232-HS") if port == "/dev/cu.ftdi" else None,
    )

    detail = hw_validate.uart_ftdi_reset_conflict(args, "/dev/cu.ftdi")

    assert detail is not None
    assert "/dev/cu.ftdi is the FTDI JTAG/reset adapter" in detail


def test_uart_ftdi_reset_conflict_ignores_runtime_uart(monkeypatch):
    args = SimpleNamespace(ftdi_reset_vid="0x0403", ftdi_reset_pid="0x6014")

    monkeypatch.setattr(
        hw_validate,
        "serial_port_usb_ids",
        lambda _port: (0x10C4, 0xEA60, "CP2102 USB to UART Bridge Controller"),
    )

    assert hw_validate.uart_ftdi_reset_conflict(args, "/dev/cu.cp2102") is None


def test_serial_port_role_labels_jtag_and_uart_candidates(monkeypatch):
    args = SimpleNamespace(ftdi_reset_vid="0x0403", ftdi_reset_pid="0x6014")
    ports = {
        "/dev/cu.ftdi": (0x0403, 0x6014, "Single RS232-HS"),
        "/dev/cu.cp2102": (0x10C4, 0xEA60, "CP2102 USB to UART Bridge Controller"),
    }

    monkeypatch.setattr(hw_validate, "serial_port_usb_ids", lambda port: ports[port])

    assert hw_validate.serial_port_role(args, "/dev/cu.ftdi") == (
        "jtag/reset VID:PID=0403:6014 Single RS232-HS"
    )
    assert hw_validate.serial_port_role(args, "/dev/cu.cp2102") == (
        "uart candidate VID:PID=10C4:EA60 CP2102 USB to UART Bridge Controller"
    )


def test_ftdi_uart_conflict_blocks_jtag_paths_only():
    base = dict(
        no_jtag=False,
        jtag_load=False,
        jtag_flash=False,
        target_reset_before_capture=False,
        target_reset_before_flash=False,
        lp_jtag_cjtag_escape=False,
    )

    assert not hw_validate.ftdi_uart_conflict_is_blocking(SimpleNamespace(**base))
    assert hw_validate.ftdi_uart_conflict_is_blocking(
        SimpleNamespace(**{**base, "jtag_load": True})
    )
    assert hw_validate.ftdi_uart_conflict_is_blocking(
        SimpleNamespace(**{**base, "target_reset_before_capture": True})
    )
    assert not hw_validate.ftdi_uart_conflict_is_blocking(
        SimpleNamespace(**{**base, "jtag_flash": True, "no_jtag": True})
    )


def test_lp_jtag_switch_stub_activates_pico_clock_divider():
    args = SimpleNamespace(
        jtag_gpio_style="bootrom",
        jtag_gpio_pins=(6, 7, 12, 13),
        lp_jtag_prebring_d0=False,
        lp_jtag_p7_io2_5="unchanged",
        lp_jtag_e902_sel="unchanged",
        lp_jtag_wl_chain="unchanged",
        lp_jtag_p4_adc_test="unchanged",
        lp_jtag_p5_dac_test="unchanged",
    )

    source = hw_validate.jtag_switch_stub_source(
        "lp",
        "m0",
        bringup_target=True,
        args=args,
    )

    assert "# Activate PICO clock divider before enabling the LP clock gate" in source
    assert "li   a0, 0x2000E12C" in source
    assert "li   a0, 0x20000094" in source
    assert "li   a2, 0x00010000" in source
    assert "li   a3, 0x00040000" in source
    assert source.index("0x2000E12C") < source.index("0x2000E110")


def test_cklink_jtag_mux_bootstrap_uses_halt_without_reset():
    args = SimpleNamespace(interface=Path("/opt/homebrew/share/openocd/scripts/interface/cklink.cfg"))

    assert hw_validate.jtag_mux_bootstrap_command(args, reset_target=True) == "halt"
    assert hw_validate.jtag_mux_bootstrap_command(args, reset_target=False) == "halt"


def test_jtag_flash_no_reset_prepares_halt_only_session(monkeypatch, tmp_path):
    seen = []

    class Session:
        log_path = tmp_path / "openocd.log"

        def command(self, command, **_kwargs):
            seen.append(command)

        def close(self):
            seen.append("close")

    def prepare(**kwargs):
        seen.append(kwargs["reset_target"])
        return Session()

    monkeypatch.setattr(hw_validate, "jtag_flash_segments_for_outputs", lambda *a, **kw: [])
    monkeypatch.setattr(hw_validate, "prepare_jtag_session_with_recovery", prepare)
    monkeypatch.setattr(hw_validate, "build_jtag_flash_stub", lambda **kw: tmp_path / "stub.elf")
    monkeypatch.setattr(hw_validate, "jtag_flash_write32", lambda *a, **kw: None)
    monkeypatch.setattr(
        hw_validate,
        "initial_jtag_command_with_recovery",
        lambda _session, command, **_kw: seen.append(command),
    )

    args = SimpleNamespace(jtag_load=False, no_jtag_reset=True, dry_run=True)
    hw_validate.flash_firmware_over_jtag(
        {"name": "scan"}, args=args, defaults={}, work_dir=tmp_path, outputs={}
    )

    assert seen[0] is False
    assert "reset halt" not in seen
    assert seen[-1] == "close"


def test_uart_anchor_flash_no_reset_prepares_halt_only_session(monkeypatch, tmp_path):
    seen = []

    class Session:
        log_path = tmp_path / "openocd.log"

        def command(self, command, **_kwargs):
            seen.append(command)

        def close(self):
            seen.append("close")

    class Serial:
        def reset_input_buffer(self):
            pass

        def reset_output_buffer(self):
            pass

        def close(self):
            pass

    monkeypatch.setattr(hw_validate, "jtag_flash_segments_for_outputs", lambda *a, **kw: [])
    monkeypatch.setattr(hw_validate, "build_uart_flash_anchor", lambda **kw: tmp_path / "anchor.bin")
    monkeypatch.setattr(hw_validate, "prepare_jtag_session_with_recovery",
                        lambda **kw: seen.append(kw["reset_target"]) or Session())
    monkeypatch.setattr(hw_validate, "initial_jtag_command_with_recovery",
                        lambda _session, command, **_kw: seen.append(command))
    monkeypatch.setattr(hw_validate, "open_serial_device", lambda *a, **kw: Serial())
    monkeypatch.setattr(hw_validate, "wait_for_uart_flash_anchor", lambda *a, **kw: None)
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet", lambda *a, **kw: None)
    monkeypatch.setattr(hw_validate, "select_uart_flash_anchor_ack_mode",
                        lambda *a, **kw: "uart")
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_command_checked",
                        lambda *a, **kw: (0x1860EF, 0))

    args = SimpleNamespace(jtag_flash=False, jtag_load=False, no_jtag_reset=True,
                           uart_anchor_existing=False, uart_anchor_reset_after_flash=False,
                           dry_run=False)
    hw_validate.flash_firmware_over_uart_anchor(
        {"name": "hello"}, args=args, defaults={}, work_dir=tmp_path,
        outputs={}, flash_port="/dev/fake", flash_baud=230400, dtr=False, rts=False,
    )

    assert seen[0] is False
    assert "reset halt" not in seen
    assert "halt" in seen
    assert seen[-1] == "close"


def test_existing_uart_anchor_reboots_without_jtag(monkeypatch, tmp_path):
    commands = []

    class Serial:
        def reset_input_buffer(self):
            pass

        def reset_output_buffer(self):
            pass

        def close(self):
            pass

    monkeypatch.setattr(hw_validate, "jtag_flash_segments_for_outputs", lambda *a, **kw: [])
    monkeypatch.setattr(hw_validate, "open_serial_device", lambda *a, **kw: Serial())
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet", lambda *a, **kw: None)
    monkeypatch.setattr(hw_validate, "select_uart_flash_anchor_ack_mode",
                        lambda *a, **kw: "uart")
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_command_checked",
                        lambda _ser, command, **_kw: commands.append(command) or (0x1860EF, 0))
    monkeypatch.setattr(hw_validate, "prepare_jtag_session_with_recovery",
                        lambda **_kw: pytest.fail("existing-anchor path must not attach JTAG"))

    args = SimpleNamespace(jtag_flash=False, jtag_load=False, no_jtag=True,
                           uart_anchor_existing=True, uart_anchor_reset_after_flash=True,
                           dry_run=False)
    hw_validate.flash_firmware_over_uart_anchor(
        {"name": "hello"}, args=args, defaults={}, work_dir=tmp_path,
        outputs={}, flash_port="/dev/fake", flash_baud=230400, dtr=False, rts=False,
    )

    assert commands == [hw_validate.UART_FLASH_CMD_READ_ID,
                        hw_validate.UART_FLASH_CMD_REBOOT]


def test_existing_uart_anchor_reboot_only_uses_uart(monkeypatch, tmp_path):
    commands = []

    class Serial:
        def reset_input_buffer(self):
            pass

        def reset_output_buffer(self):
            pass

        def close(self):
            pass

    monkeypatch.setattr(hw_validate, "configure_sudo_askpass", lambda *_args: None)
    monkeypatch.setattr(hw_validate, "open_serial_device", lambda *a, **kw: Serial())
    monkeypatch.setattr(hw_validate, "serial_drain_until_quiet", lambda *a, **kw: None)
    monkeypatch.setattr(hw_validate, "select_uart_flash_anchor_ack_mode",
                        lambda *a, **kw: "uart")
    monkeypatch.setattr(hw_validate, "uart_flash_anchor_command_checked",
                        lambda _ser, command, **_kw: commands.append(command) or (0x1860EF, 0))
    monkeypatch.setattr(hw_validate, "prepare_jtag_session_with_recovery",
                        lambda **_kw: pytest.fail("existing-anchor reboot must not attach JTAG"))

    args = SimpleNamespace(work_dir=tmp_path, no_jtag=True,
                           uart_anchor_existing=True, uart_anchor_reboot=True,
                           flash_port=None, uart="/dev/fake", flash_baud=None,
                           uart_baud=None, serial_dtr="off", serial_rts="off",
                           dry_run=False)
    assert hw_validate.run_uart_anchor_probe(args, {"defaults": {}}) == 0
    assert commands == [hw_validate.UART_FLASH_CMD_READ_ID,
                        hw_validate.UART_FLASH_CMD_REBOOT]


def test_nim_uart_anchor_implements_reboot_command():
    source = (hw_validate.REPO_ROOT / "examples" / "m0_uart_flash_anchor.nim").read_text()

    assert f"CmdReboot = {hw_validate.UART_FLASH_CMD_REBOOT}'u32" in source
    assert "of CmdReboot:" in source
    assert "rebootAfterResponse = true" in source
    assert "prepareForSoftReboot()" in source
    assert "l1cInvalidateAll()" in source
    assert "fenceI()" in source
    assert "rebootChip()" in source
    assert "PowerOnReset = 1'u32 shl 0" in source


def test_ram_uart_anchor_syncs_cache_before_reboot():
    source = (hw_validate.REPO_ROOT / "tools" / "uart_flash_anchor.c").read_text()

    assert "static void cache_sync_before_reboot(void)" in source
    assert '".long 0x0010000b"' in source
    assert '".long 0x0020000b"' in source
    assert '".long 0x0100000b"' in source
    assert '".long 0x0000100f"' in source
    reboot_body = source.split("static void reboot_chip(void)", 1)[1].split(
        "static int sf_wait_idle", 1
    )[0]
    assert "cache_sync_before_reboot();" in reboot_body
    assert "value |= (1u << 0);" in reboot_body
    assert "value |= (1u << 5);" not in reboot_body


def test_ram_uart_anchor_guards_flash_against_inherited_watchdog():
    source = (hw_validate.REPO_ROOT / "tools" / "uart_flash_anchor.c").read_text()
    disarm, main = source.split("static int stop_inherited_watchdog(void)", 1)[1].split(
        "void main(void)", 1
    )
    writes = ["write32(GLB_CGEN_CFG1", "write32(TIMER0_WFAR, 0xBABAu)",
              "write32(TIMER0_WSAR, 0xEB10u)", "write32(TIMER0_WMER, mode)"]
    offsets = [disarm.index(write) for write in writes]
    assert offsets == sorted(offsets)
    assert "read32(TIMER0_WMER) & ~TIMER0_WDT_MODE" in disarm
    assert disarm.index("return (read32(TIMER0_WMER)") > offsets[-1]
    assert main.index("stop_inherited_watchdog()") < main.index("uart0_init(")
    guard = re.search(r"!watchdog_stopped\s*&&\s*"
                      r"\(req.command == CMD_ERASE \|\| req.command == CMD_WRITE_VERIFY\)"
                      r"\)\s*\{\s*status = ERR_TIMEOUT;", main)
    assert guard is not None
    assert guard.end() < main.index("status = (uint32_t)flash_program_verify(")
    assert guard.end() < main.index("flash_erase_range(req.address")


def test_compact_flash_image_places_segments(tmp_path):
    first = tmp_path / "first.bin"
    second = tmp_path / "second.bin"
    first.write_bytes(b"ABCD")
    second.write_bytes(b"xy")

    image = hw_validate.build_compact_flash_image([
        hw_validate.JtagFlashSegment(0x10, first, "first"),
        hw_validate.JtagFlashSegment(0x20, second, "second"),
    ])

    assert len(image) == 0x22
    assert image[0x10:0x14] == b"ABCD"
    assert image[0x14:0x20] == b"\xFF" * 12
    assert image[0x20:0x22] == b"xy"


def test_fw_bootinfo_template_env_override(monkeypatch, tmp_path):
    template = tmp_path / "bootinfo.bin"
    template.write_bytes(b"header")
    monkeypatch.setenv("BL808_FW_BOOTINFO", str(template))
    assert hw_validate.find_default_fw_bootinfo_template() == template

    template.unlink()
    with pytest.raises(RuntimeError, match="BL808_FW_BOOTINFO points to a missing file"):
        hw_validate.find_default_fw_bootinfo_template()


def test_fw_bootinfo_fallback_preserves_bl808_flash_table(monkeypatch):
    monkeypatch.delenv("BL808_FW_BOOTINFO", raising=False)
    monkeypatch.setitem(sys.modules, "bflb_iot_tool", None)

    raw_fw = b"Nim BL808 test image"
    entry = 0x58000000
    image = hw_validate.build_fw_boot2_image(raw_fw, m0_boot_entry=entry)
    assert image == build_bl808_boot2_flash.build_fw_image(raw_fw, None, m0_boot_entry=entry)
    assert image[:4] == b"BFNP" and image[8:12] == b"FCFG"
    assert image[0x64:0x68] == b"PCFG"
    assert struct.unpack_from("<I", image, 0x84)[0] == 0x1000
    assert struct.unpack_from("<II", image, 0xBC) == (0, entry)
    table, table_size = struct.unpack_from("<II", image, 0x100)
    assert (table, table_size) == (0x160, 0x1C8)
    assert image[table:table + 4] == b"FCTG"
    assert struct.unpack_from("<I", image, 0x15C)[0] == hw_validate.bootheader_crc32(image[:0x15C])
    assert image[0x1000:0x1000 + len(raw_fw)] == raw_fw


def test_fw_bootinfo_rejects_truncated_override(monkeypatch, tmp_path):
    template = tmp_path / "bad.bin"
    template.write_bytes(b"BFNP\0\0\0\0FCFG")
    monkeypatch.setenv("BL808_FW_BOOTINFO", str(template))
    with pytest.raises(RuntimeError, match="bootinfo template must be 0x160..0x1000 bytes"):
        hw_validate.build_fw_boot2_image(b"Nim BL808 test image")


def test_fw_boot2_image_recomputes_bootinfo_crc(monkeypatch, tmp_path):
    template = bytearray(b"\xFF" * 0x200)
    template[0x00:0x04] = hw_validate.BL808_BOOTHEADER_MAGIC_BFNP.to_bytes(4, "little")
    template[0x08:0x0C] = hw_validate.BL808_BOOTHEADER_FLASH_CFG_MAGIC.to_bytes(4, "little")
    template[0x15C:0x160] = (0xDEADBEEF).to_bytes(4, "little")
    template_path = tmp_path / "bootinfo.bin"
    template_path.write_bytes(template)

    monkeypatch.setattr(hw_validate, "find_default_fw_bootinfo_template", lambda: template_path)

    image = hw_validate.build_fw_boot2_image(b"FW")

    stored_crc = int.from_bytes(image[0x15C:0x160], "little")
    expected_crc = hw_validate.bootheader_crc32(image[:0x15C])
    assert stored_crc == expected_crc
    assert stored_crc != 0xDEADBEEF
    assert image[0x90:0xB0] == hashlib.sha256(b"FW" + (b"\x00" * 14)).digest()
    assert int.from_bytes(image[0x8C:0x90], "little") == 16
    assert image[hw_validate.BL808_FW_BOOTINFO_SIZE:hw_validate.BL808_FW_BOOTINFO_SIZE + 2] == b"FW"


def test_fw_boot2_image_patches_m0_boot_entry(monkeypatch, tmp_path):
    template = bytearray(b"\xFF" * 0x200)
    template[0x00:0x04] = hw_validate.BL808_BOOTHEADER_MAGIC_BFNP.to_bytes(4, "little")
    template[0x08:0x0C] = hw_validate.BL808_BOOTHEADER_FLASH_CFG_MAGIC.to_bytes(4, "little")
    template[hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
             hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4] = (
        (0x58000000).to_bytes(4, "little")
    )
    template[0x15C:0x160] = (0xDEADBEEF).to_bytes(4, "little")
    template_path = tmp_path / "bootinfo.bin"
    template_path.write_bytes(template)

    monkeypatch.setattr(hw_validate, "find_default_fw_bootinfo_template", lambda: template_path)

    image = hw_validate.build_fw_boot2_image(b"FW", m0_boot_entry=0x62020000)

    entry = int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4
        ],
        "little",
    )
    assert entry == 0x62020000
    image_address = int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4
        ],
        "little",
    )
    assert image_address == 0x22020000
    bootcfg = int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_BOOTCFG_OFFSET:
            hw_validate.BL808_BOOTHEADER_BOOTCFG_OFFSET + 4
        ],
        "little",
    )
    assert bootcfg & hw_validate.BL808_BOOTCFG_NO_SEGMENT_MASK == 0
    assert int.from_bytes(
        image[
            hw_validate.BL808_BOOTCFG_IMG_LEN_COUNT_OFFSET:
            hw_validate.BL808_BOOTCFG_IMG_LEN_COUNT_OFFSET + 4
        ],
        "little",
    ) == 1
    fw_body = image[hw_validate.BL808_FW_BOOTINFO_SIZE:]
    assert fw_body[:4] == (0x22020000).to_bytes(4, "little")
    assert fw_body[4:8] == (16).to_bytes(4, "little")
    assert int.from_bytes(fw_body[8:12], "little") == hw_validate.bootheader_crc32(
        b"FW" + (b"\x00" * 14)
    )
    assert int.from_bytes(fw_body[12:16], "little") == hw_validate.bootheader_crc32(
        fw_body[:12]
    )
    assert fw_body[16:18] == b"FW"
    assert image[0x90:0xB0] == hashlib.sha256(fw_body).digest()
    assert int.from_bytes(image[0x15C:0x160], "little") == (
        hw_validate.bootheader_crc32(image[:0x15C])
    )


def test_fw_boot2_image_patches_xip_m0_image_offset(monkeypatch, tmp_path):
    template = bytearray(b"\xFF" * 0x200)
    template[0x00:0x04] = hw_validate.BL808_BOOTHEADER_MAGIC_BFNP.to_bytes(4, "little")
    template[0x08:0x0C] = hw_validate.BL808_BOOTHEADER_FLASH_CFG_MAGIC.to_bytes(4, "little")
    template[hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
             hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4] = (
        (0x2000).to_bytes(4, "little")
    )
    template[hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
             hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4] = (
        (0x2000).to_bytes(4, "little")
    )
    template_path = tmp_path / "bootinfo.bin"
    template_path.write_bytes(template)

    monkeypatch.setattr(hw_validate, "find_default_fw_bootinfo_template", lambda: template_path)

    image = hw_validate.build_fw_boot2_image(b"FW", m0_boot_entry=0x58000000)

    image_offset = int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4
        ],
        "little",
    )
    entry = int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4
        ],
        "little",
    )
    fw_body = image[hw_validate.BL808_FW_BOOTINFO_SIZE:]

    assert image_offset == 0
    assert entry == 0x58000000
    assert int.from_bytes(
        image[
            hw_validate.BL808_BOOTCFG_IMG_LEN_COUNT_OFFSET:
            hw_validate.BL808_BOOTCFG_IMG_LEN_COUNT_OFFSET + 4
        ],
        "little",
    ) == 16
    assert fw_body[:2] == b"FW"
    assert image[0x90:0xB0] == hashlib.sha256(b"FW" + (b"\x00" * 14)).digest()
    assert int.from_bytes(image[0x15C:0x160], "little") == (
        hw_validate.bootheader_crc32(image[:0x15C])
    )


def test_fw_boot2_image_loads_cached_ram_entry_via_uncached_alias(monkeypatch, tmp_path):
    template = bytearray(b"\xFF" * 0x200)
    template[0x00:0x04] = hw_validate.BL808_BOOTHEADER_MAGIC_BFNP.to_bytes(4, "little")
    template[0x08:0x0C] = hw_validate.BL808_BOOTHEADER_FLASH_CFG_MAGIC.to_bytes(4, "little")
    template[hw_validate.BL808_BOOTHEADER_BOOTCFG_OFFSET:
             hw_validate.BL808_BOOTHEADER_BOOTCFG_OFFSET + 4] = (
        hw_validate.BL808_BOOTCFG_NO_SEGMENT_MASK.to_bytes(4, "little")
    )
    template_path = tmp_path / "bootinfo.bin"
    template_path.write_bytes(template)

    monkeypatch.setattr(hw_validate, "find_default_fw_bootinfo_template", lambda: template_path)

    image = hw_validate.build_fw_boot2_image(b"FW", m0_boot_entry=0x62020000)
    fw_body = image[hw_validate.BL808_FW_BOOTINFO_SIZE:]

    assert int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_BOOT_ENTRY_OFFSET + 4
        ],
        "little",
    ) == 0x62020000
    assert int.from_bytes(
        image[
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET:
            hw_validate.BL808_BOOTHEADER_M0_IMAGE_ADDRESS_OFFSET + 4
        ],
        "little",
    ) == 0x22020000
    assert int.from_bytes(fw_body[0:4], "little") == 0x22020000
    assert fw_body[16:18] == b"FW"


def test_elf_start_address_parses_objdump(monkeypatch, tmp_path):
    elf = tmp_path / "anchor.elf"
    elf.write_bytes(b"ELF")

    def fake_run(cmd, **kwargs):
        assert cmd == ["riscv64-unknown-elf-objdump", "-f", str(elf)]
        assert kwargs["cwd"] == hw_validate.REPO_ROOT
        return SimpleNamespace(
            returncode=0,
            stdout="file format elf32-littleriscv\nstart address 0x62020000\n",
            stderr="",
        )

    monkeypatch.setattr(hw_validate.subprocess, "run", fake_run)

    assert hw_validate.elf_start_address(elf) == 0x62020000


def test_m0_jtag_flash_segments_wraps_fw_with_elf_entry(monkeypatch, tmp_path):
    boot2_path = tmp_path / "boot2.bin"
    boot2_path.write_bytes(b"BOOT2")
    elf = tmp_path / "anchor.elf"
    elf.write_bytes(b"ELF")
    fw = tmp_path / "anchor.bin"
    fw.write_bytes(b"ANCHOR")
    seen_entries = []

    def fake_build_fw_boot2_image(raw_fw, *, m0_boot_entry=None):
        seen_entries.append(m0_boot_entry)
        return b"WRAPPED:" + raw_fw

    monkeypatch.setattr(hw_validate, "find_default_boot2_image", lambda: boot2_path)
    monkeypatch.setattr(hw_validate, "patch_boot2_partition_offsets", lambda image, **_: image)
    monkeypatch.setattr(hw_validate, "build_fw_boot2_image", fake_build_fw_boot2_image)
    monkeypatch.setattr(hw_validate, "elf_start_address", lambda path: 0x62020000)

    output = hw_validate.BuildOutput(
        build_id="anchor",
        core="bl808m0",
        source="tools/uart_flash_anchor.c",
        elf=elf,
        bin=fw,
        flash_core="m0",
    )

    segments = hw_validate.build_m0_jtag_flash_segments(
        output,
        args=SimpleNamespace(dry_run=False),
        work_dir=tmp_path / "work",
        test_name="anchor-test",
    )

    assert seen_entries == [0x62020000]
    fw_segment = next(segment for segment in segments if segment.label == "anchor:FW")
    assert fw_segment.path.read_bytes() == b"WRAPPED:ANCHOR"


def test_uart_anchor_build_only_dry_run(monkeypatch, tmp_path, capsys):
    argv = [
        "hw_validate.py",
        "--uart-anchor-build-only",
        "--dry-run",
        "--work-dir",
        str(tmp_path / "work"),
    ]
    monkeypatch.setattr(sys, "argv", argv)

    assert hw_validate.main() == 0
    out = capsys.readouterr().out
    assert "UART-anchor build-only" in out
    assert "DRY-RUN: build persistent UART anchor flash image" in out


def test_uart_anchor_build_only_writes_recovery_manifest(monkeypatch, tmp_path, capsys):
    def fake_build_uart_flash_anchor(*, args, work_dir, test_name, flash_baud):
        out_dir = work_dir / "anchor"
        out_dir.mkdir(parents=True)
        anchor = out_dir / "uart_flash_anchor.bin"
        anchor.write_bytes(b"ANCHOR")
        anchor.with_suffix(".elf").write_bytes(b"ELF")
        return anchor

    def fake_build_persistent_uart_flash_anchor(anchor, *, args, work_dir, test_name):
        out_dir = work_dir / "persistent"
        out_dir.mkdir(parents=True)
        wrapper = out_dir / "uart_flash_anchor_persistent.bin"
        wrapper.write_bytes(b"WRAP" + anchor.read_bytes())
        elf = out_dir / "uart_flash_anchor_persistent.elf"
        elf.write_bytes(b"ELF")
        return hw_validate.BuildOutput(
            build_id="uart_anchor_persistent",
            core="bl808m0",
            source="tools/uart_flash_anchor_persistent.S",
            elf=elf,
            bin=wrapper,
            flash_core="m0",
        )

    def fake_build_m0_jtag_flash_segments(output, *, args, work_dir, test_name):
        seg_dir = work_dir / "segments"
        seg_dir.mkdir(parents=True)
        boot2 = seg_dir / "boot2.bin"
        fw = seg_dir / "fw.bin"
        boot2.write_bytes(b"B2")
        fw.write_bytes(
            (b"H" * hw_validate.BL808_FW_BOOTINFO_SIZE)
            + output.bin.read_bytes()
        )
        return [
            hw_validate.JtagFlashSegment(0, boot2, "boot2"),
            hw_validate.JtagFlashSegment(hw_validate.BL808_FLASH_OFFSET_FW, fw, "FW"),
        ]

    monkeypatch.setattr(hw_validate, "build_uart_flash_anchor", fake_build_uart_flash_anchor)
    monkeypatch.setattr(
        hw_validate,
        "build_persistent_uart_flash_anchor",
        fake_build_persistent_uart_flash_anchor,
    )
    monkeypatch.setattr(hw_validate, "build_m0_jtag_flash_segments", fake_build_m0_jtag_flash_segments)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--uart-anchor-build-only",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    out = capsys.readouterr().out
    manifest_path = tmp_path / "work" / "uart-anchor-persistent" / "recovery_manifest.json"
    image_path = tmp_path / "work" / "uart-anchor-persistent" / "whole_flash_data.bin"
    assert "recovery_manifest=" in out
    assert image_path.read_bytes()[0:2] == b"B2"
    anchor_flash_offset = hw_validate.BL808_FLASH_OFFSET_FW + hw_validate.BL808_FW_BOOTINFO_SIZE + 4
    assert image_path.read_bytes()[anchor_flash_offset:anchor_flash_offset + 6] == b"ANCHOR"

    recovery = json.loads(manifest_path.read_text())
    assert recovery["kind"] == "bl808-uart-anchor-recovery"
    assert recovery["baud"] == 230400
    assert recovery["anchor_size"] == 6
    assert recovery["whole_flash_size"] == anchor_flash_offset + 6
    assert recovery["anchor_payload"]["flash_offset"] == anchor_flash_offset
    assert recovery["anchor_payload"]["flash_offset_hex"] == f"0x{anchor_flash_offset:06X}"
    assert recovery["anchor_payload"]["persistent_wrapper_payload_offset"] == 4
    assert recovery["anchor_payload"]["matches_expected_boot2_wrapped_offset"]
    assert recovery["segments"][1]["address"] == hw_validate.BL808_FLASH_OFFSET_FW
    assert recovery["commands"]["install_with_existing_anchor"].startswith(
        f"{sys.executable} {Path(hw_validate.__file__).resolve()}"
    )
    assert "--uart-anchor-flash-image" in recovery["commands"]["install_with_existing_anchor"]
    assert recovery["commands"]["install_with_uart_boot"].startswith(
        str(hw_validate.REPO_ROOT / "tools" / "upload.sh")
    )


def test_existing_anchor_probe_dry_run_allows_no_jtag(monkeypatch, tmp_path, capsys):
    argv = [
        "hw_validate.py",
        "--uart-anchor-probe",
        "--uart-anchor-existing",
        "--no-jtag",
        "--uart",
        "/dev/cu.test",
        "--dry-run",
        "--work-dir",
        str(tmp_path / "work"),
    ]
    monkeypatch.setattr(sys, "argv", argv)

    assert hw_validate.main() == 0
    out = capsys.readouterr().out
    assert "probe existing UART flash anchor" in out


def test_existing_anchor_prebuilt_dry_run_allows_no_jtag(monkeypatch, tmp_path, capsys):
    argv = [
        "hw_validate.py",
        "--uart-anchor-flash-image",
        str(tmp_path / "missing.bin"),
        "--uart-anchor-existing",
        "--no-jtag",
        "--uart-anchor-reset-after-flash",
        "--uart",
        "/dev/cu.test",
        "--dry-run",
        "--work-dir",
        str(tmp_path / "work"),
    ]
    monkeypatch.setattr(sys, "argv", argv)

    assert hw_validate.main() == 0
    out = capsys.readouterr().out
    assert "use existing UART flash anchor" in out
    assert "UART-anchor flash prebuilt" in out
    assert "UART-anchor reboot target" in out


@pytest.mark.parametrize(("size", "end", "expected"), [
    (0xD0000, 0xE0000, "erase_limit=0x0E0000"),
    (0xD0001, 0xE0001, "0x0E1000 exceeds allowed end 0x0E0001"),
    (857_040, 0xE0000, "0x0E2000 exceeds allowed end 0x0E0000"),
    (0xD0000, None, "requires --uart-anchor-flash-image-end"),
])
def test_prebuilt_m0_checks_erase_limit_before_transport(
    monkeypatch, tmp_path, capsys, size, end, expected
):
    image = tmp_path / "m0.bin"
    image.write_bytes(bytes(size))
    builds = []
    monkeypatch.setattr(hw_validate, "build_uart_flash_anchor",
                        lambda **_: builds.append("anchor") or tmp_path / "anchor.bin")
    argv = ["hw_validate.py", "--uart-anchor-flash-image", str(image),
            "--uart-anchor-flash-image-address", "0x10000", "--dry-run",
            "--work-dir", str(tmp_path / "work")]
    if end is not None:
        argv += ["--uart-anchor-flash-image-end", hex(end)]
    monkeypatch.setattr(sys, "argv", argv)
    accepted = size == 0xD0000 and end is not None
    assert hw_validate.main() == (0 if accepted else 2)
    assert builds == (["anchor"] if accepted else [])
    assert expected in capsys.readouterr().out


def test_prebuilt_erase_limit_rechecks_actual_bytes_before_erase(tmp_path):
    image = tmp_path / "m0.bin"
    image.write_bytes(bytes(0x1001))
    segment = hw_validate.JtagFlashSegment(0x10000, image, "changed", erase_limit=0x11000)
    with pytest.raises(RuntimeError, match="exceeds allowed end"):
        hw_validate.uart_anchor_flash_program_segment(None, segment, args=SimpleNamespace(dry_run=False))


def test_uart_anchor_flash_defaults_to_target_reset_before_capture(
    monkeypatch,
    tmp_path,
    capsys,
):
    flashed = []
    reset_reasons = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_uart_anchor(test, **kwargs):
        flashed.append(test["name"])

    def fake_pulse_target_reset(args, log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(
        hw_validate,
        "flash_firmware_over_uart_anchor",
        fake_flash_firmware_over_uart_anchor,
    )
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_pulse_target_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            "m0_wifi_nimfw_boot_test",
            "--uart-anchor-flash",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == ["m0_wifi_nimfw_boot_test"]
    assert reset_reasons == ["after UART anchor flash before UART capture"]
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" in out


def test_uart_anchor_runtime_jtag_runs_breakpoint_snapshots(
    monkeypatch,
    tmp_path,
    capsys,
):
    flashed = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_uart_anchor(test, **kwargs):
        flashed.append(test["name"])

    def fake_elf_symbol_addresses(elf, names, *, required):
        assert elf == Path("build/fake.elf")
        assert not required
        return {
            "nimfw_dbg_dhcp_tx_final_breakpoint": 0x58019BA6,
            "nimfw_dbg_dhcp_tx_desc_bytes": 0x62021170,
        }

    def fail_ftdi_reset(*_args, **_kwargs):
        raise AssertionError("anchor reboot path must not pulse FTDI nSRST")

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(
        hw_validate,
        "flash_firmware_over_uart_anchor",
        fake_flash_firmware_over_uart_anchor,
    )
    monkeypatch.setattr(hw_validate, "elf_symbol_addresses", fake_elf_symbol_addresses)
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fail_ftdi_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            "m0_wifi_lwip_smoke",
            "--uart-anchor-flash",
            "--uart-anchor-runtime-jtag",
            "--uart-anchor-reset-after-flash",
            "--jtag-breakpoint-symbol",
            "nimfw_dbg_dhcp_tx_final_breakpoint",
            "--jtag-breakpoint-timeout",
            "1",
            "--jtag-breakpoint-snapshot-command",
            "mdw {sym:nimfw_dbg_dhcp_tx_desc_bytes} 1",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == ["m0_wifi_lwip_smoke"]
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" not in out

    openocd_log = (
        tmp_path
        / "work"
        / "logs"
        / "m0_wifi_lwip_smoke.m0.openocd.dry-run.log"
    )
    openocd_text = openocd_log.read_text()
    assert "# JTAG breakpoint nimfw_dbg_dhcp_tx_final_breakpoint at 0x58019BA6" in openocd_text
    assert "DRY-RUN openocd> bp 0x58019BA6 2 hw" in openocd_text
    assert "DRY-RUN openocd> resume" in openocd_text
    assert "DRY-RUN openocd> wait_halt 1000" in openocd_text
    assert "DRY-RUN openocd> mdw 0x62021170 1" in openocd_text
    assert "DRY-RUN openocd> rbp 0x58019BA6" in openocd_text


@pytest.mark.parametrize("no_jtag_reset", [False, True])
def test_jtag_flash_runtime_attach_respects_no_jtag_reset(
    monkeypatch,
    tmp_path,
    capsys,
    no_jtag_reset,
):
    flashed = []
    reset_reasons = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_jtag(test, **kwargs):
        flashed.append(test["name"])

    def fake_pulse_target_reset(args, log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(hw_validate, "flash_firmware_over_jtag", fake_flash_firmware_over_jtag)
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_pulse_target_reset)
    argv = [
        "hw_validate.py",
        "--test",
        "m0_ble_hal_test",
        "--jtag-flash",
        "--uart",
        "/dev/cu.test",
        "--dry-run",
        "--work-dir",
        str(tmp_path / "work"),
    ]
    if no_jtag_reset:
        argv.append("--no-jtag-reset")
    monkeypatch.setattr(sys, "argv", argv)

    assert hw_validate.main() == 0
    assert flashed == ["m0_ble_hal_test"]
    assert reset_reasons == (
        ["after JTAG flash before UART/JTAG capture"] if no_jtag_reset else []
    )
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" not in out

    openocd_log = (
        tmp_path
        / "work"
        / "logs"
        / "m0_ble_hal_test.m0.openocd.dry-run.log"
    )
    openocd_text = openocd_log.read_text()
    expected = "halt" if no_jtag_reset else "reset halt"
    assert f"DRY-RUN openocd> {expected}" in openocd_text
    if no_jtag_reset:
        assert "DRY-RUN openocd> reset halt" not in openocd_text
    assert "DRY-RUN openocd> resume" in openocd_text


def test_jtag_flash_reset_capture_manifest_can_opt_out_of_runtime_jtag(
    monkeypatch,
    tmp_path,
    capsys,
):
    flashed = []
    reset_reasons = []
    manifest = {
        "defaults": {
            "uart_baud": 230400,
            "openocd_interface": "pine64jtag.cfg",
            "openocd_target": "tgt_e907_v2.cfg",
            "forbidden": [],
            "jtag_snapshot": [],
        },
        "tests": [
            {
                "name": "jtag_reset_capture_opt_out_test",
                "tiers": ["smoke"],
                "build": [
                    {
                        "id": "kernel",
                        "core": "bl808m0",
                        "source": "examples/m0_ble_hal_test.nim",
                        "flash": "m0",
                    }
                ],
                "jtag_flash_reset_capture": True,
                "jtag_flash_runtime_jtag": False,
                "required": [],
            }
        ],
    }
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_jtag(test, **kwargs):
        flashed.append(test["name"])

    def fake_pulse_target_reset(args, log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(hw_validate, "flash_firmware_over_jtag", fake_flash_firmware_over_jtag)
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_pulse_target_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--manifest",
            str(manifest_path),
            "--test",
            "jtag_reset_capture_opt_out_test",
            "--jtag-flash",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == ["jtag_reset_capture_opt_out_test"]
    assert reset_reasons == ["after JTAG flash before UART/JTAG capture"]
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" in out


def test_jtag_flash_reset_capture_manifest_can_keep_runtime_jtag(
    monkeypatch,
    tmp_path,
    capsys,
):
    flashed = []
    reset_reasons = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_jtag(test, **kwargs):
        flashed.append(test["name"])

    def fake_pulse_target_reset(args, log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(hw_validate, "flash_firmware_over_jtag", fake_flash_firmware_over_jtag)
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_pulse_target_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            "m0_ble_wifi_nim_scan_hal_test",
            "--jtag-flash",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == ["m0_ble_wifi_nim_scan_hal_test"]
    assert reset_reasons == []
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" not in out

    openocd_log = (
        tmp_path
        / "work"
        / "logs"
        / "m0_ble_wifi_nim_scan_hal_test.m0.openocd.dry-run.log"
    )
    openocd_text = openocd_log.read_text()
    assert "DRY-RUN openocd> reset halt" in openocd_text
    assert "DRY-RUN openocd> resume" in openocd_text


def test_jtag_flash_chunk_size_manifest_default_can_be_overridden(
    monkeypatch,
    tmp_path,
):
    seen_chunk_sizes = []
    manifest = {
        "defaults": {
            "uart_baud": 230400,
            "openocd_interface": "pine64jtag.cfg",
            "openocd_target": "tgt_e907_v2.cfg",
            "forbidden": [],
            "jtag_snapshot": [],
        },
        "tests": [
            {
                "name": "chunk_size_manifest_test",
                "tiers": ["smoke"],
                "build": [
                    {
                        "id": "kernel",
                        "core": "bl808m0",
                        "source": "examples/m0_hello_nim_test.nim",
                        "flash": "m0",
                    }
                ],
                "jtag_flash_chunk_size": 1024,
                "required": [],
            }
        ],
    }
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_jtag(test, **kwargs):
        seen_chunk_sizes.append(kwargs["args"].jtag_flash_chunk_size)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(hw_validate, "flash_firmware_over_jtag", fake_flash_firmware_over_jtag)

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--manifest",
            str(manifest_path),
            "--test",
            "chunk_size_manifest_test",
            "--jtag-flash",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work-a"),
        ],
    )
    assert hw_validate.main() == 0

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--manifest",
            str(manifest_path),
            "--test",
            "chunk_size_manifest_test",
            "--jtag-flash",
            "--jtag-flash-chunk-size",
            "2048",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work-b"),
        ],
    )
    assert hw_validate.main() == 0

    assert seen_chunk_sizes == [1024, 2048]


def test_jtag_flash_program_segment_retries_verify_mismatch(monkeypatch, tmp_path):
    segment_path = tmp_path / "segment.bin"
    segment_path.write_bytes(b"A" * 32)
    lp_offset = hw_validate.JTAG_FLASH_LP_OFFSET
    segment = hw_validate.JtagFlashSegment(lp_offset, segment_path, "lp")
    log_path = tmp_path / "openocd.log"
    session = SimpleNamespace(
        log_path=log_path,
        commands=[],
        command=lambda command, timeout_s=5: session.commands.append(command) or "",
    )
    calls = []
    write_verify_calls = 0

    def fake_run_jtag_flash_command(_session, command, **kwargs):
        nonlocal write_verify_calls
        calls.append((command, kwargs["address"], kwargs["length"]))
        if command == hw_validate.JTAG_FLASH_CMD_WRITE_VERIFY:
            write_verify_calls += 1
        if command == hw_validate.JTAG_FLASH_CMD_WRITE_VERIFY and write_verify_calls == 2:
            raise RuntimeError(
                "JTAG flash command 3 failed: result=0x00000005"
            )
        return 0

    monkeypatch.setattr(
        hw_validate,
        "run_jtag_flash_command",
        fake_run_jtag_flash_command,
    )

    hw_validate.jtag_flash_program_segment(
        session,
        segment,
        args=SimpleNamespace(dry_run=False, jtag_flash_chunk_size=32),
        work_dir=tmp_path / "work",
        test_name="retry_test",
    )

    assert calls == [
        (hw_validate.JTAG_FLASH_CMD_ERASE, lp_offset, 0x10000),
        (hw_validate.JTAG_FLASH_CMD_WRITE_VERIFY, lp_offset, 32),
        (hw_validate.JTAG_FLASH_CMD_WRITE_VERIFY, lp_offset, 32),
        (hw_validate.JTAG_FLASH_CMD_WRITE_VERIFY, lp_offset, 32),
    ]
    assert session.commands.count(
        f"load_image {tmp_path / 'work' / 'jtag-flash' / 'retry_test' / 'chunk.bin'} "
        f"0x{hw_validate.JTAG_FLASH_DATA:08X} bin"
    ) == 3
    assert f"retry JTAG flash write_verify addr=0x{lp_offset:06X}" in log_path.read_text()


def test_jtag_flash_reset_capture_can_keep_runtime_jtag(
    monkeypatch,
    tmp_path,
    capsys,
):
    flashed = []
    reset_reasons = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_jtag(test, **kwargs):
        flashed.append(test["name"])

    def fake_pulse_target_reset(args, log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(hw_validate, "flash_firmware_over_jtag", fake_flash_firmware_over_jtag)
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_pulse_target_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            "m0_ble_hal_test",
            "--jtag-flash",
            "--jtag-flash-runtime-jtag",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == ["m0_ble_hal_test"]
    assert reset_reasons == []
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" not in out

    openocd_log = (
        tmp_path
        / "work"
        / "logs"
        / "m0_ble_hal_test.m0.openocd.dry-run.log"
    )
    openocd_text = openocd_log.read_text()
    assert "DRY-RUN openocd> reset halt" in openocd_text
    assert "DRY-RUN openocd> resume" in openocd_text


def test_jtag_flash_runtime_jtag_requires_jtag_flash(monkeypatch, tmp_path):
    def fail_build_firmware(*_args, **_kwargs):
        raise AssertionError("argument validation should run before build")

    monkeypatch.setattr(hw_validate, "build_firmware", fail_build_firmware)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            "m0_ble_wifi_nim_scan_hal_test",
            "--jtag-flash-runtime-jtag",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / "work"),
        ],
    )

    assert hw_validate.main() == 1


@pytest.mark.parametrize(
    "test_name",
    [
        "m0_wifi_hal_test",
        "m0_wifi_nimfw_hal_test",
        "m0_ble_hal_test",
        "m0_ble_nim_controller_hal_test",
        "m0_ble_central_hal_test",
        "m0_ble_nim_controller_central_hal_test",
        "m0_ble_wifi_nim_hal_test",
    ],
)
def test_wireless_tests_dry_run_with_existing_anchor_reboot_no_jtag(
    monkeypatch,
    tmp_path,
    capsys,
    test_name,
):
    flashed = []

    def fake_build_firmware(test, *, args, work_dir):
        return {
            "kernel": hw_validate.BuildOutput(
                build_id="kernel",
                core="bl808m0",
                source=test["build"][0]["source"],
                elf=Path("build/fake.elf"),
                bin=Path("build/fake.bin"),
                flash_core="m0",
            )
        }

    def fake_flash_firmware_over_uart_anchor(test, **kwargs):
        args = kwargs["args"]
        assert args.uart_anchor_existing
        assert args.uart_anchor_reset_after_flash
        assert args.no_jtag
        flashed.append(test["name"])

    reset_reasons = []

    def fake_ftdi_reset(_args, _log_path, *, reason):
        reset_reasons.append(reason)

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(
        hw_validate,
        "flash_firmware_over_uart_anchor",
        fake_flash_firmware_over_uart_anchor,
    )
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fake_ftdi_reset)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hw_validate.py",
            "--test",
            test_name,
            "--uart-anchor-flash",
            "--uart-anchor-existing",
            "--uart-anchor-reset-after-flash",
            "--no-jtag",
            "--uart",
            "/dev/cu.test",
            "--dry-run",
            "--work-dir",
            str(tmp_path / test_name),
        ],
    )

    assert hw_validate.main() == 0
    assert flashed == [test_name]
    assert reset_reasons == []
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" in out
