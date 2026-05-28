"""Tests for UART-anchor paths in tools/hw_validate.py."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

import hw_validate


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


def test_prepare_ble_vendor_lld_con_probe_renames_tx_symbols(monkeypatch, tmp_path):
    source = tmp_path / "lld_con_probe_llcp.o"
    output = tmp_path / "lld_con_probe_llcp_nimwrap.o"
    source.write_bytes(b"obj")
    calls = []

    def fake_run_checked(cmd, **kwargs):
        calls.append((cmd, kwargs))
        output.write_bytes(b"wrapped")
        return ""

    monkeypatch.setattr(hw_validate, "BLE_VENDOR_LLD_CON_PROBE_LLCP", source)
    monkeypatch.setattr(hw_validate, "BLE_VENDOR_LLD_CON_PROBE_NIMWRAP", output)
    monkeypatch.setattr(hw_validate, "run_checked", fake_run_checked)

    result = hw_validate.prepare_ble_vendor_lld_con_probe(
        defines={
            "bl808BleVendorLldConProbe": "1",
            "bl808BleVendorManualConnTx": "1",
        },
        objcopy="objcopy",
        work_dir=tmp_path / "work",
        dry_run=False,
    )

    assert result == output
    assert output.read_bytes() == b"wrapped"
    cmd = calls[0][0]
    assert "--redefine-sym" in cmd
    assert "lld_con_data_tx=vendor_lld_con_data_tx" in cmd
    assert "lld_con_llcp_tx=vendor_lld_con_llcp_tx" in cmd


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
    anchor_flash_offset = hw_validate.BL808_FLASH_OFFSET_FW + hw_validate.BL808_FW_BOOTINFO_SIZE
    assert image_path.read_bytes()[anchor_flash_offset:anchor_flash_offset + 6] == b"ANCHOR"

    recovery = json.loads(manifest_path.read_text())
    assert recovery["kind"] == "bl808-uart-anchor-recovery"
    assert recovery["baud"] == 230400
    assert recovery["anchor_size"] == 6
    assert recovery["whole_flash_size"] == anchor_flash_offset + 6
    assert recovery["anchor_payload"]["flash_offset"] == anchor_flash_offset
    assert recovery["anchor_payload"]["flash_offset_hex"] == f"0x{anchor_flash_offset:06X}"
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
    assert "UART-anchor reboot target after flash" in out


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

    def fail_ftdi_reset(*_args, **_kwargs):
        raise AssertionError("existing-anchor reboot path must not pulse FTDI nSRST")

    monkeypatch.setattr(hw_validate, "build_firmware", fake_build_firmware)
    monkeypatch.setattr(
        hw_validate,
        "flash_firmware_over_uart_anchor",
        fake_flash_firmware_over_uart_anchor,
    )
    monkeypatch.setattr(hw_validate, "pulse_target_reset_via_ftdi", fail_ftdi_reset)
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
    out = capsys.readouterr().out
    assert "DRY-RUN: skip OpenOCD/JTAG" in out
