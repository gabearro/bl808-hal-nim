"""Tests for UART-anchor paths in tools/hw_validate.py."""
from __future__ import annotations

import json
import hashlib
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

import hw_validate


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


def test_nim_uart_anchor_implements_reboot_command():
    source = (hw_validate.REPO_ROOT / "examples" / "m0_uart_flash_anchor.nim").read_text()

    assert f"CmdReboot = {hw_validate.UART_FLASH_CMD_REBOOT}'u32" in source
    assert "of CmdReboot:" in source
    assert "rebootAfterResponse = true" in source
    assert "prepareForSoftReboot()" in source
    assert "l1cInvalidateAll()" in source
    assert "fenceI()" in source
    assert "rebootChip()" in source


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
    assert "target reset after UART-anchor flash before capture" in out


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


def test_jtag_flash_reset_capture_keeps_runtime_jtag_by_default(
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
    assert reset_reasons == ["after UART anchor flash before UART capture"]
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" in out
