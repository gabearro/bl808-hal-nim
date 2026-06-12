#!/usr/bin/env python3
"""Build, flash, and validate BL808 HAL/kernel examples on real hardware.

The harness uses UART for bootloader flashing and runtime logs, and JTAG via
OpenOCD for reset/run control plus failure snapshots.
"""

from __future__ import annotations

import argparse
import fcntl
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "tools" / "hardware_validation.json"
DEFAULT_WORK_DIR = REPO_ROOT / "build" / "hw-validation"
DEFAULT_PATCHED_OPENOCD = REPO_ROOT.parent / "openocd-had" / "src" / "openocd"
GPIO_CFG_BASE = 0x200008C4
JTAG_D0_STATUS_ADDR = 0x40003E00
JTAG_D0_RUN_MAGIC = 0x44305255
JTAG_LP_ENTRY_ADDR = 0x22050000
DEFAULT_JTAG_GPIO_PINS = (6, 7, 12, 13)  # TMS, TDO, TCK, TDI on Ox64 J6
JTAG_FLASH_STUB_SOURCE = REPO_ROOT / "tools" / "jtag_flash_stub.c"
JTAG_FLASH_STUB_LINKER = REPO_ROOT / "tools" / "jtag_flash_stub.ld"
UART_FLASH_ANCHOR_SOURCE = REPO_ROOT / "tools" / "uart_flash_anchor.c"
UART_FLASH_ANCHOR_LINKER = REPO_ROOT / "tools" / "uart_flash_anchor.ld"
JTAG_FLASH_STUB_ENTRY = 0x22020000
JTAG_FLASH_STUB_END = 0x2204F000
UART_FLASH_ANCHOR_ENTRY = 0x62020000
JTAG_FLASH_MAILBOX = 0x2204C000
JTAG_FLASH_DATA = 0x2204C100
JTAG_FLASH_MAX_CHUNK = 0x1000
JTAG_FLASH_CMD_READ_ID = 1
JTAG_FLASH_CMD_ERASE = 2
JTAG_FLASH_CMD_WRITE_VERIFY = 3
JTAG_FLASH_MAGIC = 0x4A544746
JTAG_FLASH_STATUS_READY = 0x52454144
JTAG_FLASH_STATUS_BUSY = 0x42555359
JTAG_FLASH_STATUS_DONE = 0x444F4E45
JTAG_FLASH_STATUS_ERROR = 0x45525221
JTAG_FLASH_D0_OFFSET = 0x100000
JTAG_FLASH_LP_OFFSET = 0x091000
BL808_BOOTHEADER_SIZE = 352
BL808_FW_BOOTINFO_SIZE = 0x1000
BL808_PT_TABLE_SIZE = 596
BL808_PT_MAGIC = 0x54504642
BL808_BOOTHEADER_MAGIC_BFNP = 0x504E4642
BL808_BOOTHEADER_FLASH_CFG_MAGIC = 0x47464346
BL808_BOOTHEADER_PCLOCK_MAGIC = 0x47464350
BL808_BOOTHEADER_PT0_OFFSET = 0x0F4
BL808_BOOTHEADER_PT1_OFFSET = 0x0F8
BL808_BOOTHEADER_CRC_OFFSET = 0x15C
BL808_FLASH_OFFSET_BOOT2 = 0x000000
BL808_FLASH_OFFSET_PT0 = 0x00E000
BL808_FLASH_OFFSET_PT1 = 0x00F000
BL808_FLASH_OFFSET_FW = 0x010000
BL808_FLASH_FW_MAX_LEN = 0x0F0000
JTAG_FLASH_SF_CTRL_BASE = 0x2000B000
JTAG_FLASH_SF_CTRL_BUF = 0x2000B600
UART_FLASH_REQ_MAGIC = 0x31414655
UART_FLASH_REQ_GUARD = 0x48535246
UART_FLASH_RESP_MAGIC = 0x31524655
UART_FLASH_CMD_PING = 0
UART_FLASH_CMD_READ_ID = 1
UART_FLASH_CMD_ERASE = 2
UART_FLASH_CMD_WRITE_VERIFY = 3
UART_FLASH_CMD_REBOOT = 4
UART_FLASH_DEBUG_BASE = 0x2204C020
UART_FLASH_DEBUG_STATUS_BUSY = 0xFFFFFFFF
UART_FLASH_BANNER = b"BL808-UART-FLASH-ANCHOR v1\r\n"
JTAG_MEMORY_LOG_MAGIC = 0x474C544A
SERIAL_CAPTURE_OPEN_SETTLE_S = 0.25
UART_FLASH_STATUS_NAMES = {
    0: "ok",
    1: "bad command",
    2: "bad length",
    3: "checksum mismatch",
    4: "timeout",
    5: "verify mismatch",
}

JTAG_CORES: dict[str, dict[str, Any]] = {
    "m0": {
        "target": "tgt_e907_v2.cfg",
        "func_sel": 26,
    },
    "d0": {
        "target": "tgt_c906.cfg",
        "interface": "pine64jtag_slow.cfg",
        "func_sel": 27,
    },
    "lp": {
        "target": "tgt_e902.cfg",
        "interface": "pine64jtag_slow.cfg",
        "func_sel": 25,
    },
}


@dataclass
class TestResult:
    name: str
    ok: bool
    elapsed: float
    reason: str


class HardwareRunLock:
    def __init__(self, path: Path):
        self.path = path
        self.file: Any | None = None

    def __enter__(self) -> "HardwareRunLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("a+", encoding="utf-8")
        try:
            fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self.file.seek(0)
            holder = self.file.read().strip() or "unknown holder"
            self.file.close()
            self.file = None
            raise RuntimeError(
                f"hardware validation is already running; lock={self.path}; {holder}"
            ) from exc

        self.file.seek(0)
        self.file.truncate()
        self.file.write(
            f"pid={os.getpid()} cwd={Path.cwd()} cmd={shlex.join(sys.argv)}\n"
        )
        self.file.flush()
        os.fsync(self.file.fileno())
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self.file is None:
            return
        try:
            self.file.seek(0)
            self.file.truncate()
            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
        finally:
            self.file.close()
            self.file = None


@dataclass
class BuildOutput:
    build_id: str
    core: str
    source: str
    elf: Path
    bin: Path
    flash_core: str | None


@dataclass
class JtagFlashSegment:
    address: int
    path: Path
    label: str


def parse_jtag_gpio_pins(value: str) -> tuple[int, int, int, int]:
    parts = [part.strip() for part in value.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "expected four comma-separated GPIO numbers in TMS,TDO,TCK,TDI order"
        )
    pins: list[int] = []
    for part in parts:
        try:
            pin = int(part, 0)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"invalid GPIO number: {part!r}") from exc
        if pin < 0 or pin > 45:
            raise argparse.ArgumentTypeError(f"GPIO number out of BL808 range: {pin}")
        pins.append(pin)
    return (pins[0], pins[1], pins[2], pins[3])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate BL808 firmware on hardware with UART plus JTAG"
    )
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tier", choices=("smoke", "full"), default="smoke")
    parser.add_argument("--test", action="append", default=[],
                        help="Run only the named test. May be supplied more than once.")
    parser.add_argument("--list", action="store_true",
                        help="List manifest tests and detected serial ports, then exit.")
    parser.add_argument("--preflight", action="store_true",
                        help="Check UART/JTAG dependencies and OpenOCD attach without flashing.")
    parser.add_argument("--preflight-reset-target", action="store_true",
                        help=(
                            "During --preflight, allow the mux handoff stub to reset/release "
                            "the requested target core instead of preserving running firmware."
                        ))
    parser.add_argument("--probe-uart-boot", action="store_true",
                        help=(
                            "Probe the BL808 UART bootloader handshake on --flash-port "
                            "or --uart without building or flashing."
                        ))
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)

    parser.add_argument("--uart", type=str, default=None,
                        help="Primary runtime UART, usually the M0 console.")
    parser.add_argument("--secondary-uart", type=str, default=None,
                        help="Optional secondary runtime UART, e.g. D0 UART3.")
    parser.add_argument("--uart-baud", type=int, default=None)
    parser.add_argument("--serial-dtr", choices=("off", "on", "unchanged"), default="off",
                        help="Runtime UART DTR state after open. Default: off.")
    parser.add_argument("--serial-rts", choices=("off", "on", "unchanged"), default="off",
                        help="Runtime UART RTS state after open. Default: off.")
    parser.add_argument("--flash-port", type=str, default=None,
                        help="UART bootloader port. Defaults to --uart.")
    parser.add_argument("--flash-baud", type=int, default=None)
    parser.add_argument("--manual-boot-reset", action="store_true",
                        help=(
                            "Prompt before flashing so the Ox64 can be reset "
                            "into UART boot mode manually."
                        ))
    parser.add_argument("--target-reset-before-flash", action="store_true",
                        help=(
                            "Pulse target nSRST through the FTDI adapter before "
                            "each UART bootloader flash operation."
                        ))

    default_openocd = (
        str(DEFAULT_PATCHED_OPENOCD)
        if DEFAULT_PATCHED_OPENOCD.exists() and os.access(DEFAULT_PATCHED_OPENOCD, os.X_OK)
        else "openocd"
    )
    parser.add_argument("--openocd", default=os.environ.get("OPENOCD", default_openocd))
    parser.add_argument("--lp-openocd", default=os.environ.get(
        "BL808_LP_OPENOCD",
        default_openocd,
    ), help=(
        "OpenOCD binary for LP/E902 attach. Defaults to the patched "
        "../openocd-had build when present; falls back to --openocd otherwise."
    ))
    parser.add_argument("--lp-jtag-mode", choices=("rvdm", "raw-had"),
                        default=os.environ.get("BL808_LP_JTAG_MODE", "rvdm"),
                        help=(
                            "LP debug transport. rvdm uses the BL808 board JTAG/RISC-V DM "
                            "path; raw-had uses the experimental direct E902 HAD transport."
                        ))
    parser.add_argument("--jtag-gpio-style", choices=("bootrom", "sdk-af"),
                        default=os.environ.get("BL808_JTAG_GPIO_STYLE", "bootrom"),
                        help=(
                            "GPIO pad config used when switching JTAG muxes. bootrom uses "
                            "the minimal working M0/D0 pattern; sdk-af mirrors the Bouffalo "
                            "SDK alternate-function/pull-up/drive-1 pattern."
                        ))
    parser.add_argument("--lp-jtag-p7-io2-5", choices=("unchanged", "clear", "set"),
                        default=os.environ.get("BL808_LP_JTAG_P7_IO2_5", "unchanged"),
                        help=(
                            "For LP JTAG mux experiments, optionally clear or set "
                            "GLB_PARM_CFG0.P7_JTAG_USE_IO_2_5 before moving the JTAG pads."
                        ))
    parser.add_argument("--lp-jtag-e902-sel", choices=("unchanged", "clear", "set"),
                        default=os.environ.get("BL808_LP_JTAG_E902_SEL", "unchanged"),
                        help=(
                            "Experimental LP JTAG chain-select bit. BL616D documents "
                            "GLB_PARM_CFG0 bit 7 as GLB_E902_JTAG_SEL; BL808 leaves the "
                            "same bit unnamed, so this is a reversible GLB-register probe."
                        ))
    parser.add_argument("--lp-jtag-wl-chain", choices=("unchanged", "clear", "set"),
                        default=os.environ.get("BL808_LP_JTAG_WL_CHAIN", "unchanged"),
                        help=(
                            "Experimental JTAG chain bit. BL616D documents GLB_PARM_CFG0 "
                            "bit 6 as GLB_WL_JTG_CHAIN; BL808 leaves the same bit unnamed."
                        ))
    parser.add_argument("--lp-jtag-p4-adc-test", choices=("unchanged", "clear", "set"),
                        default=os.environ.get("BL808_LP_JTAG_P4_ADC_TEST", "unchanged"),
                        help=(
                            "Experimental BL808 GLB_PARM_CFG0 bit 20 probe. The BL808 "
                            "register map names this P4_ADC_TEST_WITH_JTAG."
                        ))
    parser.add_argument("--lp-jtag-p5-dac-test", choices=("unchanged", "clear", "set"),
                        default=os.environ.get("BL808_LP_JTAG_P5_DAC_TEST", "unchanged"),
                        help=(
                            "Experimental BL808 GLB_PARM_CFG0 bit 21 probe. The BL808 "
                            "register map names this P5_DAC_TEST_WITH_JTAG."
                        ))
    parser.add_argument("--lp-jtag-cjtag-escape", action="store_true",
                        default=os.environ.get("BL808_LP_JTAG_CJTAG_ESCAPE", "") not in ("", "0"),
                        help=(
                            "After switching the GPIO mux to LP JTAG, clock the TMS portions "
                            "of the vendor CKLink cJTAG/JTAG port-detect sequence with the "
                            "FTDI adapter before starting LP OpenOCD."
                        ))
    parser.add_argument("--lp-jtag-cjtag-sequence", choices=("cklink", "legacy"),
                        default=os.environ.get("BL808_LP_JTAG_CJTAG_SEQUENCE", "cklink"),
                        help=(
                            "TMS/escape sequence used by --lp-jtag-cjtag-escape. cklink emits "
                            "the exact link_config(0x18, 0) sequence recovered from libCklink.so; "
                            "legacy keeps the older helper default with the broader public "
                            "cJTAG connect preamble."
                        ))
    parser.add_argument("--lp-jtag-prebring-d0", action="store_true",
                        default=os.environ.get("BL808_LP_JTAG_PREBRING_D0", "") not in ("", "0"),
                        help=(
                            "When M0 is switching to LP JTAG in bring-up mode, first release "
                            "D0/C906 into a spin loop. This tests whether the LP debug path "
                            "depends on MM/D0-side bring-up side effects."
                        ))
    parser.add_argument("--jtag-gpio-pins", type=parse_jtag_gpio_pins,
                        default=parse_jtag_gpio_pins(os.environ.get(
                            "BL808_JTAG_GPIO_PINS",
                            ",".join(str(pin) for pin in DEFAULT_JTAG_GPIO_PINS),
                        )),
                        help=(
                            "GPIOs to program for the JTAG mux in TMS,TDO,TCK,TDI order. "
                            "Default is Ox64 J6: 6,7,12,13. The strongest BL808 LP JTAG "
                            "route hint is GLB_PARM_CFG0.P7_JTAG_USE_IO_2_5, which needs "
                            "an experimental rewire to 2,3,4,5."
                        ))
    parser.add_argument("--lp-attach-retries", type=int,
                        default=int(os.environ.get("BL808_LP_ATTACH_RETRIES", "3")),
                        help="OpenOCD start/first-command attempts for LP attach.")
    parser.add_argument("--openocd-sudo", action="store_true",
                        help="Run OpenOCD through sudo for USB access.")
    parser.add_argument("--sudo-askpass", action="store_true",
                        help="Use sudo -A with an askpass helper instead of sudo -n.")
    parser.add_argument("--sudo-askpass-helper", type=Path, default=None,
                        help="Executable askpass helper for sudo -A.")
    parser.add_argument("--interface", type=Path, default=None)
    parser.add_argument("--target", type=Path, default=None)
    parser.add_argument("--jtag-core", choices=tuple(JTAG_CORES.keys()), default="m0",
                        help="Core the harness should leave selected on the JTAG GPIO mux.")
    parser.add_argument("--no-jtag-mux", action="store_true",
                        help="Do not program the BL808 JTAG GPIO mux.")
    parser.add_argument("--jtag-mux-bootstrap-core",
                        choices=tuple(JTAG_CORES.keys()), default="m0",
                        help="Core used to program the JTAG mux before switching.")
    parser.add_argument("--telnet-host", default="127.0.0.1")
    parser.add_argument("--telnet-port", type=int, default=4444)
    parser.add_argument("--attach-openocd", action="store_true",
                        help="Use an already-running OpenOCD telnet server.")
    parser.add_argument("--no-jtag-reset", action="store_true",
                        help="Do not issue OpenOCD reset before UART capture.")
    parser.add_argument("--manual-target-reset", action="store_true",
                        help=(
                            "Prompt for a manual Ox64 reset after opening UART and "
                            "before JTAG attach. Implies --no-jtag-reset."
                        ))
    parser.add_argument("--target-reset-before-capture", action="store_true",
                        help=(
                            "Pulse target nSRST through the FTDI adapter after opening "
                            "UART and before capture/JTAG attach."
                        ))
    parser.add_argument("--no-ftdi-reset", action="store_true",
                        help="Do not USB-reset the FTDI JTAG adapter before OpenOCD starts.")
    parser.add_argument("--ftdi-reset-required", action="store_true",
                        help="Treat FTDI reset failures as fatal.")
    parser.add_argument("--ftdi-reset-sudo", action="store_true",
                        help="Run the FTDI reset helper through sudo.")
    parser.add_argument("--ftdi-reset-vid", default=os.environ.get("FTDI_RESET_VID", "0x0403"))
    parser.add_argument("--ftdi-reset-pid", default=os.environ.get("FTDI_RESET_PID", "0x6014"))
    parser.add_argument("--ftdi-reset-serial", default=os.environ.get("FTDI_RESET_SERIAL", ""))
    parser.add_argument("--ftdi-reset-bin", type=Path,
                        default=REPO_ROOT / "build" / "ftdi_reset")
    parser.add_argument("--ftdi-reset-source", type=Path,
                        default=REPO_ROOT / "tools" / "ftdi_reset.c")
    parser.add_argument("--ftdi-srst-pulse-bin", type=Path,
                        default=REPO_ROOT / "build" / "ftdi_srst_pulse")
    parser.add_argument("--ftdi-srst-pulse-source", type=Path,
                        default=REPO_ROOT / "tools" / "ftdi_srst_pulse.c")
    parser.add_argument("--ftdi-tms-escape-bin", type=Path,
                        default=REPO_ROOT / "build" / "ftdi_tms_escape")
    parser.add_argument("--ftdi-tms-escape-source", type=Path,
                        default=REPO_ROOT / "tools" / "ftdi_tms_escape.c")
    parser.add_argument("--ftdi-reset-settle", type=float, default=1.0)
    parser.add_argument("--cc-host", default=os.environ.get("CC_HOST", "cc"))
    parser.add_argument("--pkg-config", default=os.environ.get("PKG_CONFIG", "pkg-config"))
    parser.add_argument("--riscv-gcc", default=os.environ.get("RISCV_GCC"),
                        help="RISC-V GCC used to build the M0 JTAG mux switch stub.")

    parser.add_argument("--nim", default=os.environ.get("NIM", "nim"))
    parser.add_argument("--nim-define", action="append", default=[],
                        metavar="NAME=VALUE",
                        help=(
                            "Extra Nim -d define passed to every build item. "
                            "May be supplied more than once."
                        ))
    parser.add_argument("--objcopy-rv32", default=os.environ.get("OBJCOPY_RV32"))
    parser.add_argument("--objcopy-rv64", default=os.environ.get("OBJCOPY_RV64"))
    parser.add_argument("--upload-script", type=Path, default=REPO_ROOT / "tools" / "upload.sh")

    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--jtag-load", action="store_true",
                        help=(
                            "Skip UART bootloader flashing and load the built firmware "
                            "directly into RAM over JTAG. Supports single-image M0 tests "
                            "plus M0+D0 and M0+D0+LP tests where M0 releases the other cores."
                        ))
    parser.add_argument("--jtag-flash", action="store_true",
                        help=(
                            "Skip UART bootloader flashing and program persistent SPI flash "
                            "through a RAM-resident M0 JTAG flash stub."
                        ))
    parser.add_argument("--uart-anchor-flash", action="store_true",
                        help=(
                            "Skip UART bootloader flashing by JTAG-loading a RAM-resident "
                            "M0 UART anchor, then stream persistent SPI flash data over "
                            "the normal UART pins."
                        ))
    parser.add_argument("--uart-anchor-existing", action="store_true",
                        help=(
                            "Use an already-running M0 UART flash anchor instead of "
                            "loading the anchor over JTAG. This requires UART ack mode "
                            "and pairs with --uart-anchor-reset-after-flash when runtime "
                            "JTAG/nSRST is unavailable."
                        ))
    parser.add_argument("--uart-anchor-probe", action="store_true",
                        help=(
                            "Load the M0 UART flash anchor, verify ping/read-id, and exit "
                            "without erasing or writing SPI flash."
                        ))
    parser.add_argument("--uart-anchor-build-only", action="store_true",
                        help=(
                            "Build the M0 UART flash anchor and a persistent boot2 flash "
                            "image for recovery/install, then exit without touching hardware."
                        ))
    parser.add_argument("--uart-anchor-flash-image", type=Path, default=None,
                        help=(
                            "Flash an already-built image through the M0 UART anchor and exit. "
                            "This is intended for replaying known-good whole_flash_data.bin "
                            "images without entering UART boot mode."
                        ))
    parser.add_argument("--uart-anchor-flash-image-address",
                        type=lambda value: int(value, 0), default=0,
                        help="Flash address for --uart-anchor-flash-image. Default: 0.")
    parser.add_argument("--uart-anchor-flash-image-label", default="prebuilt",
                        help="Log label for --uart-anchor-flash-image.")
    parser.add_argument("--prebuilt-snapshot-after-marker", default=None,
                        help=(
                            "After flashing --uart-anchor-flash-image, reset/run it, wait for "
                            "this UART marker, then halt over JTAG and capture a BLE snapshot."
                        ))
    parser.add_argument("--prebuilt-snapshot-timeout", type=float, default=30.0,
                        help="Seconds to wait for --prebuilt-snapshot-after-marker.")
    parser.add_argument("--prebuilt-snapshot-delay", type=float, default=0.5,
                        help="Seconds to wait after the marker before taking the JTAG snapshot.")
    parser.add_argument("--prebuilt-snapshot-command", action="append", default=[],
                        help=(
                            "OpenOCD command to include in the prebuilt marker snapshot. "
                            "May be supplied more than once; otherwise BLE defaults are used."
                        ))
    parser.add_argument("--jtag-flash-reset-capture", action="store_true",
                        help=(
                            "With --jtag-flash, run the flashed image by pulsing target nSRST "
                            "before UART/host capture. Runtime JTAG remains attached by default "
                            "so failure snapshots are available; set jtag_flash_runtime_jtag=false "
                            "in a manifest entry only when the run must be isolated from OpenOCD."
                        ))
    parser.add_argument("--jtag-flash-runtime-jtag", action="store_true",
                        help=(
                            "Compatibility flag for --jtag-flash reset-capture tests. Runtime JTAG "
                            "is already kept by default; this option explicitly requests the same "
                            "behavior for older commands or manifest opt-outs."
                        ))
    parser.add_argument("--jtag-flash-chunk-size", type=int, default=JTAG_FLASH_MAX_CHUNK,
                        help=(
                            "Bytes per write command for --jtag-flash. Must be 1..4096; "
                            "default is 4096."
                        ))
    parser.add_argument("--uart-anchor-flash-chunk-size", type=int, default=JTAG_FLASH_MAX_CHUNK,
                        help=(
                            "Bytes per write command for --uart-anchor-flash. Must be "
                            "1..4096; default is 4096."
                        ))
    parser.add_argument("--uart-anchor-ack-mode", choices=("auto", "uart", "jtag"), default="auto",
                        help=(
                            "How the M0 UART flash anchor is acknowledged. 'uart' waits for "
                            "normal UART replies, 'jtag' observes the anchor RAM status words "
                            "through OpenOCD, and 'auto' falls back to JTAG when UART replies "
                            "are not visible."
                        ))
    parser.add_argument("--uart-anchor-runtime-jtag", action="store_true",
                        help=(
                            "After --uart-anchor-flash, reattach runtime JTAG instead of "
                            "skipping it. Useful with --jtag-memory-log when UART TX is not "
                            "visible to the host."
                        ))
    parser.add_argument("--uart-anchor-reset-after-flash", action="store_true",
                        help=(
                            "After --uart-anchor-flash succeeds, ask the M0 UART anchor "
                            "to reboot the chip instead of relying on nSRST or a manual reset."
                        ))
    parser.add_argument("--jtag-memory-log", action="store_true",
                        help=(
                            "Poll the firmware's exported hw_validation_log_* ring buffer "
                            "over JTAG and include it in marker matching."
                        ))
    parser.add_argument("--jtag-breakpoint-symbol", action="append", default=[],
                        help=(
                            "Set a temporary hardware breakpoint at this M0 ELF symbol after "
                            "the runtime image is resumed. When it hits, capture a JTAG "
                            "snapshot, remove the breakpoint, and resume."
                        ))
    parser.add_argument("--jtag-breakpoint-address", action="append", default=[],
                        help=(
                            "Set a temporary hardware breakpoint at this raw M0 address "
                            "(decimal or 0x-prefixed hex). Uses the same snapshot commands "
                            "as --jtag-breakpoint-symbol."
                        ))
    parser.add_argument("--jtag-breakpoint-timeout", type=float, default=20.0,
                        help="Seconds to wait for each --jtag-breakpoint-symbol hit.")
    parser.add_argument("--jtag-breakpoint-skip-count", type=int, default=0,
                        help=(
                            "Resume through this many matching JTAG breakpoint/watchpoint "
                            "hits before capturing the snapshot. Useful for comparing later "
                            "scan-channel iterations."
                        ))
    parser.add_argument("--jtag-breakpoint-snapshot-command", action="append", default=[],
                        help=(
                            "OpenOCD command to capture when a JTAG breakpoint hits. May use "
                            "{sym:name}. If omitted, the test's jtag_snapshot commands are used."
                        ))
    parser.add_argument("--jtag-watchpoint-address", action="append", default=[],
                        help=(
                            "Set a temporary write watchpoint at this raw address after the "
                            "runtime image is resumed. Uses the same snapshot commands as "
                            "--jtag-breakpoint-symbol."
                        ))
    parser.add_argument("--jtag-watchpoint-symbol", action="append", default=[],
                        help=(
                            "Set a temporary write watchpoint at this M0 ELF symbol after the "
                            "runtime image is resumed. Uses the same snapshot commands as "
                            "--jtag-breakpoint-symbol."
                        ))
    parser.add_argument("--no-flash", action="store_true",
                        help="Skip UART bootloader flashing and run the current image.")
    parser.add_argument("--no-jtag", action="store_true",
                        help="Skip OpenOCD/JTAG control. Diagnostic mode only; full validation uses JTAG.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print build/flash/debug actions without executing them.")
    parser.add_argument("--keep-going", action="store_true",
                        help="Continue after failures.")
    return parser.parse_args()


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def resolve_repo_path(path: Path | str) -> Path:
    p = Path(path)
    if p.is_absolute():
        return p
    return REPO_ROOT / p


def command_to_text(cmd: list[str]) -> str:
    return redact_secrets(" ".join(subprocess.list2cmdline([arg]) for arg in cmd))


def redact_secrets(text: str) -> str:
    redacted = text
    for name, value in os.environ.items():
        upper = name.upper()
        if not value or len(value) < 4:
            continue
        if any(marker in upper for marker in ("PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY")):
            redacted = redacted.replace(value, "<redacted>")
    return redacted


def parse_cli_nim_defines(values: list[str]) -> dict[str, str]:
    defines: dict[str, str] = {}
    for item in values:
        if "=" not in item:
            raise RuntimeError(f"--nim-define expects NAME=VALUE, got {item!r}")
        name, value = item.split("=", 1)
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
            raise RuntimeError(f"invalid Nim define name: {name!r}")
        defines[name] = value
    return defines


def resolve_manifest_define_value(name: str, value: Any) -> str:
    if isinstance(value, dict):
        env_name = value.get("env") or value.get("secret_env")
        if env_name:
            env_value = os.environ.get(str(env_name))
            if env_value is not None:
                return env_value
            if "default" in value:
                return str(value["default"])
            raise RuntimeError(f"environment variable {env_name} is required for Nim define {name}")
        if "value" in value:
            return str(value["value"])
        raise RuntimeError(f"unsupported Nim define object for {name}: {value!r}")
    return str(value)


def manifest_nim_defines(*maps: Any) -> dict[str, str]:
    defines: dict[str, str] = {}
    for mapping in maps:
        if not mapping:
            continue
        if not isinstance(mapping, dict):
            raise RuntimeError(f"Nim defines must be an object, got {mapping!r}")
        for name, value in mapping.items():
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", str(name)):
                raise RuntimeError(f"invalid Nim define name: {name!r}")
            defines[str(name)] = resolve_manifest_define_value(str(name), value)
    return defines


def dry_run_log_path(log_path: Path) -> Path:
    if log_path.suffix:
        return log_path.with_name(f"{log_path.stem}.dry-run{log_path.suffix}")
    return log_path.with_name(f"{log_path.name}.dry-run")


def find_tool(primary: str | None, *fallbacks: str) -> str:
    candidates = [tool for tool in (primary, *fallbacks) if tool]
    for candidate in candidates:
        found = shutil.which(candidate)
        if found:
            return found
    raise RuntimeError(f"required tool not found: {' or '.join(candidates)}")


def harness_env() -> dict[str, str]:
    env = os.environ.copy()
    bin_dirs = [
        Path(sys.executable).parent,
        Path(sys.prefix) / ("Scripts" if os.name == "nt" else "bin"),
    ]
    prefix = os.pathsep.join(str(path) for path in dict.fromkeys(bin_dirs))
    env["PATH"] = prefix + os.pathsep + env.get("PATH", "")
    return env


def harness_which(tool: str) -> str | None:
    return shutil.which(tool, path=harness_env().get("PATH"))


def configure_sudo_askpass(args: argparse.Namespace, work_dir: Path) -> None:
    if not args.sudo_askpass:
        return
    if args.sudo_askpass_helper is not None:
        return
    if os.environ.get("SUDO_ASKPASS"):
        return
    if sys.platform != "darwin":
        raise RuntimeError("--sudo-askpass requires SUDO_ASKPASS outside macOS")

    helper = work_dir / "sudo_askpass.sh"
    helper.write_text(
        "\n".join([
            "#!/bin/sh",
            "exec /usr/bin/osascript <<'APPLESCRIPT'",
            "display dialog \"Codex needs sudo access for the BL808 hardware harness.\" default answer \"\" with hidden answer buttons {\"Cancel\", \"OK\"} default button \"OK\" with icon caution",
            "text returned of result",
            "APPLESCRIPT",
            "",
        ]),
        encoding="utf-8",
    )
    helper.chmod(0o700)
    args.sudo_askpass_helper = helper


def sudo_prefix(args: argparse.Namespace) -> list[str]:
    return ["sudo", "-A" if args.sudo_askpass else "-n"]


def sudo_env(args: argparse.Namespace) -> dict[str, str] | None:
    if not args.sudo_askpass:
        return None
    env = os.environ.copy()
    if args.sudo_askpass_helper is not None:
        env["SUDO_ASKPASS"] = str(resolve_repo_path(args.sudo_askpass_helper))
    env.setdefault("SUDO_PROMPT", "BL808 hardware harness sudo password: ")
    return env


def run_checked(cmd: list[str], *, cwd: Path, log_path: Path,
                timeout: float | None = None, dry_run: bool = False,
                env: dict[str, str] | None = None) -> str:
    ensure_parent(log_path)
    if dry_run:
        text = f"DRY-RUN: {command_to_text(cmd)}\n"
        dry_log_path = dry_run_log_path(log_path)
        ensure_parent(dry_log_path)
        dry_log_path.write_text(text, encoding="utf-8")
        print(text, end="")
        return text

    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        log_path.write_text(output, encoding="utf-8")
        raise RuntimeError(f"{command_to_text(cmd)} timed out after {timeout}s") from exc
    log_path.write_text(proc.stdout, encoding="utf-8")
    if proc.returncode != 0:
        tail = proc.stdout.strip().splitlines()[-1:] or ["no output"]
        raise RuntimeError(f"{command_to_text(cmd)} failed: {tail[0]}")
    return proc.stdout


def append_log(path: Path, text: str) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as f:
        f.write(text)


def run_logged(
    cmd: list[str],
    *,
    cwd: Path,
    log_path: Path,
    timeout: float | None = None,
    dry_run: bool = False,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    ensure_parent(log_path)
    if dry_run:
        text = f"DRY-RUN: {command_to_text(cmd)}\n"
        append_log(dry_run_log_path(log_path), text)
        print(text, end="")
        return subprocess.CompletedProcess(cmd, 0, text, "")

    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        message = f"{command_to_text(cmd)} timed out after {timeout}s\n"
        append_log(log_path, output + message)
        return subprocess.CompletedProcess(cmd, 124, output + message, "")
    append_log(log_path, proc.stdout)
    return proc


def parse_e2e_marker_fields(output: str, phase: str, kind: str) -> dict[str, str]:
    prefix = f"@e2e {phase}:{kind}"
    fields: dict[str, str] = {}
    for line in output.splitlines():
        marker_at = line.find(prefix)
        if marker_at < 0:
            continue
        marker = line[marker_at:]
        for part in marker[len(prefix):].strip().split():
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            fields[key] = value
    return fields


def expand_host_action_arg(text: str, marker_output: str | None) -> str:
    if not text.startswith("{e2e:") or not text.endswith("}"):
        return text
    if marker_output is None:
        raise RuntimeError(f"host action placeholder {text!r} requires marker output")
    parts = text[1:-1].split(":")
    if len(parts) != 4:
        raise RuntimeError(f"bad host action placeholder {text!r}")
    _, phase, kind, key = parts
    fields = parse_e2e_marker_fields(marker_output, phase, kind)
    if key not in fields:
        raise RuntimeError(f"host action placeholder {text!r} not found in markers")
    return fields[key]


def host_action_command(action: dict[str, Any], marker_output: str | None = None) -> list[str]:
    raw = action.get("cmd")
    if not isinstance(raw, list) or not raw:
        raise RuntimeError("host action requires non-empty cmd list")
    cmd: list[str] = []
    for part in raw:
        text = str(part)
        text = sys.executable if text == "{python}" else text
        cmd.append(expand_host_action_arg(text, marker_output))
    return cmd


def host_action_env() -> dict[str, str]:
    env = harness_env()
    # CoreBluetooth privacy authorization is attached to the helper app bundle.
    # Launch through LaunchServices by default so host actions exercise the same
    # TCC identity as manual validation runs. Developers can still override this
    # for local debugging with BL808_MACOS_BLE_HELPER_LAUNCH=direct.
    env.setdefault("BL808_MACOS_BLE_HELPER_LAUNCH", "open")
    return env


def run_host_action(
    test_name: str,
    index: int,
    action: dict[str, Any],
    *,
    work_dir: Path,
    inherited_forbidden: list[str],
) -> tuple[bool, str, str]:
    cmd = host_action_command(action)
    timeout_s = float(action.get("timeout", 30))
    log_path = work_dir / "logs" / f"{test_name}.host{index}.log"
    if log_path.exists():
        log_path.unlink()
    proc = run_logged(
        cmd,
        cwd=REPO_ROOT,
        log_path=log_path,
        timeout=timeout_s,
        env=host_action_env(),
    )
    output = proc.stdout
    if proc.returncode != 0:
        tail = output.strip().splitlines()[-1:] or ["no output"]
        return False, f"exit {proc.returncode}: {tail[0]}", output

    forbidden = inherited_forbidden + list(action.get("forbidden", []))
    forbidden_marker = check_forbidden(output, forbidden)
    if forbidden_marker is not None:
        return False, f"forbidden marker {forbidden_marker!r}", output

    missing = missing_required(output, list(action.get("required", [])))
    if missing:
        return False, f"missing {missing!r}", output
    return True, "ok", output


@dataclass
class RunningHostAction:
    index: int
    action: dict[str, Any]
    cmd: list[str]
    proc: subprocess.Popen[Any]
    log_path: Path
    log_file: Any
    deadline: float


def start_host_action(
    test_name: str,
    index: int,
    action: dict[str, Any],
    *,
    work_dir: Path,
    marker_output: str | None = None,
    log_label: str | None = None,
) -> RunningHostAction:
    cmd = host_action_command(action, marker_output)
    timeout_s = float(action.get("timeout", 30))
    log_path = work_dir / "logs" / f"{test_name}.{log_label or f'host{index}'}.log"
    if log_path.exists():
        log_path.unlink()
    ensure_parent(log_path)
    log_file = log_path.open("w", encoding="utf-8")
    proc = subprocess.Popen(
        cmd,
        cwd=REPO_ROOT,
        text=True,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=host_action_env(),
    )
    return RunningHostAction(
        index=index,
        action=action,
        cmd=cmd,
        proc=proc,
        log_path=log_path,
        log_file=log_file,
        deadline=time.monotonic() + timeout_s,
    )


def read_running_host_action_output(running: RunningHostAction) -> str:
    running.log_file.flush()
    return running.log_path.read_text(encoding="utf-8", errors="replace")


def stop_host_action(running: RunningHostAction) -> str:
    if running.proc.poll() is None:
        running.proc.terminate()
        try:
            running.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            running.proc.kill()
            running.proc.wait()
    if not running.log_file.closed:
        running.log_file.close()
    return running.log_path.read_text(encoding="utf-8", errors="replace")


def wait_host_action_ready(
    running: RunningHostAction,
    *,
    inherited_forbidden: list[str],
) -> tuple[bool, str, str]:
    while time.monotonic() < running.deadline:
        output = read_running_host_action_output(running)
        forbidden = inherited_forbidden + list(running.action.get("forbidden", []))
        forbidden_marker = check_forbidden(output, forbidden)
        if forbidden_marker is not None:
            stop_host_action(running)
            return False, f"forbidden marker {forbidden_marker!r}", output
        missing = missing_required(output, list(running.action.get("required", [])))
        if not missing:
            return True, "ready", output
        if running.proc.poll() is not None:
            finished = finish_host_action(
                running,
                inherited_forbidden=inherited_forbidden,
            )
            assert finished is not None
            return finished
        time.sleep(0.02)

    stop_host_action(running)
    timeout_s = float(running.action.get("timeout", 30))
    append_log(
        running.log_path,
        f"{command_to_text(running.cmd)} did not become ready after {timeout_s}s\n",
    )
    output = running.log_path.read_text(encoding="utf-8", errors="replace")
    return False, f"ready timeout after {timeout_s}s", output


def finish_host_action(
    running: RunningHostAction,
    *,
    inherited_forbidden: list[str],
) -> tuple[bool, str, str] | None:
    returncode = running.proc.poll()
    timed_out = False
    if returncode is None:
        if time.monotonic() < running.deadline:
            return None
        timed_out = True
        running.proc.kill()
        returncode = running.proc.wait()

    running.log_file.close()
    if timed_out:
        timeout_s = float(running.action.get("timeout", 30))
        append_log(
            running.log_path,
            f"{command_to_text(running.cmd)} timed out after {timeout_s}s\n",
        )
    output = running.log_path.read_text(encoding="utf-8", errors="replace")
    if timed_out:
        return False, f"timeout after {running.action.get('timeout', 30)}s", output
    if returncode != 0:
        tail = output.strip().splitlines()[-1:] or ["no output"]
        return False, f"exit {returncode}: {tail[0]}", output

    forbidden = inherited_forbidden + list(running.action.get("forbidden", []))
    forbidden_marker = check_forbidden(output, forbidden)
    if forbidden_marker is not None:
        return False, f"forbidden marker {forbidden_marker!r}", output

    missing = missing_required(output, list(running.action.get("required", [])))
    if missing:
        return False, f"missing {missing!r}", output
    return True, "ok", output


def pkg_config_flags(pkg_config: str, package: str) -> list[str]:
    proc = subprocess.run(
        [pkg_config, "--cflags", "--libs", package],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stdout.strip() or f"pkg-config {package} failed")
    return proc.stdout.split()


def build_ftdi_reset_helper(args: argparse.Namespace, log_path: Path) -> Path | None:
    source = resolve_repo_path(args.ftdi_reset_source)
    output = resolve_repo_path(args.ftdi_reset_bin)
    if not source.exists():
        append_log(log_path, f"FTDI reset source missing: {source}\n")
        return None
    if output.exists() and os.access(output, os.X_OK) and output.stat().st_mtime >= source.stat().st_mtime:
        return output
    if not shutil.which(args.cc_host):
        append_log(log_path, f"host compiler not found: {args.cc_host}\n")
        return None
    if not shutil.which(args.pkg_config):
        append_log(log_path, f"pkg-config not found: {args.pkg_config}\n")
        return None

    ensure_parent(output)
    try:
        flags = pkg_config_flags(args.pkg_config, "libftdi1")
    except RuntimeError as exc:
        append_log(log_path, f"libftdi1 pkg-config failed: {exc}\n")
        return None
    cmd = [args.cc_host, "-O2", "-Wall", "-Wextra", "-o", str(output), str(source), *flags]
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path)
    if proc.returncode != 0:
        append_log(log_path, "FTDI reset helper build failed\n")
        return None
    output.chmod(output.stat().st_mode | 0o111)
    return output


def build_ftdi_tms_escape_helper(args: argparse.Namespace, log_path: Path) -> Path | None:
    source = resolve_repo_path(args.ftdi_tms_escape_source)
    output = resolve_repo_path(args.ftdi_tms_escape_bin)
    if not source.exists():
        append_log(log_path, f"FTDI TMS escape source missing: {source}\n")
        return None
    if output.exists() and os.access(output, os.X_OK) and output.stat().st_mtime >= source.stat().st_mtime:
        return output
    if not shutil.which(args.cc_host):
        append_log(log_path, f"host compiler not found: {args.cc_host}\n")
        return None
    if not shutil.which(args.pkg_config):
        append_log(log_path, f"pkg-config not found: {args.pkg_config}\n")
        return None

    ensure_parent(output)
    try:
        flags = pkg_config_flags(args.pkg_config, "libftdi1")
    except RuntimeError as exc:
        append_log(log_path, f"libftdi1 pkg-config failed: {exc}\n")
        return None
    cmd = [args.cc_host, "-O2", "-Wall", "-Wextra", "-o", str(output), str(source), *flags]
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path)
    if proc.returncode != 0:
        append_log(log_path, "FTDI TMS escape helper build failed\n")
        return None
    output.chmod(output.stat().st_mode | 0o111)
    return output


def build_ftdi_srst_pulse_helper(args: argparse.Namespace, log_path: Path) -> Path | None:
    source = resolve_repo_path(args.ftdi_srst_pulse_source)
    output = resolve_repo_path(args.ftdi_srst_pulse_bin)
    if not source.exists():
        append_log(log_path, f"FTDI nSRST pulse source missing: {source}\n")
        return None
    if output.exists() and os.access(output, os.X_OK) and output.stat().st_mtime >= source.stat().st_mtime:
        return output
    if not shutil.which(args.cc_host):
        append_log(log_path, f"host compiler not found: {args.cc_host}\n")
        return None
    if not shutil.which(args.pkg_config):
        append_log(log_path, f"pkg-config not found: {args.pkg_config}\n")
        return None

    ensure_parent(output)
    try:
        flags = pkg_config_flags(args.pkg_config, "libftdi1")
    except RuntimeError as exc:
        append_log(log_path, f"libftdi1 pkg-config failed: {exc}\n")
        return None
    cmd = [args.cc_host, "-O2", "-Wall", "-Wextra", "-o", str(output), str(source), *flags]
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path)
    if proc.returncode != 0:
        append_log(log_path, "FTDI nSRST pulse helper build failed\n")
        return None
    output.chmod(output.stat().st_mode | 0o111)
    return output


def ftdi_reset_command(args: argparse.Namespace, helper: Path) -> list[str]:
    cmd = [str(helper), args.ftdi_reset_vid, args.ftdi_reset_pid]
    if args.ftdi_reset_serial:
        cmd.append(args.ftdi_reset_serial)
    if args.ftdi_reset_sudo and os.geteuid() != 0:
        cmd = [*sudo_prefix(args), *cmd]
    return cmd


def ftdi_srst_pulse_command(args: argparse.Namespace, helper: Path) -> list[str]:
    cmd = [str(helper), args.ftdi_reset_vid, args.ftdi_reset_pid]
    if args.ftdi_reset_serial:
        cmd.append(args.ftdi_reset_serial)
    if args.ftdi_reset_sudo and os.geteuid() != 0:
        cmd = [*sudo_prefix(args), *cmd]
    return cmd


def ftdi_tms_escape_command(args: argparse.Namespace, helper: Path) -> list[str]:
    cmd = [str(helper)]
    if args.lp_jtag_cjtag_sequence == "cklink":
        cmd.extend([
            "--escape", "10",
            "--tms", "24", "0xffff",
            "--escape", "7",
            "--tms", "4", "0x0c",
            "--tms", "4", "0x08",
            "--tms", "4", "0x00",
        ])
    cmd.extend([args.ftdi_reset_vid, args.ftdi_reset_pid])
    if args.ftdi_reset_serial:
        cmd.append(args.ftdi_reset_serial)
    if args.ftdi_reset_sudo and os.geteuid() != 0:
        cmd = [*sudo_prefix(args), *cmd]
    return cmd


def run_lp_jtag_cjtag_escape(args: argparse.Namespace, log_path: Path) -> None:
    if args.attach_openocd:
        append_log(log_path, "\n# LP cJTAG escape skipped while attaching to existing OpenOCD\n")
        return
    if args.dry_run:
        text = "DRY-RUN: FTDI LP cJTAG/JTAG TMS escape\n"
        append_log(log_path, text)
        print(text, end="")
        return

    helper = build_ftdi_tms_escape_helper(args, log_path)
    if helper is None:
        raise RuntimeError("FTDI TMS escape helper unavailable")

    cmd = ftdi_tms_escape_command(args, helper)
    append_log(log_path, f"\n# FTDI LP cJTAG/JTAG TMS escape ({args.lp_jtag_cjtag_sequence})\n")
    timeout_s = 60 if args.ftdi_reset_sudo and args.sudo_askpass else 10
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path, timeout=timeout_s, env=sudo_env(args))
    if proc.returncode != 0:
        raise RuntimeError(f"FTDI TMS escape failed with exit {proc.returncode}")

    time.sleep(0.2)


def probe_ftdi_reset(args: argparse.Namespace, log_path: Path, *, reason: str) -> tuple[bool, str]:
    if args.no_ftdi_reset:
        message = f"FTDI reset skipped ({reason})"
        append_log(log_path, message + "\n")
        return True, message
    if args.attach_openocd:
        message = f"FTDI reset skipped while attaching to existing OpenOCD ({reason})"
        append_log(log_path, message + "\n")
        return True, message
    if args.dry_run:
        text = f"DRY-RUN: FTDI reset ({reason})\n"
        append_log(log_path, text)
        print(text, end="")
        return True, text.strip()

    helper = build_ftdi_reset_helper(args, log_path)
    if helper is None:
        message = "FTDI reset helper unavailable"
        append_log(log_path, message + "\n")
        return False, message

    cmd = ftdi_reset_command(args, helper)

    append_log(log_path, f"\n# FTDI reset ({reason})\n")
    timeout_s = 60 if args.ftdi_reset_sudo and args.sudo_askpass else 20
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path, timeout=timeout_s, env=sudo_env(args))
    if proc.returncode != 0:
        message = f"FTDI reset failed with exit {proc.returncode}"
        append_log(log_path, message + "\n")
        tail = proc.stdout.strip().splitlines()[-1:] or [message]
        return False, tail[0]

    time.sleep(float(args.ftdi_reset_settle))
    tail = proc.stdout.strip().splitlines()[-1:] or ["FTDI reset ok"]
    return True, tail[0]


def reset_ftdi_adapter(args: argparse.Namespace, log_path: Path, *, reason: str) -> None:
    ok, message = probe_ftdi_reset(args, log_path, reason=reason)
    if not ok and args.ftdi_reset_required:
        raise RuntimeError(message)


def pulse_target_reset_via_ftdi(args: argparse.Namespace, log_path: Path, *, reason: str) -> None:
    """Pulse the Pine64 adapter nSRST line without relying on a live TAP scan."""
    if args.attach_openocd:
        append_log(log_path, f"\n# target nSRST pulse skipped while attaching ({reason})\n")
        return

    if args.dry_run:
        helper = resolve_repo_path(args.ftdi_srst_pulse_bin)
    else:
        helper = build_ftdi_srst_pulse_helper(args, log_path)
        if helper is None:
            raise RuntimeError("FTDI nSRST pulse helper unavailable")

    cmd = ftdi_srst_pulse_command(args, helper)
    append_log(log_path, f"\n# target nSRST pulse via FTDI ({reason})\n")
    if args.dry_run:
        text = f"DRY-RUN: {command_to_text(cmd)}\n"
        append_log(dry_run_log_path(log_path), text)
        print(text, end="")
        return

    timeout_s = 60 if args.ftdi_reset_sudo and args.sudo_askpass else 20
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path, timeout=timeout_s, env=sudo_env(args))
    if proc.returncode != 0:
        raise RuntimeError(f"target nSRST pulse failed with exit {proc.returncode}")
    time.sleep(float(args.ftdi_reset_settle))


def target_reset_recovery_allowed(args: argparse.Namespace) -> bool:
    """Return whether automatic nSRST recovery is allowed for a failed JTAG attach."""
    return not (args.no_jtag_reset or args.manual_target_reset or args.attach_openocd)


def openocd_startup_scan_error(text: str) -> str | None:
    """Return the first hard JTAG scan error from a fresh OpenOCD startup log."""
    if "Examined RISC-V core; found" in text or "Examined RISCV core;" in text:
        return None
    markers = (
        "JTAG scan chain interrogation failed",
        "does not have valid IDCODE",
        "IR capture error",
        "Bypassing JTAG setup events due to errors",
        "double-check your JTAG setup",
        "Unsupported DTM version",
        "dtmcontrol is 0",
    )
    cleaned = text.replace("\x00", "")
    for line in cleaned.splitlines():
        stripped = line.strip()
        if any(marker in stripped for marker in markers):
            return stripped
    return None


def select_tests(manifest: dict[str, Any], tier: str, names: list[str]) -> list[dict[str, Any]]:
    tests = manifest["tests"]
    if names:
        wanted = set(names)
        selected = [test for test in tests if test["name"] in wanted]
        missing = wanted - {test["name"] for test in selected}
        if missing:
            raise SystemExit(f"unknown test(s): {', '.join(sorted(missing))}")
        return selected
    return [test for test in tests if tier in test.get("tiers", [])]


def list_serial_ports() -> list[str]:
    try:
        from serial.tools import list_ports  # type: ignore
    except Exception:
        ports = []
    else:
        ports = [port.device for port in list_ports.comports()]

    for pattern in ("/dev/cu.*", "/dev/ttyUSB*", "/dev/ttyACM*"):
        ports.extend(glob.glob(pattern))
    return sorted(set(ports))


def missing_required(output: str, required: list[str]) -> list[str]:
    return [marker for marker in required if marker not in output]


def check_forbidden(output: str, forbidden: list[str]) -> str | None:
    for marker in forbidden:
        if marker in output:
            return marker
    return None


def modem_control_state(mode: str) -> bool | None:
    if mode == "on":
        return True
    if mode == "off":
        return False
    return None


def open_serial_device(
    serial_module: Any,
    *,
    port: str,
    baud: int,
    timeout: float,
    write_timeout: float,
    dtr: bool | None,
    rts: bool | None,
) -> Any:
    ser = serial_module.Serial(
        port=None,
        baudrate=baud,
        timeout=timeout,
        write_timeout=write_timeout,
    )
    ser.port = port
    if dtr is not None:
        ser.dtr = dtr
    if rts is not None:
        ser.rts = rts
    ser.open()
    if dtr is not None:
        ser.dtr = dtr
    if rts is not None:
        ser.rts = rts
    return ser


class SerialCapture:
    def __init__(
        self,
        port: str,
        baud: int,
        label: str,
        log_path: Path,
        *,
        dtr: bool | None,
        rts: bool | None,
    ) -> None:
        try:
            import serial  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "pyserial is required for hardware validation. "
                "Install it with: python3 -m pip install pyserial"
            ) from exc

        ensure_parent(log_path)
        self.label = label
        self.log_path = log_path
        self.output = ""
        self._log = log_path.open("w", encoding="utf-8")
        self._serial = open_serial_device(
            serial,
            port=port,
            baud=baud,
            timeout=0,
            write_timeout=2,
            dtr=dtr,
            rts=rts,
        )
        self._serial.reset_input_buffer()
        self._serial.reset_output_buffer()

    def read_available(self) -> str:
        waiting = getattr(self._serial, "in_waiting", 0)
        if waiting <= 0:
            return ""
        data = self._serial.read(min(waiting, 4096))
        if not data:
            return ""
        text = data.decode("utf-8", errors="replace")
        self.output += text
        self._log.write(text)
        self._log.flush()
        return text

    def drain_available(self) -> str:
        chunks: list[str] = []
        for _ in range(256):
            chunk = self.read_available()
            if not chunk:
                break
            chunks.append(chunk)
        return "".join(chunks)

    def write_text(self, text: str) -> None:
        self._serial.write(text.encode("utf-8"))
        self._serial.flush()
        self._log.write(f"\n[HARNESS -> {self.label}] {text!r}\n")
        self._log.flush()

    def reset_buffers(self) -> None:
        self._serial.reset_input_buffer()
        self._serial.reset_output_buffer()

    def close(self) -> None:
        try:
            self._serial.close()
        finally:
            self._log.close()


def elf_symbol_addresses(
    elf: Path,
    symbols: list[str],
    *,
    required: bool = True,
) -> dict[str, int]:
    nm = shutil.which("riscv64-unknown-elf-nm") or shutil.which("riscv32-unknown-elf-nm")
    if nm is None:
        raise RuntimeError("riscv64-unknown-elf-nm not found for JTAG memory log")
    proc = subprocess.run(
        [nm, str(elf)],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{nm} failed for {elf}: {proc.stdout.strip()}")
    wanted = set(symbols)
    found: dict[str, int] = {}
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[-1] in wanted:
            try:
                found[parts[-1]] = int(parts[0], 16)
            except ValueError:
                continue
    missing = [symbol for symbol in symbols if symbol not in found]
    if required and missing:
        raise RuntimeError(f"{elf} is missing JTAG memory log symbols {missing!r}")
    return found


def openocd_read_bytes(session: "OpenOcdSession", address: int, length: int) -> bytes:
    if length <= 0:
        return b""
    base = address & ~0x3
    prefix = address - base
    word_count = (prefix + length + 3) // 4
    text = session.command(f"mdw 0x{base:08X} {word_count}", timeout_s=10)
    words = parse_openocd_words(text, base, word_count)
    raw = bytearray()
    for word in words:
        raw.extend(struct.pack("<I", word & 0xFFFFFFFF))
    return bytes(raw[prefix:prefix + length])


def openocd_read32_nohalt(session: "OpenOcdSession", address: int) -> int:
    return parse_openocd_word(session.command(f"mdw 0x{address:08X} 1", timeout_s=5), address)


class JtagMemoryLogCapture:
    def __init__(self, session: "OpenOcdSession", output: BuildOutput, log_path: Path) -> None:
        self.session = session
        self.symbols = elf_symbol_addresses(output.elf, [
            "hw_validation_log_magic",
            "hw_validation_log_capacity",
            "hw_validation_log_write",
            "hw_validation_log_wrapped",
            "hw_validation_log_buffer",
        ])
        ensure_parent(log_path)
        self._log = log_path.open("w", encoding="utf-8")
        self.output = ""
        self.last_write = 0
        self.last_wrapped = 0
        poll_interval = float(os.environ.get("HW_VALIDATE_JTAG_LOG_POLL_INTERVAL", "0.25"))
        initial_delay = float(os.environ.get("HW_VALIDATE_JTAG_LOG_INITIAL_DELAY", "0"))
        self.poll_interval = max(0.01, poll_interval)
        self.next_poll = time.monotonic() + max(0.0, initial_delay)

    def _read_range(self, start: int, end: int) -> bytes:
        if end <= start:
            return b""
        return openocd_read_bytes(
            self.session,
            self.symbols["hw_validation_log_buffer"] + start,
            end - start,
        )

    def read_available(self) -> str:
        now = time.monotonic()
        if now < self.next_poll:
            return ""
        self.next_poll = now + self.poll_interval
        chunks: list[bytes] = []
        self.session.command("halt", timeout_s=5)
        try:
            magic = openocd_read32_nohalt(self.session, self.symbols["hw_validation_log_magic"])
            if magic != JTAG_MEMORY_LOG_MAGIC:
                return ""
            capacity = openocd_read32_nohalt(self.session, self.symbols["hw_validation_log_capacity"])
            write = openocd_read32_nohalt(self.session, self.symbols["hw_validation_log_write"])
            wrapped = openocd_read32_nohalt(self.session, self.symbols["hw_validation_log_wrapped"])
            if capacity == 0 or capacity > 65536 or write >= capacity:
                return ""

            if wrapped != self.last_wrapped or write < self.last_write:
                chunks.append(self._read_range(self.last_write, capacity))
                chunks.append(self._read_range(0, write))
            elif write > self.last_write:
                chunks.append(self._read_range(self.last_write, write))
            self.last_write = write
            self.last_wrapped = wrapped
        finally:
            self.session.command("resume", timeout_s=5)

        data = b"".join(chunks)
        if not data:
            return ""
        text = data.decode("utf-8", errors="replace")
        self.output += text
        self._log.write(text)
        self._log.flush()
        return text

    def close(self) -> None:
        self._log.close()


class OpenOcdSession:
    def __init__(
        self,
        *,
        openocd: str,
        interface: Path,
        target: Path,
        host: str,
        port: int,
        log_path: Path,
        attach: bool,
        dry_run: bool,
        openocd_sudo: bool,
        env: dict[str, str] | None = None,
    ) -> None:
        self.openocd = openocd
        self.interface = interface
        self.target = target
        self.host = host
        self.port = port
        self.attach = attach
        self.dry_run = dry_run
        self.openocd_sudo = openocd_sudo
        self.env = env
        self.proc: subprocess.Popen[str] | None = None
        self.sock: socket.socket | None = None
        if dry_run:
            log_path = dry_run_log_path(log_path)
        ensure_parent(log_path)
        self.log_path = log_path
        log_path.write_text("", encoding="utf-8")
        self._log = log_path.open("a", encoding="utf-8")

    def start(self) -> None:
        if self.dry_run:
            cmd = self.openocd_command()
            self._log.write(f"DRY-RUN: {command_to_text(cmd)}\n")
            self._log.flush()
            return

        if not self.attach:
            cmd = self.openocd_command()
            self._log.write(f"$ {command_to_text(cmd)}\n")
            self._log.flush()
            self.proc = subprocess.Popen(
                cmd,
                cwd=REPO_ROOT,
                text=True,
                stdout=self._log,
                stderr=subprocess.STDOUT,
                env=self.env,
            )

        deadline = time.monotonic() + 20
        last_error = ""
        while time.monotonic() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                self._log.flush()
                tail = self.log_path.read_text(encoding="utf-8", errors="replace").strip().splitlines()[-3:]
                details = "; ".join(tail) if tail else "no OpenOCD output"
                raise RuntimeError(f"OpenOCD exited early with code {self.proc.returncode}: {details}")
            try:
                self.sock = socket.create_connection((self.host, self.port), timeout=1)
                self.sock.settimeout(0.2)
                self._read_until_prompt(5)
                return
            except OSError as exc:
                last_error = str(exc)
                time.sleep(0.2)

        raise RuntimeError(f"could not connect to OpenOCD telnet: {last_error}")

    def openocd_command(self) -> list[str]:
        cmd = [self.openocd, "-f", str(self.interface), "-f", str(self.target)]
        if self.openocd_sudo and os.geteuid() != 0:
            sudo_flag = "-A" if self.env and self.env.get("SUDO_ASKPASS") else "-n"
            return ["sudo", sudo_flag, *cmd]
        return cmd

    def _read_until_prompt(self, timeout_s: float) -> str:
        if self.sock is None:
            return ""
        deadline = time.monotonic() + timeout_s
        chunks: list[bytes] = []
        while time.monotonic() < deadline:
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not data:
                break
            chunks.append(data)
            if data.rstrip().endswith(b">") or b"\n> " in data or b"\r\n> " in data:
                break
        text = b"".join(chunks).decode("utf-8", errors="replace")
        if text:
            self._log.write(text)
            self._log.flush()
        return text

    def command(self, command: str, timeout_s: float = 5) -> str:
        if self.dry_run:
            text = f"DRY-RUN openocd> {command}\n"
            self._log.write(text)
            self._log.flush()
            return text
        if self.sock is None:
            raise RuntimeError("OpenOCD telnet is not connected")
        self._log.write(f"\n> {command}\n")
        self._log.flush()
        self.sock.sendall((command + "\n").encode("utf-8"))
        text = self._read_until_prompt(timeout_s)
        self._raise_for_command_error(command, text)
        if self.proc is not None and self.proc.poll() is not None and command != "shutdown":
            tail = self.log_path.read_text(encoding="utf-8", errors="replace").strip().splitlines()[-3:]
            details = "; ".join(tail) if tail else "no OpenOCD output"
            raise RuntimeError(
                f"OpenOCD exited during command {command!r} with code {self.proc.returncode}: {details}"
            )
        return text

    @staticmethod
    def _raise_for_command_error(command: str, text: str) -> None:
        markers = (
            "Error:",
            "Target not examined yet",
            "Unsupported DTM version",
            "JTAG scan chain interrogation failed",
            "Assertion failed:",
        )
        cleaned = text.replace("\x00", "")
        failure_lines = [
            line.strip()
            for line in cleaned.splitlines()
            if any(marker in line for marker in markers)
        ]
        if failure_lines:
            raise RuntimeError(f"OpenOCD command {command!r} failed: {failure_lines[-1]}")

    def stop_process(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None

    def close(self) -> None:
        try:
            if self.sock is not None:
                try:
                    if not self.attach and not self.dry_run:
                        self.command("shutdown", timeout_s=2)
                except Exception:
                    pass
                self.sock.close()
                self.sock = None
        finally:
            self.stop_process()
            self._log.close()

    def detach(self) -> None:
        try:
            if self.sock is not None:
                try:
                    self.sock.close()
                except Exception:
                    pass
                self.sock = None
        finally:
            self.stop_process()
            self._log.close()


def build_firmware(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    work_dir: Path,
) -> dict[str, BuildOutput]:
    outputs: dict[str, BuildOutput] = {}
    bin_dir = work_dir / "bin" / test["name"]
    bin_dir.mkdir(parents=True, exist_ok=True)
    console_baud = int(args.uart_baud or 230_400)

    objcopy_rv32 = find_tool(args.objcopy_rv32, "riscv32-unknown-elf-objcopy",
                             "riscv64-unknown-elf-objcopy")
    objcopy_rv64 = find_tool(args.objcopy_rv64, "riscv64-unknown-elf-objcopy")

    for item in test.get("build", []):
        build_id = item["id"]
        core = item["core"]
        source = item["source"]
        elf_path = bin_dir / f"{build_id}.elf"
        bin_path = bin_dir / f"{build_id}.bin"
        map_path = bin_dir / f"{build_id}.map"
        nimcache = work_dir / "nimcache" / test["name"] / build_id

        nim_cmd = [
            args.nim,
            "c",
            f"-d:{core}",
            "-d:bl808kernel",
            f"-d:ConsoleBaud={console_baud}",
            f"--nimcache:{nimcache}",
            f"--out:{elf_path}",
            f"--passL:-Wl,-Map,{map_path}",
            source,
        ]
        defines = manifest_nim_defines(
            test.get("defines", {}),
            item.get("defines", {}),
            parse_cli_nim_defines(args.nim_define),
        )
        for name, value in sorted(defines.items()):
            nim_cmd.insert(4, f"-d:{name}={value}")
        if args.jtag_load and core in ("bl808m0", "bl808d0", "bl808lp"):
            nim_cmd.insert(4, "-d:bl808jtagram")
        if args.jtag_load and core == "bl808lp":
            tms_pin, tdo_pin, tck_pin, tdi_pin = args.jtag_gpio_pins
            nim_cmd.insert(4, f"-d:JtagTmsPin={tms_pin}")
            nim_cmd.insert(4, f"-d:JtagTdoPin={tdo_pin}")
            nim_cmd.insert(4, f"-d:JtagTckPin={tck_pin}")
            nim_cmd.insert(4, f"-d:JtagTdiPin={tdi_pin}")
            if args.lp_jtag_p7_io2_5 == "set":
                nim_cmd.insert(4, "-d:LpJtagUseIo2To5=1")
        cache_signature = hashlib.sha256(
            "\0".join(nim_cmd).encode("utf-8")
        ).hexdigest()
        cache_signature_path = nimcache / ".build-signature"
        old_signature = None
        if cache_signature_path.exists():
            old_signature = cache_signature_path.read_text(encoding="utf-8").strip()
        if nimcache.exists() and old_signature != cache_signature:
            shutil.rmtree(nimcache)
        nimcache.mkdir(parents=True, exist_ok=True)
        cache_signature_path.write_text(cache_signature + "\n", encoding="utf-8")
        run_checked(
            nim_cmd,
            cwd=REPO_ROOT,
            log_path=work_dir / "logs" / f"{test['name']}.{build_id}.build.log",
            dry_run=args.dry_run,
        )

        objcopy = objcopy_rv64 if core == "bl808d0" else objcopy_rv32
        objcopy_cmd = [objcopy, "-O", "binary", str(elf_path), str(bin_path)]
        run_checked(
            objcopy_cmd,
            cwd=REPO_ROOT,
            log_path=work_dir / "logs" / f"{test['name']}.{build_id}.objcopy.log",
            dry_run=args.dry_run,
        )

        outputs[build_id] = BuildOutput(
            build_id=build_id,
            core=core,
            source=source,
            elf=elf_path,
            bin=bin_path,
            flash_core=item.get("flash"),
        )

    return outputs


def flash_firmware(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    work_dir: Path,
    outputs: dict[str, BuildOutput],
    flash_port: str,
    flash_baud: int,
) -> None:
    flash_items = [output for output in outputs.values() if output.flash_core]
    order = {"d0": 0, "lp": 1, "m0": 2}
    flash_items.sort(key=lambda item: order.get(item.flash_core or "", 99))

    for item in flash_items:
        log_path = work_dir / "logs" / f"{test['name']}.{item.flash_core}.flash.log"
        if args.target_reset_before_flash:
            pulse_target_reset_via_ftdi(
                args,
                log_path,
                reason=f"before UART flash {test['name']}:{item.flash_core}",
            )
        cmd = [
            str(args.upload_script),
            item.flash_core or "",
            str(item.bin),
            flash_port,
            str(flash_baud),
        ]
        run_checked(
            cmd,
            cwd=REPO_ROOT,
            log_path=log_path,
            timeout=120,
            dry_run=args.dry_run,
            env=harness_env(),
        )


def find_default_boot2_image() -> Path:
    env_path = os.environ.get("BL808_BOOT2")
    if env_path:
        boot2 = resolve_repo_path(env_path)
        if not boot2.exists():
            raise RuntimeError(f"BL808_BOOT2 points to a missing file: {boot2}")
        if not boot2_image_has_header(boot2):
            raise RuntimeError(
                f"BL808_BOOT2 must point to a headered BL808 boot2 image: {boot2}"
            )
        return boot2

    for boot2 in [
        REPO_ROOT / "build" / "bl808-sdk-a05" / "bsp" / "board" /
        "bl808dk" / "builtin_imgs" / "boot2_bl808_release_v8.1.1.bin",
        REPO_ROOT / "build" / "bl808-sdk-a05" / "bsp" / "board" /
        "bl808dk" / "builtin_imgs" / "boot2_bl808_debug_v8.1.1.bin",
    ]:
        if boot2.exists() and boot2_image_has_header(boot2):
            return boot2

    raise RuntimeError(
        "no headered BL808 boot2 image found; set BL808_BOOT2 to "
        "boot2_bl808_release_v8.1.1.bin or populate build/bl808-sdk-a05"
    )


def find_default_fw_bootinfo_template() -> Path | None:
    try:
        import bflb_iot_tool  # type: ignore
    except Exception:
        return None
    template = (
        Path(getattr(bflb_iot_tool, "__file__", "")).parent
        / "chips"
        / "bl808"
        / "img_create_iot"
        / "bootinfo.bin"
    )
    return template if template.exists() else None


def build_fw_boot2_image(raw_fw: bytes) -> bytes:
    if len(raw_fw) >= 12:
        magic, _, flash_cfg_magic = struct.unpack_from("<III", raw_fw)
        if (
            magic == BL808_BOOTHEADER_MAGIC_BFNP
            and flash_cfg_magic == BL808_BOOTHEADER_FLASH_CFG_MAGIC
        ):
            return raw_fw

    template_path = find_default_fw_bootinfo_template()
    if template_path is None:
        raise RuntimeError(
            "raw FW image needs a BL808 bootinfo template; install bflb-iot-tool"
        )
    bootinfo = bytearray(template_path.read_bytes())
    if len(bootinfo) > BL808_FW_BOOTINFO_SIZE:
        raise RuntimeError(f"FW bootinfo template is larger than 0x1000: {template_path}")
    magic, _, flash_cfg_magic = struct.unpack_from("<III", bootinfo)
    if (
        magic != BL808_BOOTHEADER_MAGIC_BFNP
        or flash_cfg_magic != BL808_BOOTHEADER_FLASH_CFG_MAGIC
    ):
        raise RuntimeError(f"FW bootinfo template is not a BL808 BFNP header: {template_path}")

    padded_fw = raw_fw + (b"\x00" * ((-len(raw_fw)) % 16))
    bootinfo[0x8C:0x90] = len(padded_fw).to_bytes(4, "little")
    return bytes(bootinfo) + (b"\xFF" * (BL808_FW_BOOTINFO_SIZE - len(bootinfo))) + padded_fw


def boot2_image_has_header(path: Path) -> bool:
    try:
        header = path.read_bytes()[:12]
    except OSError:
        return False
    if len(header) < 12:
        return False
    magic, _, flash_cfg_magic = struct.unpack_from("<III", header)
    return (
        magic == BL808_BOOTHEADER_MAGIC_BFNP and
        flash_cfg_magic == BL808_BOOTHEADER_FLASH_CFG_MAGIC
    )


def bootheader_crc32(data: bytes | bytearray) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def patch_boot2_partition_offsets(
    image: bytes,
    *,
    pt0_offset: int,
    pt1_offset: int,
) -> bytes:
    if len(image) < BL808_BOOTHEADER_SIZE:
        raise RuntimeError("boot2 image is smaller than a BL808 boot header")

    header = bytearray(image[:BL808_BOOTHEADER_SIZE])
    magic, _, flash_cfg_magic = struct.unpack_from("<III", header)
    if (
        magic != BL808_BOOTHEADER_MAGIC_BFNP or
        flash_cfg_magic != BL808_BOOTHEADER_FLASH_CFG_MAGIC
    ):
        raise RuntimeError("boot2 image does not start with a BL808 BFNP header")
    if struct.unpack_from("<I", header, 0x64)[0] != BL808_BOOTHEADER_PCLOCK_MAGIC:
        raise RuntimeError("boot2 image header does not contain a BL808 PCFG block")

    struct.pack_into("<I", header, BL808_BOOTHEADER_PT0_OFFSET, pt0_offset)
    struct.pack_into("<I", header, BL808_BOOTHEADER_PT1_OFFSET, pt1_offset)
    struct.pack_into(
        "<I",
        header,
        BL808_BOOTHEADER_CRC_OFFSET,
        bootheader_crc32(header[:BL808_BOOTHEADER_CRC_OFFSET]),
    )
    return bytes(header) + image[BL808_BOOTHEADER_SIZE:]


def build_single_fw_partition_table(*, age: int) -> bytes:
    table = bytearray(b"\xFF" * BL808_PT_TABLE_SIZE)
    struct.pack_into("<IHHI", table, 0x00, BL808_PT_MAGIC, 0, 1, age)

    entry_base = 0x10
    table[entry_base + 0] = 0
    table[entry_base + 1] = 0
    table[entry_base + 2] = 0
    table[entry_base + 3:entry_base + 12] = b"FW\x00\x00\x00\x00\x00\x00\x00"
    struct.pack_into("<II", table, entry_base + 12, BL808_FLASH_OFFSET_FW, 0)
    struct.pack_into("<II", table, entry_base + 20, BL808_FLASH_FW_MAX_LEN, 0)
    struct.pack_into("<II", table, entry_base + 28, BL808_FLASH_FW_MAX_LEN, 0)

    struct.pack_into("<I", table, 0x0C, bootheader_crc32(table[:0x0C]))
    entries_end = entry_base + 36
    struct.pack_into(
        "<I",
        table,
        entries_end,
        bootheader_crc32(table[0x10:entries_end]),
    )
    return bytes(table)


def build_m0_jtag_flash_segments(
    output: BuildOutput,
    *,
    args: argparse.Namespace,
    work_dir: Path,
    test_name: str,
) -> list[JtagFlashSegment]:
    """Create sparse boot2/partition/FW flash segments for an M0 image."""
    out_dir = work_dir / "jtag-flash" / test_name / output.build_id
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    boot2_path = find_default_boot2_image()
    boot2_segment = out_dir / "boot2.bin"
    pt0_segment = out_dir / "partition_table_0.bin"
    pt1_segment = out_dir / "partition_table_1.bin"
    fw_segment = out_dir / "fw_boot2_image.bin"

    if args.dry_run:
        append_log(
            work_dir / "logs" / f"{test_name}.{output.build_id}.jtag-image.log",
            f"DRY-RUN: build sparse boot2 flash segments from {boot2_path} and {output.bin}\n",
        )
    else:
        boot2_segment.write_bytes(
            patch_boot2_partition_offsets(
                boot2_path.read_bytes(),
                pt0_offset=BL808_FLASH_OFFSET_PT0,
                pt1_offset=BL808_FLASH_OFFSET_PT1,
            )
        )
        pt = build_single_fw_partition_table(age=1)
        pt0_segment.write_bytes(pt)
        pt1_segment.write_bytes(pt)
        fw_segment.write_bytes(build_fw_boot2_image(output.bin.read_bytes()))

    return [
        JtagFlashSegment(BL808_FLASH_OFFSET_BOOT2, boot2_segment, f"{output.build_id}:boot2"),
        JtagFlashSegment(BL808_FLASH_OFFSET_PT0, pt0_segment, f"{output.build_id}:pt0"),
        JtagFlashSegment(BL808_FLASH_OFFSET_PT1, pt1_segment, f"{output.build_id}:pt1"),
        JtagFlashSegment(BL808_FLASH_OFFSET_FW, fw_segment, f"{output.build_id}:FW"),
    ]


def build_compact_flash_image(segments: list[JtagFlashSegment]) -> bytes:
    if not segments:
        raise RuntimeError("cannot build compact flash image without segments")
    flash_size = 0
    payloads: list[tuple[int, bytes, str]] = []
    for segment in segments:
        data = segment.path.read_bytes()
        if not data:
            raise RuntimeError(f"flash segment is empty: {segment.path}")
        end = segment.address + len(data)
        flash_size = max(flash_size, end)
        payloads.append((segment.address, data, segment.label))

    flash = bytearray(b"\xFF" * flash_size)
    for address, data, label in payloads:
        end = address + len(data)
        if flash[address:end] != b"\xFF" * len(data):
            raise RuntimeError(f"overlapping flash segment: {label}")
        flash[address:end] = data
    return bytes(flash)


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_unique_payload_offset(image: bytes, payload: bytes, *, label: str) -> int:
    if not payload:
        raise RuntimeError(f"{label} payload is empty")
    offset = image.find(payload)
    if offset < 0:
        raise RuntimeError(f"{label} payload was not found in compact flash image")
    duplicate = image.find(payload, offset + 1)
    if duplicate >= 0:
        raise RuntimeError(
            f"{label} payload appears multiple times in compact flash image "
            f"(0x{offset:X}, 0x{duplicate:X})"
        )
    return offset


def jtag_flash_segments_for_outputs(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    work_dir: Path,
    outputs: dict[str, BuildOutput],
) -> list[JtagFlashSegment]:
    flash_items = [output for output in outputs.values() if output.flash_core]
    order = {"m0": 0, "lp": 1, "d0": 2}
    flash_items.sort(key=lambda item: order.get(item.flash_core or "", 99))
    segments: list[JtagFlashSegment] = []

    for item in flash_items:
        if item.flash_core == "m0":
            segments.extend(
                build_m0_jtag_flash_segments(
                    item,
                    args=args,
                    work_dir=work_dir,
                    test_name=test["name"],
                )
            )
        elif item.flash_core == "lp":
            segments.append(JtagFlashSegment(JTAG_FLASH_LP_OFFSET, item.bin, item.build_id))
        elif item.flash_core == "d0":
            segments.append(JtagFlashSegment(JTAG_FLASH_D0_OFFSET, item.bin, item.build_id))
        else:
            raise RuntimeError(f"--jtag-flash does not know flash core {item.flash_core!r}")

    if not segments:
        raise RuntimeError(f"{test['name']} has no flashable build outputs")
    return segments


def build_jtag_flash_stub(
    *,
    args: argparse.Namespace,
    work_dir: Path,
    test_name: str,
) -> Path:
    gcc = find_tool(args.riscv_gcc, "riscv64-unknown-elf-gcc")
    out_dir = work_dir / "jtag-flash" / test_name / "stub"
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / "jtag_flash_stub.elf"
    cmd = [
        gcc,
        "-march=rv32imafc",
        "-mabi=ilp32f",
        "-mcmodel=medlow",
        "-Os",
        "-ffreestanding",
        "-fno-builtin",
        "-nostdlib",
        "-nostartfiles",
        "-T",
        str(JTAG_FLASH_STUB_LINKER),
        "-o",
        str(elf),
        str(JTAG_FLASH_STUB_SOURCE),
    ]
    run_checked(
        cmd,
        cwd=REPO_ROOT,
        log_path=work_dir / "logs" / f"{test_name}.jtag-flash-stub.build.log",
        timeout=60,
        dry_run=args.dry_run,
        env=harness_env(),
    )
    return elf


def parse_openocd_word(text: str, address: int) -> int:
    pattern = rf"0x{address:08x}:\s+([0-9a-fA-F]+)"
    match = re.search(pattern, text, flags=re.IGNORECASE)
    if not match:
        match = re.search(r":\s+([0-9a-fA-F]{8})", text)
    if not match:
        raise RuntimeError(f"could not parse OpenOCD mdw output for 0x{address:08X}: {text!r}")
    return int(match.group(1), 16)


def parse_openocd_words(text: str, address: int, count: int) -> list[int]:
    words: list[int] = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        _, payload = line.split(":", 1)
        for token in payload.split():
            if re.fullmatch(r"[0-9a-fA-F]{8}", token):
                words.append(int(token, 16))
    if len(words) < count:
        raise RuntimeError(
            f"could not parse {count} OpenOCD words for 0x{address:08X}: {text!r}"
        )
    return words[:count]


def jtag_snapshot_symbol_names(commands: list[str]) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for command in commands:
        for match in re.finditer(r"\{sym:([^}]+)\}", command):
            name = match.group(1)
            if name not in seen:
                names.append(name)
                seen.add(name)
    return names


def expand_jtag_snapshot_command(command: str, symbols: dict[str, int]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in symbols:
            raise RuntimeError(f"missing JTAG snapshot symbol {name!r}")
        return f"0x{symbols[name]:08X}"

    return re.sub(r"\{sym:([^}]+)\}", replace, command)


def missing_jtag_snapshot_symbols(command: str, symbols: dict[str, int]) -> list[str]:
    return [
        match.group(1)
        for match in re.finditer(r"\{sym:([^}]+)\}", command)
        if match.group(1) not in symbols
    ]


def jtag_flash_read32(session: OpenOcdSession, address: int) -> int:
    return parse_openocd_word(session.command(f"mdw 0x{address:08X} 1", timeout_s=5), address)


def jtag_flash_write32(session: OpenOcdSession, address: int, value: int) -> None:
    session.command(f"mww 0x{address:08X} 0x{value & 0xFFFFFFFF:08X}", timeout_s=5)


def jtag_flash_pc(session: OpenOcdSession) -> int:
    text = session.command("reg pc", timeout_s=5)
    match = re.search(r"pc\s+\(/32\):\s+0x([0-9a-fA-F]+)", text)
    if not match:
        raise RuntimeError(f"could not parse OpenOCD PC output: {text!r}")
    return int(match.group(1), 16)


def jtag_flash_checksum(data: bytes) -> int:
    checksum = 0
    for byte in data:
        checksum = ((checksum << 5) ^ (checksum >> 27) ^ byte) & 0xFFFFFFFF
    return checksum


def uart_flash_header_checksum(command: int, address: int, length: int) -> int:
    return (~(UART_FLASH_REQ_GUARD ^ command ^ address ^ length)) & 0xFFFFFFFF


def jtag_flash_debug_snapshot(session: OpenOcdSession) -> str:
    lines: list[str] = []
    for command in (
        "reg pc",
        f"mdw 0x{JTAG_FLASH_MAILBOX:08X} 8",
        f"mdw 0x{JTAG_FLASH_SF_CTRL_BASE:08X} 8",
        f"mdw 0x{JTAG_FLASH_SF_CTRL_BUF:08X} 4",
    ):
        try:
            lines.append(f"> {command}")
            lines.append(session.command(command, timeout_s=5).strip())
        except Exception as exc:
            lines.append(f"> {command}")
            lines.append(f"ERROR: {exc}")
    return "\n".join(lines)


def uart_flash_anchor_debug_snapshot(session: OpenOcdSession) -> str:
    lines: list[str] = []
    for command in (
        "halt",
        "poll",
        "reg pc",
        "reg sp",
        "reg ra",
        "reg mcause",
        "reg mepc",
        "reg mtval",
        "mdw 0x2204C000 8",
        "mdw 0x2204C020 9",
        "mdw 0x20000150 3",
        "mdw 0x20000510 1",
        "mdw 0x200008FC 2",
        "mdw 0x2000A000 4",
        "mdw 0x2000A080 4",
    ):
        try:
            lines.append(f"> {command}")
            lines.append(session.command(command, timeout_s=5).strip())
        except Exception as exc:
            lines.append(f"> {command}")
            lines.append(f"ERROR: {exc}")
    return "\n".join(lines)


def wait_for_jtag_flash_stub(
    session: OpenOcdSession,
    *,
    args: argparse.Namespace,
    log_path: Path,
) -> None:
    deadline = time.monotonic() + 5
    last_magic = 0
    last_status = 0
    last_pc = 0
    while time.monotonic() < deadline:
        try:
            session.command("halt", timeout_s=5)
            last_pc = jtag_flash_pc(session)
            last_magic = jtag_flash_read32(session, JTAG_FLASH_MAILBOX)
            last_status = jtag_flash_read32(session, JTAG_FLASH_MAILBOX + 8)
            status_ready = last_status in (JTAG_FLASH_STATUS_READY, JTAG_FLASH_STATUS_DONE)
            pc_in_stub = JTAG_FLASH_STUB_ENTRY <= last_pc < JTAG_FLASH_STUB_END
            if last_magic == JTAG_FLASH_MAGIC and status_ready and pc_in_stub:
                return
        except Exception as exc:
            append_log(log_path, f"\n# waiting for JTAG flash stub: {exc}\n")
        session.command("resume", timeout_s=5)
        time.sleep(0.05)
    raise RuntimeError(
        "JTAG flash stub did not become ready "
        f"(magic=0x{last_magic:08X}, status=0x{last_status:08X}, pc=0x{last_pc:08X})"
    )


def run_jtag_flash_command(
    session: OpenOcdSession,
    command: int,
    *,
    address: int = 0,
    length: int = 0,
    checksum: int = 0,
    timeout_s: float = 30,
    poll_s: float = 0.05,
) -> int:
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 8, JTAG_FLASH_STATUS_READY)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 12, address)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 16, length)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 20, checksum)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 24, 0)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 28, 0)
    jtag_flash_write32(session, JTAG_FLASH_MAILBOX + 4, command)
    session.command("resume", timeout_s=5)

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        time.sleep(poll_s)
        session.command("halt", timeout_s=5)
        status = jtag_flash_read32(session, JTAG_FLASH_MAILBOX + 8)
        if status == JTAG_FLASH_STATUS_BUSY:
            session.command("resume", timeout_s=5)
            continue
        result = jtag_flash_read32(session, JTAG_FLASH_MAILBOX + 24)
        if status == JTAG_FLASH_STATUS_DONE:
            return result
        if status == JTAG_FLASH_STATUS_ERROR:
            raise RuntimeError(
                f"JTAG flash command {command} failed: result=0x{result:08X}"
            )
        session.command("resume", timeout_s=5)

    try:
        session.command("halt", timeout_s=5)
        status = jtag_flash_read32(session, JTAG_FLASH_MAILBOX + 8)
        result = jtag_flash_read32(session, JTAG_FLASH_MAILBOX + 24)
        snapshot = jtag_flash_debug_snapshot(session)
    except Exception:
        status = 0
        result = 0
        snapshot = "<snapshot unavailable>"
    raise RuntimeError(
        f"JTAG flash command {command} timed out "
        f"(status=0x{status:08X}, result=0x{result:08X})\n{snapshot}"
    )


def jtag_flash_program_segment(
    session: OpenOcdSession,
    segment: JtagFlashSegment,
    *,
    args: argparse.Namespace,
    work_dir: Path,
    test_name: str,
) -> None:
    if args.dry_run:
        print(f"DRY-RUN: JTAG flash {segment.label} at 0x{segment.address:06X}: {segment.path}")
        return

    data = segment.path.read_bytes()
    if not data:
        raise RuntimeError(f"JTAG flash segment is empty: {segment.path}")

    chunk_size = int(args.jtag_flash_chunk_size)
    if chunk_size < 1 or chunk_size > JTAG_FLASH_MAX_CHUNK:
        raise RuntimeError("--jtag-flash-chunk-size must be between 1 and 4096")

    print(
        f"JTAG flashing {segment.label}: "
        f"0x{segment.address:06X}+0x{len(data):X}"
    )
    erase_timeout = max(30.0, (len(data) / (64 * 1024)) * 8.0 + 20.0)
    run_jtag_flash_command(
        session,
        JTAG_FLASH_CMD_ERASE,
        address=segment.address,
        length=len(data),
        timeout_s=erase_timeout,
        poll_s=0.25,
    )

    chunk_path = work_dir / "jtag-flash" / test_name / "chunk.bin"
    ensure_parent(chunk_path)
    written = 0
    while written < len(data):
        chunk = data[written:written + chunk_size]
        chunk_path.write_bytes(chunk)
        session.command(
            f"load_image {chunk_path} 0x{JTAG_FLASH_DATA:08X} bin",
            timeout_s=20,
        )
        run_jtag_flash_command(
            session,
            JTAG_FLASH_CMD_WRITE_VERIFY,
            address=segment.address + written,
            length=len(chunk),
            checksum=jtag_flash_checksum(chunk),
            timeout_s=10,
        )
        written += len(chunk)
        if written == len(data) or (written % (64 * 1024)) == 0:
            print(f"  wrote 0x{written:X}/0x{len(data):X}")


def flash_firmware_over_jtag(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    outputs: dict[str, BuildOutput],
) -> None:
    segments = jtag_flash_segments_for_outputs(
        test,
        args=args,
        work_dir=work_dir,
        outputs=outputs,
    )
    flash_args = argparse.Namespace(**vars(args))
    flash_args.jtag_core = "m0"
    if args.jtag_load:
        raise RuntimeError("--jtag-flash and --jtag-load are mutually exclusive")

    session = prepare_jtag_session_with_recovery(
        args=flash_args,
        defaults=defaults,
        work_dir=work_dir,
        test_name=f"{test['name']}.jtag-flash",
        reset_target=True,
    )
    try:
        if not args.dry_run and not args.no_jtag_reset:
            initial_jtag_command_with_recovery(
                session,
                "reset halt",
                args=flash_args,
                log_path=session.log_path,
                timeout_s=10,
                reason="m0 reset-halt before JTAG flash",
            )
        stub = build_jtag_flash_stub(args=flash_args, work_dir=work_dir, test_name=test["name"])
        for offset in range(0, 32, 4):
            jtag_flash_write32(session, JTAG_FLASH_MAILBOX + offset, 0)
        session.command(f"load_image {stub}", timeout_s=60)
        initial_jtag_command_with_recovery(
            session,
            f"reg pc 0x{JTAG_FLASH_STUB_ENTRY:08X}",
            args=flash_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 JTAG flash stub PC set",
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=flash_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 JTAG flash stub resume",
        )
        if args.dry_run:
            for segment in segments:
                jtag_flash_program_segment(
                    session,
                    segment,
                    args=flash_args,
                    work_dir=work_dir,
                    test_name=test["name"],
                )
            return
        wait_for_jtag_flash_stub(session, args=flash_args, log_path=session.log_path)
        jedec = run_jtag_flash_command(
            session,
            JTAG_FLASH_CMD_READ_ID,
            timeout_s=5,
        )
        print(f"JTAG flash JEDEC ID: 0x{jedec:06X}")
        for segment in segments:
            jtag_flash_program_segment(
                session,
                segment,
                args=flash_args,
                work_dir=work_dir,
                test_name=test["name"],
            )
    finally:
        session.close()


def build_uart_flash_anchor(
    *,
    args: argparse.Namespace,
    work_dir: Path,
    test_name: str,
    flash_baud: int,
) -> Path:
    gcc = find_tool(args.riscv_gcc, "riscv64-unknown-elf-gcc")
    objcopy = find_tool(args.objcopy_rv32, "riscv32-unknown-elf-objcopy",
                        "riscv64-unknown-elf-objcopy")
    out_dir = work_dir / "uart-anchor-flash" / test_name / "anchor"
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / "uart_flash_anchor.elf"
    bin_path = out_dir / "uart_flash_anchor.bin"
    cmd = [
        gcc,
        "-march=rv32imafc",
        "-mabi=ilp32f",
        "-mcmodel=medlow",
        "-Os",
        "-ffreestanding",
        "-fno-builtin",
        "-nostdlib",
        "-nostartfiles",
        f"-DUART_ANCHOR_BAUD={flash_baud}",
        "-T",
        str(UART_FLASH_ANCHOR_LINKER),
        "-o",
        str(elf),
        str(UART_FLASH_ANCHOR_SOURCE),
    ]
    run_checked(
        cmd,
        cwd=REPO_ROOT,
        log_path=work_dir / "logs" / f"{test_name}.uart-anchor.build.log",
        timeout=60,
        dry_run=args.dry_run,
        env=harness_env(),
    )
    objcopy_cmd = [objcopy, "-O", "binary", str(elf), str(bin_path)]
    run_checked(
        objcopy_cmd,
        cwd=REPO_ROOT,
        log_path=work_dir / "logs" / f"{test_name}.uart-anchor.objcopy.log",
        timeout=60,
        dry_run=args.dry_run,
        env=harness_env(),
    )
    return bin_path


def serial_read_exact(ser: Any, length: int, *, timeout_s: float) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout_s
    while len(data) < length and time.monotonic() < deadline:
        chunk = ser.read(length - len(data))
        if chunk:
            data.extend(chunk)
            continue
        time.sleep(0.005)
    if len(data) != length:
        raise RuntimeError(f"UART anchor response timed out ({len(data)}/{length} bytes)")
    return bytes(data)


def serial_read_uart_anchor_response(ser: Any, *, timeout_s: float) -> bytes:
    magic = struct.pack("<I", UART_FLASH_RESP_MAGIC)
    match = 0
    skipped = bytearray()
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        chunk = ser.read(1)
        if not chunk:
            time.sleep(0.005)
            continue
        byte = chunk[0]
        if len(skipped) < 256:
            skipped.append(byte)
        if byte == magic[match]:
            match += 1
            if match == len(magic):
                rest = serial_read_exact(
                    ser,
                    12,
                    timeout_s=max(0.1, deadline - time.monotonic()),
                )
                return magic + rest
        else:
            match = 1 if byte == magic[0] else 0
    raise RuntimeError(
        "UART anchor response timed out while waiting for response magic; "
        f"skipped={bytes(skipped)!r}"
    )


def serial_drain_until_quiet(ser: Any, *, quiet_s: float = 0.25, timeout_s: float = 3.0) -> None:
    deadline = time.monotonic() + timeout_s
    quiet_deadline = time.monotonic() + quiet_s
    while time.monotonic() < deadline and time.monotonic() < quiet_deadline:
        waiting = getattr(ser, "in_waiting", 0)
        chunk = ser.read(max(1, min(waiting, 4096)))
        if chunk:
            quiet_deadline = time.monotonic() + quiet_s
        else:
            time.sleep(0.01)


def wait_for_uart_flash_anchor(ser: Any, *, log_path: Path, timeout_s: float = 5.0) -> None:
    ensure_parent(log_path)
    buffer = bytearray()
    deadline = time.monotonic() + timeout_s
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        while time.monotonic() < deadline:
            waiting = getattr(ser, "in_waiting", 0)
            chunk = ser.read(max(1, min(waiting, 4096)))
            if chunk:
                buffer.extend(chunk)
                log.write(chunk.decode("utf-8", errors="replace"))
                log.flush()
                if UART_FLASH_BANNER in buffer:
                    return
            else:
                time.sleep(0.01)
    text = buffer.decode("utf-8", errors="replace")
    raise RuntimeError(f"UART flash anchor banner not seen; received {text!r}")


def uart_flash_anchor_read_debug(
    session: OpenOcdSession,
    *,
    halt_target: bool = False,
) -> dict[str, int]:
    if halt_target:
        session.command("halt", timeout_s=5)
    try:
        text = session.command(f"mdw 0x{UART_FLASH_DEBUG_BASE:08X} 9", timeout_s=5)
        words = parse_openocd_words(text, UART_FLASH_DEBUG_BASE, 9)
    finally:
        if halt_target:
            session.command("resume", timeout_s=5)
    return {
        "command": words[0],
        "address": words[1],
        "length": words[2],
        "header_checksum": words[3],
        "expected_header_checksum": words[4],
        "status": words[5],
        "result": words[6],
        "counter": words[7],
        "sequence": words[8],
    }


def uart_flash_anchor_command_jtag_ack(
    ser: Any,
    session: OpenOcdSession,
    command: int,
    *,
    address: int = 0,
    length: int = 0,
    checksum: int = 0,
    payload: bytes = b"",
    timeout_s: float = 10.0,
    attempts: int = 1,
) -> tuple[int, int]:
    if payload and length not in (0, len(payload)):
        raise RuntimeError("internal error: UART anchor payload length mismatch")
    frame_length = len(payload) if payload else length
    expected_counter = (address + frame_length) & 0xFFFFFFFF
    header_checksum = uart_flash_header_checksum(command, address, frame_length)
    last_exc: Exception | None = None

    for attempt in range(max(1, attempts)):
        before_sequence = 0
        try:
            before_sequence = uart_flash_anchor_read_debug(session, halt_target=True).get("sequence", 0)
        except Exception as exc:
            last_exc = exc

        try:
            header = struct.pack(
                "<IIIIII",
                UART_FLASH_REQ_MAGIC,
                UART_FLASH_REQ_GUARD,
                command,
                address & 0xFFFFFFFF,
                frame_length & 0xFFFFFFFF,
                header_checksum,
            )
            ser.write(header)
            if payload:
                ser.write(struct.pack("<I", checksum & 0xFFFFFFFF))
                ser.write(payload)
            ser.flush()

            deadline = time.monotonic() + timeout_s
            last_debug: dict[str, int] | None = None
            while time.monotonic() < deadline:
                debug = uart_flash_anchor_read_debug(session, halt_target=True)
                last_debug = debug
                if debug["sequence"] <= before_sequence:
                    time.sleep(0.02)
                    continue
                if (
                    debug["command"] != command
                    or debug["address"] != (address & 0xFFFFFFFF)
                    or debug["length"] != (frame_length & 0xFFFFFFFF)
                    or debug["expected_header_checksum"] != header_checksum
                ):
                    time.sleep(0.02)
                    continue
                status = debug["status"]
                if status == UART_FLASH_DEBUG_STATUS_BUSY:
                    time.sleep(0.02)
                    continue
                result = debug["result"]
                counter = debug["counter"]
                if status != 0:
                    status_name = UART_FLASH_STATUS_NAMES.get(status, f"status {status}")
                    raise RuntimeError(
                        f"UART anchor command {command} failed via JTAG ack: {status_name}, "
                        f"result=0x{result:08X}, counter=0x{counter:08X}"
                    )
                if counter == expected_counter:
                    return result, counter
                raise RuntimeError(
                    f"UART anchor command {command} completed with counter "
                    f"0x{counter:08X}; expected 0x{expected_counter:08X}"
                )
            raise RuntimeError(
                f"UART anchor command {command} JTAG ack timed out; "
                f"last_debug={last_debug!r}"
            )
        except Exception as exc:
            last_exc = exc
            if attempt + 1 >= max(1, attempts):
                break
            time.sleep(0.05)

    if last_exc is None:
        raise RuntimeError(f"UART anchor command {command} failed via JTAG ack")
    raise last_exc


def uart_flash_anchor_command(
    ser: Any,
    command: int,
    *,
    address: int = 0,
    length: int = 0,
    checksum: int = 0,
    payload: bytes = b"",
    timeout_s: float = 10.0,
    attempts: int = 1,
) -> tuple[int, int]:
    if payload and length not in (0, len(payload)):
        raise RuntimeError("internal error: UART anchor payload length mismatch")
    frame_length = len(payload) if payload else length
    expected_counter = (address + frame_length) & 0xFFFFFFFF
    last_exc: Exception | None = None
    for attempt in range(max(1, attempts)):
        try:
            header_checksum = uart_flash_header_checksum(command, address, frame_length)
            header = struct.pack(
                "<IIIIII",
                UART_FLASH_REQ_MAGIC,
                UART_FLASH_REQ_GUARD,
                command,
                address & 0xFFFFFFFF,
                frame_length & 0xFFFFFFFF,
                header_checksum,
            )
            ser.write(header)
            if payload:
                ser.write(struct.pack("<I", checksum & 0xFFFFFFFF))
                ser.write(payload)
            ser.flush()

            deadline = time.monotonic() + timeout_s
            last_counter: int | None = None
            while time.monotonic() < deadline:
                response = serial_read_uart_anchor_response(
                    ser,
                    timeout_s=max(0.1, deadline - time.monotonic()),
                )
                magic, status, result, counter = struct.unpack("<IIII", response)
                if magic != UART_FLASH_RESP_MAGIC:
                    raise RuntimeError(
                        f"UART anchor returned bad response magic 0x{magic:08X}: {response!r}"
                    )
                if status != 0:
                    status_name = UART_FLASH_STATUS_NAMES.get(status, f"status {status}")
                    raise RuntimeError(
                        f"UART anchor command {command} failed: {status_name}, "
                        f"result=0x{result:08X}, counter=0x{counter:08X}"
                    )
                if counter == expected_counter:
                    return result, counter
                last_counter = counter
            raise RuntimeError(
                f"UART anchor command {command} only returned stale response "
                f"counter 0x{(last_counter or 0):08X}; expected 0x{expected_counter:08X}"
            )
        except Exception as exc:
            last_exc = exc
            if attempt + 1 >= max(1, attempts):
                break
            serial_drain_until_quiet(ser, quiet_s=0.05, timeout_s=0.25)
            time.sleep(0.05)
    if last_exc is None:
        raise RuntimeError(f"UART anchor command {command} failed")
    raise last_exc


def uart_flash_anchor_command_checked(
    ser: Any,
    command: int,
    *,
    session: OpenOcdSession | None,
    ack_mode: str,
    address: int = 0,
    length: int = 0,
    checksum: int = 0,
    payload: bytes = b"",
    timeout_s: float = 10.0,
    attempts: int = 1,
) -> tuple[int, int]:
    if ack_mode == "jtag":
        if session is None:
            raise RuntimeError("JTAG UART anchor ack mode requires an OpenOCD session")
        return uart_flash_anchor_command_jtag_ack(
            ser,
            session,
            command,
            address=address,
            length=length,
            checksum=checksum,
            payload=payload,
            timeout_s=timeout_s,
            attempts=attempts,
        )
    return uart_flash_anchor_command(
        ser,
        command,
        address=address,
        length=length,
        checksum=checksum,
        payload=payload,
        timeout_s=timeout_s,
        attempts=attempts,
    )


def uart_flash_anchor_ping_until_ready(ser: Any, *, timeout_s: float = 5.0) -> int:
    deadline = time.monotonic() + timeout_s
    last_exc: Exception | None = None
    while time.monotonic() < deadline:
        try:
            version, _ = uart_flash_anchor_command(
                ser,
                UART_FLASH_CMD_PING,
                timeout_s=max(0.25, min(1.0, deadline - time.monotonic())),
            )
            return version
        except Exception as exc:
            last_exc = exc
            time.sleep(0.05)
    if last_exc is None:
        raise RuntimeError("UART flash anchor did not answer ping")
    raise RuntimeError(f"UART flash anchor did not answer ping: {last_exc}") from last_exc


def uart_flash_anchor_ping_until_ready_jtag(
    ser: Any,
    session: OpenOcdSession,
    *,
    timeout_s: float = 5.0,
) -> int:
    deadline = time.monotonic() + timeout_s
    last_exc: Exception | None = None
    while time.monotonic() < deadline:
        try:
            version, _ = uart_flash_anchor_command_jtag_ack(
                ser,
                session,
                UART_FLASH_CMD_PING,
                timeout_s=max(0.25, min(1.0, deadline - time.monotonic())),
            )
            return version
        except Exception as exc:
            last_exc = exc
            time.sleep(0.05)
    if last_exc is None:
        raise RuntimeError("UART flash anchor did not answer ping via JTAG ack")
    raise RuntimeError(f"UART flash anchor did not answer ping via JTAG ack: {last_exc}") from last_exc


def select_uart_flash_anchor_ack_mode(
    args: argparse.Namespace,
    ser: Any,
    session: OpenOcdSession | None,
    *,
    log_path: Path,
    prefix: str,
) -> str:
    requested = str(getattr(args, "uart_anchor_ack_mode", "auto"))
    if requested == "jtag":
        if session is None:
            raise RuntimeError("UART anchor JTAG ack mode requires an OpenOCD session")
        version = uart_flash_anchor_ping_until_ready_jtag(ser, session, timeout_s=10)
        if version != 1:
            raise RuntimeError(f"unexpected UART flash anchor version via JTAG ack: {version}")
        append_log(log_path, f"\n# {prefix} using UART anchor JTAG ack mode\n")
        return "jtag"

    try:
        version = uart_flash_anchor_ping_until_ready(ser, timeout_s=10)
        if version != 1:
            raise RuntimeError(f"unexpected UART flash anchor version: {version}")
        append_log(log_path, f"\n# {prefix} using UART anchor UART ack mode\n")
        return "uart"
    except Exception as uart_exc:
        if requested == "uart":
            raise
        if session is None:
            raise RuntimeError(
                f"{prefix} UART ack failed and no OpenOCD session is available "
                f"for JTAG ack fallback: {uart_exc}"
            ) from uart_exc
        append_log(
            log_path,
            f"\n# {prefix} UART anchor UART ack failed; trying JTAG ack: {uart_exc}\n",
        )
        version = uart_flash_anchor_ping_until_ready_jtag(ser, session, timeout_s=10)
        if version != 1:
            raise RuntimeError(f"unexpected UART flash anchor version via JTAG ack: {version}")
        append_log(log_path, f"\n# {prefix} using UART anchor JTAG ack mode\n")
        return "jtag"


def uart_anchor_flash_program_segment(
    ser: Any,
    segment: JtagFlashSegment,
    *,
    args: argparse.Namespace,
    session: OpenOcdSession | None = None,
    ack_mode: str = "uart",
) -> None:
    if args.dry_run:
        print(
            f"DRY-RUN: UART-anchor flash {segment.label} "
            f"at 0x{segment.address:06X}: {segment.path}"
        )
        return

    data = segment.path.read_bytes()
    if not data:
        raise RuntimeError(f"UART anchor flash segment is empty: {segment.path}")

    chunk_size = int(args.uart_anchor_flash_chunk_size)
    if chunk_size < 1 or chunk_size > JTAG_FLASH_MAX_CHUNK:
        raise RuntimeError("--uart-anchor-flash-chunk-size must be between 1 and 4096")

    print(
        f"UART-anchor flashing {segment.label}: "
        f"0x{segment.address:06X}+0x{len(data):X}"
    )
    erase_timeout = max(30.0, (len(data) / (64 * 1024)) * 8.0 + 20.0)
    uart_flash_anchor_command_checked(
        ser,
        UART_FLASH_CMD_ERASE,
        session=session,
        ack_mode=ack_mode,
        address=segment.address,
        length=len(data),
        checksum=uart_flash_header_checksum(
            UART_FLASH_CMD_ERASE,
            segment.address,
            len(data),
        ),
        timeout_s=erase_timeout,
        attempts=3,
    )

    written = 0
    while written < len(data):
        chunk = data[written:written + chunk_size]
        uart_flash_anchor_command_checked(
            ser,
            UART_FLASH_CMD_WRITE_VERIFY,
            session=session,
            ack_mode=ack_mode,
            address=segment.address + written,
            payload=chunk,
            checksum=jtag_flash_checksum(chunk),
            timeout_s=30.0,
            attempts=3,
        )
        written += len(chunk)
        if written == len(data) or (written % (64 * 1024)) == 0:
            print(f"  wrote 0x{written:X}/0x{len(data):X}")


def uart_anchor_request_reboot(
    ser: Any,
    *,
    args: argparse.Namespace,
    session: OpenOcdSession | None = None,
    ack_mode: str = "uart",
) -> None:
    if args.dry_run:
        print("DRY-RUN: UART-anchor reboot target after flash")
        return
    uart_flash_anchor_command_checked(
        ser,
        UART_FLASH_CMD_REBOOT,
        session=session,
        ack_mode=ack_mode,
        timeout_s=5,
        attempts=3,
    )
    print("UART anchor reboot requested", flush=True)


def flash_firmware_over_uart_anchor(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    outputs: dict[str, BuildOutput],
    flash_port: str,
    flash_baud: int,
    dtr: bool | None,
    rts: bool | None,
) -> None:
    if args.jtag_flash or args.jtag_load:
        raise RuntimeError(
            "--uart-anchor-flash is mutually exclusive with --jtag-flash and --jtag-load"
        )
    segments = jtag_flash_segments_for_outputs(
        test,
        args=args,
        work_dir=work_dir,
        outputs=outputs,
    )
    anchor_args = argparse.Namespace(**vars(args))
    anchor_args.jtag_core = "m0"

    anchor: Path | None = None
    if not args.uart_anchor_existing:
        anchor = build_uart_flash_anchor(
            args=anchor_args,
            work_dir=work_dir,
            test_name=test["name"],
            flash_baud=flash_baud,
        )

    if args.dry_run:
        if args.uart_anchor_existing:
            print(f"DRY-RUN: use existing UART flash anchor on {flash_port} at {flash_baud}")
        else:
            print(f"DRY-RUN: open UART flash anchor port {flash_port} at {flash_baud}")
        for segment in segments:
            uart_anchor_flash_program_segment(None, segment, args=anchor_args)
        if args.uart_anchor_reset_after_flash:
            uart_anchor_request_reboot(None, args=anchor_args)
        return

    try:
        import serial  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "pyserial is required for --uart-anchor-flash. "
            "Install it with: python3 -m pip install pyserial"
        ) from exc

    ser: Any | None = None
    session: OpenOcdSession | None = None
    try:
        if args.uart_anchor_existing:
            anchor_log_path = work_dir / "logs" / f"{test['name']}.uart-anchor-existing.log"
            append_log(
                anchor_log_path,
                "\n# use existing UART flash anchor; no JTAG load/reset performed\n",
            )
            ser = open_serial_device(
                serial,
                port=flash_port,
                baud=flash_baud,
                timeout=0.05,
                write_timeout=10,
                dtr=dtr,
                rts=rts,
            )
            ser.reset_input_buffer()
            ser.reset_output_buffer()
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ack_mode = select_uart_flash_anchor_ack_mode(
                args,
                ser,
                None,
                log_path=anchor_log_path,
                prefix="existing UART flash anchor",
            )
            jedec, _ = uart_flash_anchor_command_checked(
                ser,
                UART_FLASH_CMD_READ_ID,
                session=None,
                ack_mode=ack_mode,
                timeout_s=5,
                attempts=3,
            )
            print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}")
            for segment in segments:
                uart_anchor_flash_program_segment(
                    ser,
                    segment,
                    args=anchor_args,
                    session=None,
                    ack_mode=ack_mode,
                )
            if args.uart_anchor_reset_after_flash:
                uart_anchor_request_reboot(
                    ser,
                    args=anchor_args,
                    session=None,
                    ack_mode=ack_mode,
                )
            return

        assert anchor is not None
        session = prepare_jtag_session_with_recovery(
            args=anchor_args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=f"{test['name']}.uart-anchor",
            reset_target=True,
        )
        initial_jtag_command_with_recovery(
            session,
            "reset halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 reset-halt before UART anchor flash",
        )
        initial_jtag_command_with_recovery(
            session,
            "halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=5,
            reason="m0 halt before UART anchor load",
        )
        session.command(f"load_image {anchor} 0x{UART_FLASH_ANCHOR_ENTRY:08X} bin", timeout_s=60)
        initial_jtag_command_with_recovery(
            session,
            f"reg pc 0x{UART_FLASH_ANCHOR_ENTRY:08X}",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 UART flash anchor PC set",
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 UART flash anchor resume",
        )
        anchor_log_path = session.log_path
        append_log(
            anchor_log_path,
            "\n# open UART anchor port after anchor resume; keep OpenOCD attached for diagnostics\n",
        )

        ser = open_serial_device(
            serial,
            port=flash_port,
            baud=flash_baud,
            timeout=0.05,
            write_timeout=10,
            dtr=dtr,
            rts=rts,
        )
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        try:
            wait_for_uart_flash_anchor(
                ser,
                log_path=work_dir / "logs" / f"{test['name']}.uart-anchor.banner.log",
                timeout_s=5.0,
            )
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ser.reset_input_buffer()
        except Exception as banner_exc:
            append_log(
                anchor_log_path,
                f"\n# UART flash anchor banner not observed before ping: {banner_exc}\n",
            )
        try:
            ack_mode = select_uart_flash_anchor_ack_mode(
                args,
                ser,
                session,
                log_path=anchor_log_path,
                prefix="UART flash anchor",
            )
        except Exception as ping_exc:
            append_log(
                anchor_log_path,
                f"\n# UART flash anchor did not answer ping while OpenOCD remained attached: {ping_exc}\n",
            )
            append_log(
                anchor_log_path,
                "\n# UART flash anchor JTAG snapshot after ping failure\n"
                f"{uart_flash_anchor_debug_snapshot(session)}\n",
            )
            raise
        jedec, _ = uart_flash_anchor_command_checked(
            ser,
            UART_FLASH_CMD_READ_ID,
            session=session,
            ack_mode=ack_mode,
            timeout_s=5,
            attempts=3,
        )
        print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}")
        for segment in segments:
            uart_anchor_flash_program_segment(
                ser,
                segment,
                args=anchor_args,
                session=session,
                ack_mode=ack_mode,
            )
        if args.uart_anchor_reset_after_flash:
            uart_anchor_request_reboot(
                ser,
                args=anchor_args,
                session=session,
                ack_mode=ack_mode,
            )
    finally:
        if ser is not None:
            ser.close()
        if session is not None:
            session.close()


def default_prebuilt_ble_snapshot_commands() -> list[str]:
    return [
        "poll",
        "reg pc",
        "reg sp",
        "reg ra",
        "reg a0",
        "reg a1",
        "reg a2",
        "reg s1",
        "reg s2",
        "reg mepc",
        "reg mcause",
        "reg mtval",
        "mdw 0x200010b0 4",
        "mdw 0x200010b8 4",
        "mdw 0x20000250 1",
        "mdw 0x20000540 3",
        "mdw 0x20000580 3",
        "mdw 0x2000060c 1",
        "mdw 0x20000810 9",
        "mdw 0x2000f880 1",
        "mdw 0x28000018 3",
        "mdw 0x28000100 2",
        "mdw 0x28000110 1",
        "mdw 0x280009c0 3",
        "mdw 0x28010000 4",
        "mdw 0x28010120 18",
        "mdw 0x28010558 6",
        "mdw 0x28010a2c 8",
    ]


def run_uart_anchor_build_only(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    defaults = manifest.get("defaults", {})
    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)
    flash_baud = int(args.flash_baud or args.uart_baud or defaults.get("uart_baud", 230_400))
    anchor_args = argparse.Namespace(**vars(args))
    anchor_args.jtag_core = "m0"
    test_name = "uart_anchor_persistent"

    print("UART-anchor build-only", flush=True)
    print(f"work_dir={work_dir}", flush=True)
    print(f"baud={flash_baud}", flush=True)

    anchor = build_uart_flash_anchor(
        args=anchor_args,
        work_dir=work_dir,
        test_name=test_name,
        flash_baud=flash_baud,
    )
    if args.dry_run:
        print("DRY-RUN: build persistent UART anchor flash image")
        return 0

    output = BuildOutput(
        build_id="uart_anchor",
        core="bl808m0",
        source=str(UART_FLASH_ANCHOR_SOURCE),
        elf=anchor.with_suffix(".elf"),
        bin=anchor,
        flash_core="m0",
    )
    segments = build_m0_jtag_flash_segments(
        output,
        args=anchor_args,
        work_dir=work_dir,
        test_name=test_name,
    )
    image_dir = work_dir / "uart-anchor-persistent"
    image_dir.mkdir(parents=True, exist_ok=True)
    image = image_dir / "whole_flash_data.bin"
    image_data = build_compact_flash_image(segments)
    image.write_bytes(image_data)
    anchor_bytes = anchor.read_bytes()
    anchor_flash_offset = find_unique_payload_offset(
        image_data,
        anchor_bytes,
        label="UART anchor",
    )
    expected_anchor_flash_offset = BL808_FLASH_OFFSET_FW + BL808_FW_BOOTINFO_SIZE
    install_with_uart_boot = shlex.join([
        str(resolve_repo_path(args.upload_script)),
        "m0",
        str(anchor),
        "<uart-port>",
        str(flash_baud),
    ])
    install_with_existing_anchor = shlex.join([
        sys.executable,
        str(Path(__file__).resolve()),
        "--uart-anchor-flash-image",
        str(image),
        "--uart-anchor-flash-image-address",
        "0",
        "--uart-anchor-reset-after-flash",
        "--uart-anchor-existing",
        "--no-jtag",
        "--uart",
        "<uart-port>",
    ])
    recovery_manifest = image_dir / "recovery_manifest.json"
    recovery_manifest.write_text(
        json.dumps(
            {
                "kind": "bl808-uart-anchor-recovery",
                "version": 1,
                "baud": flash_baud,
                "anchor_bin": str(anchor),
                "anchor_size": len(anchor_bytes),
                "anchor_sha256": file_sha256(anchor),
                "anchor_payload": {
                    "flash_offset": anchor_flash_offset,
                    "flash_offset_hex": f"0x{anchor_flash_offset:06X}",
                    "expected_boot2_wrapped_flash_offset": expected_anchor_flash_offset,
                    "expected_boot2_wrapped_flash_offset_hex": (
                        f"0x{expected_anchor_flash_offset:06X}"
                    ),
                    "matches_expected_boot2_wrapped_offset": (
                        anchor_flash_offset == expected_anchor_flash_offset
                    ),
                },
                "whole_flash_image": str(image),
                "whole_flash_size": image.stat().st_size,
                "whole_flash_sha256": file_sha256(image),
                "segments": [
                    {
                        "label": segment.label,
                        "address": segment.address,
                        "path": str(segment.path),
                        "size": segment.path.stat().st_size,
                        "sha256": file_sha256(segment.path),
                    }
                    for segment in segments
                ],
                "commands": {
                    "install_with_uart_boot": install_with_uart_boot,
                    "install_with_existing_anchor": install_with_existing_anchor,
                },
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"anchor_bin={anchor}", flush=True)
    print(f"whole_flash_image={image}", flush=True)
    print(f"recovery_manifest={recovery_manifest}", flush=True)
    print(f"install_with_uart_boot={install_with_uart_boot}", flush=True)
    print(f"install_with_existing_anchor={install_with_existing_anchor}", flush=True)
    return 0


def run_uart_anchor_probe(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    defaults = manifest.get("defaults", {})
    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)
    configure_sudo_askpass(args, work_dir)

    if args.no_jtag and not args.uart_anchor_existing:
        raise RuntimeError("--uart-anchor-probe requires JTAG; remove --no-jtag")
    flash_port = args.flash_port or args.uart
    if flash_port is None and not args.dry_run:
        raise RuntimeError("--flash-port or --uart is required for --uart-anchor-probe")

    flash_baud = int(args.flash_baud or args.uart_baud or defaults.get("uart_baud", 230_400))
    serial_dtr = modem_control_state(args.serial_dtr)
    serial_rts = modem_control_state(args.serial_rts)
    test_name = "uart_anchor_probe"
    anchor_args = argparse.Namespace(**vars(args))
    anchor_args.jtag_core = "m0"

    print("UART-anchor probe", flush=True)
    print(f"work_dir={work_dir}", flush=True)
    if flash_port:
        print(f"uart={flash_port}", flush=True)

    anchor: Path | None = None
    if not args.uart_anchor_existing:
        anchor = build_uart_flash_anchor(
            args=anchor_args,
            work_dir=work_dir,
            test_name=test_name,
            flash_baud=flash_baud,
        )

    if args.dry_run:
        if args.uart_anchor_existing:
            print(f"DRY-RUN: probe existing UART flash anchor on {flash_port or '<uart>'} at {flash_baud}")
        else:
            print(f"DRY-RUN: open UART flash anchor port {flash_port or '<uart>'} at {flash_baud}")
        return 0

    try:
        import serial  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "pyserial is required for --uart-anchor-probe. "
            "Install it with: python3 -m pip install pyserial"
        ) from exc

    ser: Any | None = None
    session: OpenOcdSession | None = None
    try:
        if args.uart_anchor_existing:
            anchor_log_path = work_dir / "logs" / f"{test_name}.uart-anchor-existing.log"
            append_log(
                anchor_log_path,
                "\n# probe existing UART flash anchor; no JTAG load/reset performed\n",
            )
            ser = open_serial_device(
                serial,
                port=flash_port or "",
                baud=flash_baud,
                timeout=0.05,
                write_timeout=10,
                dtr=serial_dtr,
                rts=serial_rts,
            )
            ser.reset_input_buffer()
            ser.reset_output_buffer()
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ack_mode = select_uart_flash_anchor_ack_mode(
                args,
                ser,
                None,
                log_path=anchor_log_path,
                prefix="existing UART flash anchor probe",
            )
            jedec, _ = uart_flash_anchor_command_checked(
                ser,
                UART_FLASH_CMD_READ_ID,
                session=None,
                ack_mode=ack_mode,
                timeout_s=5,
                attempts=3,
            )
            print(f"UART anchor ack mode: {ack_mode}", flush=True)
            print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}", flush=True)
            return 0

        assert anchor is not None
        session = prepare_jtag_session_with_recovery(
            args=anchor_args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=f"{test_name}.uart-anchor",
            reset_target=True,
        )
        initial_jtag_command_with_recovery(
            session,
            "reset halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 reset-halt before UART anchor probe",
        )
        initial_jtag_command_with_recovery(
            session,
            "halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=5,
            reason="m0 halt before UART anchor probe load",
        )
        session.command(f"load_image {anchor} 0x{UART_FLASH_ANCHOR_ENTRY:08X} bin", timeout_s=60)
        initial_jtag_command_with_recovery(
            session,
            f"reg pc 0x{UART_FLASH_ANCHOR_ENTRY:08X}",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 UART anchor probe PC set",
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 UART anchor probe resume",
        )
        append_log(
            session.log_path,
            "\n# open UART anchor port after probe anchor resume; keep OpenOCD attached for diagnostics\n",
        )

        ser = open_serial_device(
            serial,
            port=flash_port or "",
            baud=flash_baud,
            timeout=0.05,
            write_timeout=10,
            dtr=serial_dtr,
            rts=serial_rts,
        )
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        try:
            wait_for_uart_flash_anchor(
                ser,
                log_path=work_dir / "logs" / f"{test_name}.uart-anchor.banner.log",
                timeout_s=5.0,
            )
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ser.reset_input_buffer()
        except Exception as banner_exc:
            append_log(
                session.log_path,
                f"\n# UART flash anchor probe banner not observed before ping: {banner_exc}\n",
            )

        ack_mode = select_uart_flash_anchor_ack_mode(
            args,
            ser,
            session,
            log_path=session.log_path,
            prefix="UART flash anchor probe",
        )
        jedec, _ = uart_flash_anchor_command_checked(
            ser,
            UART_FLASH_CMD_READ_ID,
            session=session,
            ack_mode=ack_mode,
            timeout_s=5,
            attempts=3,
        )
        print(f"UART anchor ack mode: {ack_mode}", flush=True)
        print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}", flush=True)
    finally:
        if ser is not None:
            ser.close()
        if session is not None:
            session.close()

    return 0


def run_uart_anchor_prebuilt(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    defaults = manifest.get("defaults", {})
    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)
    configure_sudo_askpass(args, work_dir)

    if args.no_jtag and not args.uart_anchor_existing:
        raise RuntimeError("--uart-anchor-flash-image requires JTAG; remove --no-jtag")
    if args.jtag_flash or args.jtag_load:
        raise RuntimeError("--uart-anchor-flash-image is mutually exclusive with --jtag-flash and --jtag-load")
    if args.uart_anchor_existing and args.prebuilt_snapshot_after_marker:
        raise RuntimeError(
            "--prebuilt-snapshot-after-marker is not supported with "
            "--uart-anchor-existing because the existing-anchor path does not "
            "load/reset/run the target through JTAG"
        )
    if args.uart_anchor_reset_after_flash and args.prebuilt_snapshot_after_marker:
        raise RuntimeError(
            "--prebuilt-snapshot-after-marker is not supported with "
            "--uart-anchor-reset-after-flash because the reboot happens before "
            "the snapshot JTAG session can be prepared"
        )

    flash_port = args.flash_port or args.uart
    if flash_port is None and not args.dry_run:
        raise RuntimeError("--flash-port or --uart is required for --uart-anchor-flash-image")
    if args.prebuilt_snapshot_after_marker and args.uart is None and not args.dry_run:
        raise RuntimeError("--uart is required for --prebuilt-snapshot-after-marker")

    image = resolve_repo_path(args.uart_anchor_flash_image)
    if not image.exists() and not args.dry_run:
        raise RuntimeError(f"prebuilt flash image does not exist: {image}")

    label = args.uart_anchor_flash_image_label or image.stem
    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "_", label).strip("_") or "prebuilt"
    test_name = f"prebuilt_{safe_label}"
    flash_baud = int(args.flash_baud or args.uart_baud or defaults.get("uart_baud", 230_400))
    uart_baud = int(args.uart_baud or defaults.get("uart_baud", 230_400))
    serial_dtr = modem_control_state(args.serial_dtr)
    serial_rts = modem_control_state(args.serial_rts)

    print("UART-anchor prebuilt flash", flush=True)
    print(f"work_dir={work_dir}", flush=True)
    print(f"image={image}", flush=True)
    print(f"address=0x{int(args.uart_anchor_flash_image_address):06X}", flush=True)
    if flash_port:
        print(f"uart={flash_port}", flush=True)

    anchor_args = argparse.Namespace(**vars(args))
    anchor_args.jtag_core = "m0"
    anchor: Path | None = None
    if not args.uart_anchor_existing:
        anchor = build_uart_flash_anchor(
            args=anchor_args,
            work_dir=work_dir,
            test_name=test_name,
            flash_baud=flash_baud,
        )
    segment = JtagFlashSegment(
        int(args.uart_anchor_flash_image_address),
        image,
        label,
    )

    if args.dry_run:
        if args.uart_anchor_existing:
            print(f"DRY-RUN: use existing UART flash anchor on {flash_port or '<uart>'} at {flash_baud}")
        else:
            print(f"DRY-RUN: open UART flash anchor port {flash_port or '<uart>'} at {flash_baud}")
        uart_anchor_flash_program_segment(None, segment, args=anchor_args)
        if args.uart_anchor_reset_after_flash:
            uart_anchor_request_reboot(None, args=anchor_args)
        return 0

    try:
        import serial  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "pyserial is required for --uart-anchor-flash-image. "
            "Install it with: python3 -m pip install pyserial"
        ) from exc

    ser: Any | None = None
    session: OpenOcdSession | None = None
    try:
        if args.uart_anchor_existing:
            anchor_log_path = work_dir / "logs" / f"{test_name}.uart-anchor-existing.log"
            append_log(
                anchor_log_path,
                "\n# use existing UART flash anchor for prebuilt image; no JTAG load/reset performed\n",
            )
            ser = open_serial_device(
                serial,
                port=flash_port or "",
                baud=flash_baud,
                timeout=0.05,
                write_timeout=10,
                dtr=serial_dtr,
                rts=serial_rts,
            )
            ser.reset_input_buffer()
            ser.reset_output_buffer()
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ack_mode = select_uart_flash_anchor_ack_mode(
                args,
                ser,
                None,
                log_path=anchor_log_path,
                prefix="existing prebuilt UART flash anchor",
            )
            jedec, _ = uart_flash_anchor_command_checked(
                ser,
                UART_FLASH_CMD_READ_ID,
                session=None,
                ack_mode=ack_mode,
                timeout_s=5,
                attempts=3,
            )
            print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}", flush=True)
            uart_anchor_flash_program_segment(
                ser,
                segment,
                args=anchor_args,
                session=None,
                ack_mode=ack_mode,
            )
            if args.uart_anchor_reset_after_flash:
                uart_anchor_request_reboot(
                    ser,
                    args=anchor_args,
                    session=None,
                    ack_mode=ack_mode,
                )
            print("Prebuilt image flashed", flush=True)
            return 0

        assert anchor is not None
        session = prepare_jtag_session_with_recovery(
            args=anchor_args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=f"{test_name}.uart-anchor",
            reset_target=True,
        )
        initial_jtag_command_with_recovery(
            session,
            "reset halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 reset-halt before prebuilt UART anchor flash",
        )
        initial_jtag_command_with_recovery(
            session,
            "halt",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=5,
            reason="m0 halt before prebuilt UART anchor load",
        )
        session.command(f"load_image {anchor} 0x{UART_FLASH_ANCHOR_ENTRY:08X} bin", timeout_s=60)
        initial_jtag_command_with_recovery(
            session,
            f"reg pc 0x{UART_FLASH_ANCHOR_ENTRY:08X}",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 prebuilt UART flash anchor PC set",
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=anchor_args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 prebuilt UART flash anchor resume",
        )
        anchor_log_path = session.log_path
        append_log(
            anchor_log_path,
            "\n# open prebuilt UART anchor port after anchor resume; keep OpenOCD attached for diagnostics\n",
        )

        ser = open_serial_device(
            serial,
            port=flash_port or "",
            baud=flash_baud,
            timeout=0.05,
            write_timeout=10,
            dtr=serial_dtr,
            rts=serial_rts,
        )
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        try:
            wait_for_uart_flash_anchor(
                ser,
                log_path=work_dir / "logs" / f"{test_name}.uart-anchor.banner.log",
                timeout_s=5.0,
            )
            serial_drain_until_quiet(ser, quiet_s=0.15, timeout_s=1.0)
            ser.reset_input_buffer()
        except Exception as banner_exc:
            append_log(
                anchor_log_path,
                f"\n# UART flash anchor banner not observed before ping: {banner_exc}\n",
            )
        try:
            ack_mode = select_uart_flash_anchor_ack_mode(
                args,
                ser,
                session,
                log_path=anchor_log_path,
                prefix="prebuilt UART flash anchor",
            )
        except Exception as ping_exc:
            append_log(
                anchor_log_path,
                f"\n# prebuilt UART flash anchor did not answer ping while OpenOCD remained attached: {ping_exc}\n",
            )
            append_log(
                anchor_log_path,
                "\n# prebuilt UART flash anchor JTAG snapshot after ping failure\n"
                f"{uart_flash_anchor_debug_snapshot(session)}\n",
            )
            raise
        jedec, _ = uart_flash_anchor_command_checked(
            ser,
            UART_FLASH_CMD_READ_ID,
            session=session,
            ack_mode=ack_mode,
            timeout_s=5,
            attempts=3,
        )
        print(f"UART anchor flash JEDEC ID: 0x{jedec:06X}", flush=True)
        uart_anchor_flash_program_segment(
            ser,
            segment,
            args=anchor_args,
            session=session,
            ack_mode=ack_mode,
        )
        if args.uart_anchor_reset_after_flash:
            uart_anchor_request_reboot(
                ser,
                args=anchor_args,
                session=session,
                ack_mode=ack_mode,
            )
    finally:
        if ser is not None:
            ser.close()
        if session is not None:
            session.close()

    marker = args.prebuilt_snapshot_after_marker
    if not marker:
        print("Prebuilt image flashed", flush=True)
        return 0

    primary: SerialCapture | None = None
    session = None
    try:
        primary = SerialCapture(
            args.uart or "",
            uart_baud,
            "primary",
            work_dir / "logs" / f"{test_name}.primary.uart.log",
            dtr=serial_dtr,
            rts=serial_rts,
        )
        session = prepare_jtag_session_with_recovery(
            args=args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=test_name,
            reset_target=True,
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=args,
            log_path=session.log_path,
            timeout_s=10,
            reason="m0 prebuilt image resume",
        )

        deadline = time.monotonic() + float(args.prebuilt_snapshot_timeout)
        while time.monotonic() < deadline:
            primary.read_available()
            if marker in primary.output:
                time.sleep(max(0.0, float(args.prebuilt_snapshot_delay)))
                primary.read_available()
                commands = (
                    list(args.prebuilt_snapshot_command)
                    if args.prebuilt_snapshot_command
                    else default_prebuilt_ble_snapshot_commands()
                )
                snapshot = capture_jtag_snapshot(session, commands, halt_first=True)
                print(snapshot, flush=True)
                print(f"Prebuilt marker snapshot captured after {marker!r}", flush=True)
                return 0
            time.sleep(0.02)

        snapshot = capture_jtag_snapshot(
            session,
            ["poll", "reg pc", "reg mcause", "reg mepc", "reg mtval"],
            halt_first=True,
        )
        print(snapshot, flush=True)
        print(f"Timed out waiting for prebuilt marker {marker!r}", flush=True)
        return 1
    finally:
        if primary is not None:
            primary.close()
        if session is not None:
            session.close()


def jtag_load_entry(output: BuildOutput) -> int:
    if output.core == "bl808m0":
        return 0x22020000
    if output.core == "bl808d0":
        return 0x3EFF0000
    if output.core == "bl808lp":
        return JTAG_LP_ENTRY_ADDR
    raise RuntimeError(
        f"JTAG RAM load is not implemented for {output.core}; "
        "currently M0, D0, and LP RAM images are supported"
    )


def jtag_m0_d0_pair(outputs: dict[str, BuildOutput]) -> tuple[BuildOutput, BuildOutput] | None:
    load_items = [output for output in outputs.values() if output.flash_core]
    by_flash_core = {output.flash_core: output for output in load_items}
    if len(load_items) != 2 or {"m0", "d0"} != set(by_flash_core):
        return None
    m0 = by_flash_core["m0"]
    d0 = by_flash_core["d0"]
    if m0.core != "bl808m0" or d0.core != "bl808d0":
        raise RuntimeError(
            f"--jtag-load expected M0+D0 images, got "
            f"{m0.build_id}:{m0.core}->{m0.flash_core}, "
            f"{d0.build_id}:{d0.core}->{d0.flash_core}"
        )
    return m0, d0


def jtag_m0_lp_pair(outputs: dict[str, BuildOutput]) -> tuple[BuildOutput, BuildOutput] | None:
    load_items = [output for output in outputs.values() if output.flash_core]
    by_flash_core = {output.flash_core: output for output in load_items}
    if len(load_items) != 2 or {"m0", "lp"} != set(by_flash_core):
        return None
    m0 = by_flash_core["m0"]
    lp = by_flash_core["lp"]
    if m0.core != "bl808m0" or lp.core != "bl808lp":
        raise RuntimeError(
            f"--jtag-load expected M0+LP images, got "
            f"{m0.build_id}:{m0.core}->{m0.flash_core}, "
            f"{lp.build_id}:{lp.core}->{lp.flash_core}"
        )
    return m0, lp


def jtag_m0_d0_lp_set(
    outputs: dict[str, BuildOutput],
) -> tuple[BuildOutput, BuildOutput, BuildOutput] | None:
    load_items = [output for output in outputs.values() if output.flash_core]
    by_flash_core = {output.flash_core: output for output in load_items}
    if len(load_items) != 3 or {"m0", "d0", "lp"} != set(by_flash_core):
        return None
    m0 = by_flash_core["m0"]
    d0 = by_flash_core["d0"]
    lp = by_flash_core["lp"]
    if m0.core != "bl808m0" or d0.core != "bl808d0" or lp.core != "bl808lp":
        raise RuntimeError(
            f"--jtag-load expected M0+D0+LP images, got "
            f"{m0.build_id}:{m0.core}->{m0.flash_core}, "
            f"{d0.build_id}:{d0.core}->{d0.flash_core}, "
            f"{lp.build_id}:{lp.core}->{lp.flash_core}"
        )
    return m0, d0, lp


def load_firmware_over_jtag(
    test: dict[str, Any],
    *,
    session: OpenOcdSession,
    outputs: dict[str, BuildOutput],
) -> int:
    load_items = [output for output in outputs.values() if output.flash_core]
    by_flash_core = {output.flash_core: output for output in load_items}

    if len(load_items) == 1:
        item = load_items[0]
        if item.flash_core != "m0" or item.core != "bl808m0":
            raise RuntimeError(
                f"--jtag-load currently supports single M0 images only, got "
                f"{item.build_id}:{item.core}->{item.flash_core}"
            )
        entry = jtag_load_entry(item)
        # Reset-halt at the BootROM first, so any lingering PMP/TZC config from
        # the firmware currently in flash (e.g. an enclave image that locks OCRAM
        # out of U-mode/exec) is cleared before we load and run the RAM image.
        # Without this, the RAM entry can take an instruction-access fault.
        session.command("reset halt", timeout_s=10)
        session.command(f"load_image {item.elf}", timeout_s=60)
        return entry

    if (
        jtag_m0_d0_pair(outputs) is not None
        or jtag_m0_lp_pair(outputs) is not None
        or jtag_m0_d0_lp_set(outputs) is not None
    ):
        raise RuntimeError(
            "internal error: multi-core JTAG load requires a staged loader"
        )

    if len(load_items) != 1:
        raise RuntimeError(
            f"{test['name']} has {len(load_items)} flash images; "
            "--jtag-load currently supports one M0 image, one M0+D0 image set, "
            "one M0+LP image set, or one M0+D0+LP image set"
        )

    raise RuntimeError(f"--jtag-load unsupported image set for {test['name']}")


def wait_for_serial_marker(
    capture: SerialCapture | None,
    marker: str,
    *,
    timeout_s: float,
) -> bool:
    if capture is None:
        return False
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        capture.read_available()
        if marker in capture.output:
            return True
        time.sleep(0.02)
    return False


def load_m0_lp_firmware_over_jtag(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    outputs: dict[str, BuildOutput],
    primary: SerialCapture | None,
    secondary: SerialCapture | None,
) -> OpenOcdSession:
    pair = jtag_m0_lp_pair(outputs)
    if pair is None:
        raise RuntimeError("internal error: expected M0+LP JTAG load image set")
    m0, lp = pair

    m0_args = argparse.Namespace(**vars(args))
    m0_args.jtag_core = "m0"
    # In M0+LP JTAG-load mode, --jtag-gpio-pins may describe the LP experiment
    # pins compiled into the LP helper (for example GPIO2-5). Keep the M0 debug
    # anchor on the known Ox64 J6 pins while loading both RAM images.
    m0_args.jtag_gpio_pins = DEFAULT_JTAG_GPIO_PINS
    m0_session = prepare_jtag_session_with_recovery(
        args=m0_args,
        defaults=defaults,
        work_dir=work_dir,
        test_name=test["name"],
    )
    try:
        m0_session.command(
            f"load_image {lp.bin} 0x{jtag_load_entry(lp):08X} bin",
            timeout_s=60,
        )
        m0_session.command(f"load_image {m0.elf}", timeout_s=60)
        if primary is not None:
            primary.reset_buffers()
        if secondary is not None:
            secondary.reset_buffers()
        initial_jtag_command_with_recovery(
            m0_session,
            f"resume 0x{jtag_load_entry(m0):08X}",
            args=m0_args,
            log_path=m0_session.log_path,
            timeout_s=10,
            reason="m0 resume for LP JTAG helper",
        )
        return m0_session
    except Exception:
        m0_session.close()
        raise


def load_m0_d0_firmware_over_jtag(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    outputs: dict[str, BuildOutput],
    primary: SerialCapture | None,
    secondary: SerialCapture | None,
) -> OpenOcdSession:
    pair = jtag_m0_d0_pair(outputs)
    triple = jtag_m0_d0_lp_set(outputs)
    lp: BuildOutput | None = None
    if triple is not None:
        m0, d0, lp = triple
    elif pair is not None:
        m0, d0 = pair
    else:
        raise RuntimeError(
            "internal error: expected M0+D0 or M0+D0+LP JTAG load image set"
        )

    m0_args = argparse.Namespace(**vars(args))
    m0_args.jtag_core = "m0"
    try:
        m0_session = prepare_jtag_session(
            args=m0_args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=test["name"],
        )
    except Exception as first_exc:
        recovery_log = work_dir / "logs" / f"{test['name']}.m0-recovery.openocd.log"
        append_log(
            recovery_log,
            "# M0 direct attach failed; pulsing target reset before retry: "
            f"{first_exc}\n",
        )
        if target_reset_recovery_allowed(args):
            pulse_target_reset_via_ftdi(
                args,
                recovery_log,
                reason="recover M0 JTAG mux for D0 JTAG load",
            )
        else:
            append_log(
                recovery_log,
                "# automatic target reset recovery skipped by no-reset/attach mode\n",
            )
        retry_exc: Exception | None = None
        try:
            m0_session = prepare_jtag_session(
                args=m0_args,
                defaults=defaults,
                work_dir=work_dir,
                test_name=test["name"],
                reset_target=False,
            )
        except Exception as exc:
            retry_exc = exc
            append_log(
                recovery_log,
                "# M0 attach after target reset failed; trying D0->M0 mux fallback: "
                f"{exc}\n",
            )

        if retry_exc is None:
            pass
        else:
            fallback_args = argparse.Namespace(**vars(args))
            fallback_args.jtag_core = "m0"
            fallback_args.jtag_mux_bootstrap_core = "d0"
            fallback_args.no_jtag_mux = False
            fallback_args.no_jtag_reset = True
            m0_args = fallback_args
            m0_session = prepare_jtag_session(
                args=m0_args,
                defaults=defaults,
                work_dir=work_dir,
                test_name=test["name"],
                reset_target=False,
            )
    try:
        if lp is not None:
            m0_session.command(
                f"load_image {lp.bin} 0x{jtag_load_entry(lp):08X} bin",
                timeout_s=60,
            )
        m0_session.command(f"load_image {m0.elf}", timeout_s=60)
        if primary is not None:
            primary.reset_buffers()
        if secondary is not None:
            secondary.reset_buffers()
        initial_jtag_command_with_recovery(
            m0_session,
            f"resume 0x{jtag_load_entry(m0):08X}",
            args=m0_args,
            log_path=m0_session.log_path,
            timeout_s=10,
            reason="m0 resume for D0 JTAG load",
        )
        marker = "JTAG mux switched to D0"
        if not wait_for_serial_marker(primary, marker, timeout_s=5):
            append_log(
                m0_session.log_path,
                f"\n# warning: did not see UART marker {marker!r} before D0 attach\n",
            )
    finally:
        m0_session.close()

    d0_args = argparse.Namespace(**vars(args))
    d0_args.jtag_core = "d0"
    d0_args.no_jtag_mux = True
    d0_args.no_jtag_reset = True
    d0_session = prepare_jtag_session(
        args=d0_args,
        defaults=defaults,
        work_dir=work_dir,
        test_name=test["name"],
        reset_target=False,
    )
    try:
        d0_session.command(f"load_image {d0.elf}", timeout_s=60)
        d0_session.command(
            f"mww 0x{JTAG_D0_STATUS_ADDR:08X} 0x{JTAG_D0_RUN_MAGIC:08X}",
            timeout_s=20,
        )
        initial_jtag_command_with_recovery(
            d0_session,
            f"resume 0x{jtag_load_entry(d0):08X}",
            args=d0_args,
            log_path=d0_session.log_path,
            timeout_s=10,
            reason="d0 resume after JTAG load",
        )
        return d0_session
    except Exception:
        d0_session.close()
        raise


def wait_for_manual_boot_reset(args: argparse.Namespace, test_name: str) -> None:
    message = (
        f"[{test_name}] Put the Ox64 in UART boot mode now: press and hold BOOT, "
        "reset or power-cycle the board, release BOOT after power-up, "
        "then press Enter to flash..."
    )
    if args.dry_run:
        print(f"DRY-RUN: {message}")
        return
    try:
        input(message)
    except EOFError as exc:
        raise RuntimeError("--manual-boot-reset requires interactive stdin") from exc


def wait_for_manual_target_reset(args: argparse.Namespace, test_name: str) -> None:
    message = (
        f"[{test_name}] Reset or power-cycle the Ox64 now, leave BOOT released, "
        "then press Enter to continue..."
    )
    if args.dry_run:
        print(f"DRY-RUN: {message}")
        return
    try:
        input(message)
    except EOFError as exc:
        raise RuntimeError("--manual-target-reset requires interactive stdin") from exc


def capture_jtag_snapshot(
    session: OpenOcdSession,
    commands: list[str],
    *,
    halt_first: bool,
    symbols: dict[str, int] | None = None,
) -> str:
    output = ""
    if halt_first:
        output += session.command("halt", timeout_s=5)
    for command in commands:
        if symbols is not None:
            missing = missing_jtag_snapshot_symbols(command, symbols)
            if missing:
                output += (
                    f"\n# skipped JTAG snapshot command {command!r}; "
                    f"missing symbols {missing!r}\n"
                )
                continue
        expanded = (
            expand_jtag_snapshot_command(command, symbols)
            if symbols is not None
            else command
        )
        output += session.command(expanded, timeout_s=5)
    return output


def m0_output_for_jtag_symbols(outputs: dict[str, BuildOutput]) -> BuildOutput:
    m0_outputs = [
        output for output in outputs.values()
        if output.core == "bl808m0"
    ]
    if not m0_outputs:
        raise RuntimeError("symbolic JTAG operation requires a bl808m0 build output")
    return m0_outputs[0]


def run_jtag_breakpoint_snapshots(
    session: OpenOcdSession,
    *,
    args: argparse.Namespace,
    test: dict[str, Any],
    defaults: dict[str, Any],
    outputs: dict[str, BuildOutput],
    log_path: Path,
    resume_command: str,
) -> None:
    m0_output = m0_output_for_jtag_symbols(outputs)
    snapshot = (
        list(args.jtag_breakpoint_snapshot_command)
        if args.jtag_breakpoint_snapshot_command
        else list(test.get("jtag_snapshot", defaults.get("jtag_snapshot", [])))
    )
    symbol_names = list(args.jtag_breakpoint_symbol)
    for name in args.jtag_watchpoint_symbol:
        if name not in symbol_names:
            symbol_names.append(name)
    for name in jtag_snapshot_symbol_names(snapshot):
        if name not in symbol_names:
            symbol_names.append(name)
    symbols = elf_symbol_addresses(m0_output.elf, symbol_names, required=False)
    timeout_ms = max(1, int(float(args.jtag_breakpoint_timeout) * 1000.0))
    skip_count = max(0, int(args.jtag_breakpoint_skip_count))
    next_resume_command = resume_command
    breakpoints: list[tuple[str, int]] = []
    for symbol in args.jtag_breakpoint_symbol:
        address = symbols.get(symbol)
        if address is None:
            breakpoints.append((symbol, -1))
        else:
            breakpoints.append((symbol, address))
    for raw_address in args.jtag_breakpoint_address:
        try:
            address = int(raw_address, 0)
        except ValueError as exc:
            raise RuntimeError(f"invalid JTAG breakpoint address {raw_address!r}") from exc
        breakpoints.append((raw_address, address))
    for raw_address in args.jtag_watchpoint_address:
        try:
            address = int(raw_address, 0)
        except ValueError as exc:
            raise RuntimeError(f"invalid JTAG watchpoint address {raw_address!r}") from exc
        breakpoints.append((f"watch:{raw_address}", address))
    for symbol in args.jtag_watchpoint_symbol:
        address = symbols.get(symbol)
        if address is None:
            breakpoints.append((f"watch:{symbol}", -1))
        else:
            breakpoints.append((f"watch:{symbol}", address))

    with log_path.open("a", encoding="utf-8") as log:
        for index, (name, address) in enumerate(breakpoints):
            if address < 0:
                log.write(f"\n# skipped JTAG breakpoint {name!r}; missing symbol\n")
                log.flush()
                continue
            is_watchpoint = name.startswith("watch:")
            kind = "watchpoint" if is_watchpoint else "breakpoint"
            log.write(f"\n# JTAG {kind} {name} at 0x{address:08X}\n")
            log.flush()
            if is_watchpoint:
                session.command(f"wp 0x{address:08X} 4 w", timeout_s=5)
            else:
                bp_size = 2 if (address & 0x3) != 0 else 4
                session.command(f"bp 0x{address:08X} {bp_size} hw", timeout_s=5)
            did_halt = False
            try:
                initial_jtag_command_with_recovery(
                    session,
                    next_resume_command,
                    args=args,
                    log_path=log_path,
                    timeout_s=10,
                    reason=f"{args.jtag_core} resume to JTAG {kind} {name}",
                )
                next_resume_command = "resume"
                for hit_index in range(skip_count + 1):
                    try:
                        hit = session.command(
                            f"wait_halt {timeout_ms}",
                            timeout_s=float(args.jtag_breakpoint_timeout) + 5.0,
                        )
                        hit_lower = hit.lower()
                        log.write(hit)
                        if "timed out" in hit_lower or "target not halted" in hit_lower:
                            log.write(f"\n# JTAG {kind} {name} did not halt\n")
                            return
                        did_halt = True
                        if hit_index < skip_count:
                            log.write(
                                f"\n# skipped JTAG {kind} {name} hit "
                                f"{hit_index + 1}/{skip_count}\n"
                            )
                            log.flush()
                            session.command("resume", timeout_s=5)
                            did_halt = False
                            continue
                        log.write(capture_jtag_snapshot(
                            session,
                            snapshot,
                            halt_first=False,
                            symbols=symbols,
                        ))
                    except Exception as exc:
                        log.write(f"\n# JTAG {kind} {name} did not halt: {exc}\n")
                        return
            finally:
                try:
                    if is_watchpoint:
                        session.command(f"rwp 0x{address:08X}", timeout_s=5)
                    else:
                        session.command(f"rbp 0x{address:08X}", timeout_s=5)
                finally:
                    if did_halt and index == len(breakpoints) - 1:
                        session.command("resume", timeout_s=5)
                log.flush()


def jtag_target_for_core(args: argparse.Namespace, defaults: dict[str, Any], core: str) -> Path:
    if args.target is not None and core == args.jtag_core:
        return resolve_repo_path(args.target)
    if core == "lp" and args.lp_jtag_mode == "raw-had":
        return REPO_ROOT.parent / "openocd-had" / "tcl" / "target" / "bl808_lp_had.cfg"
    target = JTAG_CORES.get(core, {}).get("target")
    if target is None:
        return resolve_repo_path(defaults["openocd_target"])
    return resolve_repo_path(target)


def jtag_interface_for_core(args: argparse.Namespace, defaults: dict[str, Any], core: str) -> Path:
    if args.interface is not None:
        return resolve_repo_path(args.interface)
    if core == "lp" and args.lp_jtag_mode == "raw-had":
        return REPO_ROOT.parent / "openocd-had" / "tcl" / "interface" / "ftdi" / "pine64-raw-had.cfg"
    interface = JTAG_CORES.get(core, {}).get("interface")
    if interface is None:
        interface = defaults["openocd_interface"]
    return resolve_repo_path(interface)


def jtag_openocd_for_core(args: argparse.Namespace, core: str) -> str:
    if core == "lp":
        lp_openocd = resolve_repo_path(args.lp_openocd)
        if lp_openocd.exists() and os.access(lp_openocd, os.X_OK):
            return str(lp_openocd)
    return args.openocd


def jtag_gpio_values(args: argparse.Namespace, core: str) -> tuple[str, str]:
    func_sel = int(JTAG_CORES[core]["func_sel"])
    if args.jtag_gpio_style == "sdk-af":
        base = (
            (1 << 30) |   # GPIO mode: set/clear mode, as in bflb_gpio_init()
            (1 << 22) |   # mask GPIO interrupt
            (func_sel << 8) |
            (1 << 4) |    # pull-up
            (1 << 2) |    # drive strength 1
            (1 << 1) |    # Schmitt trigger
            (1 << 0)      # input enable for alternate function
        )
    else:
        base = (func_sel << 8) | (1 << 22) | (1 << 1) | (1 << 0)
    # Match the boot ROM's working JTAG pad setup: TDO is driven by the
    # peripheral function, not by the GPIO OE bit.
    tdo = base
    return f"0x{base:08X}", f"0x{tdo:08X}"


def gpio_cfg_addr(pin: int) -> int:
    return GPIO_CFG_BASE + pin * 4


def jtag_gpio_pin_labels(args: argparse.Namespace) -> tuple[tuple[str, int], ...]:
    tms, tdo, tck, tdi = args.jtag_gpio_pins
    return (("TMS", tms), ("TDO", tdo), ("TCK", tck), ("TDI", tdi))


def lp_jtag_parm_cfg0_bit_updates(args: argparse.Namespace) -> tuple[tuple[str, int, str], ...]:
    """Return reversible LP JTAG route experiments in GLB_PARM_CFG0."""
    updates: list[tuple[str, int, str]] = []
    if args.lp_jtag_wl_chain != "unchanged":
        updates.append(("WL_JTG_CHAIN", 0x00000040, args.lp_jtag_wl_chain))
    if args.lp_jtag_e902_sel != "unchanged":
        updates.append(("E902_JTAG_SEL", 0x00000080, args.lp_jtag_e902_sel))
    if args.lp_jtag_p7_io2_5 != "unchanged":
        updates.append(("P7_JTAG_USE_IO_2_5", 0x00800000, args.lp_jtag_p7_io2_5))
    if args.lp_jtag_p4_adc_test != "unchanged":
        updates.append(("P4_ADC_TEST_WITH_JTAG", 0x00100000, args.lp_jtag_p4_adc_test))
    if args.lp_jtag_p5_dac_test != "unchanged":
        updates.append(("P5_DAC_TEST_WITH_JTAG", 0x00200000, args.lp_jtag_p5_dac_test))
    return tuple(updates)


def jtag_switch_stub_entry(core: str) -> int:
    if core == "d0":
        return 0x3EFF8000
    return 0x22030000


def jtag_switch_stub_source(
    target_core: str,
    runner_core: str,
    *,
    bringup_target: bool,
    args: argparse.Namespace,
) -> str:
    """Return the target-resident stub that switches the BL808 JTAG mux."""
    gpio_val, gpio_val_tdo = jtag_gpio_values(args, target_core)
    lines = [
        "    .section .text",
        "    .global _start",
        "_start:",
    ]

    if bringup_target and runner_core == "m0" and target_core in ("d0", "lp"):
        lines.extend([
            "    # Power on MM subsystem: PDS_CTL2 = 0",
            "    li   a0, 0x2000E010",
            "    sw   zero, 0(a0)",
            "    fence iorw, iorw",
        ])

    if bringup_target and runner_core == "m0" and target_core == "d0":
        lines.extend([
            "    # Hold D0 reset while programming its boot address",
            "    li   a0, 0x30007040",
            "    lw   a1, 0(a0)",
            "    ori  a1, a1, 0x100",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Write \"j self\" to DRAM for D0",
            "    li   a0, 0x3EF80000",
            "    li   a1, 0x0000006F",
            "    sw   a1, 0(a0)",
            "    # Set D0 boot address: MM_MISC_CPU0_BOOT = 0x3EF80000",
            "    li   a0, 0x30000000",
            "    li   a1, 0x3EF80000",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Enable only the D0 clock bit in MM_CLK_CTRL_CPU",
            "    li   a0, 0x30007000",
            "    lw   a1, 0(a0)",
            "    li   a2, 0x00001000",
            "    or   a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Release only the D0 reset bit in MM_SW_SYS_RESET",
            "    li   a0, 0x30007040",
            "    lw   a1, 0(a0)",
            "    li   a2, -257",
            "    and  a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
        ])
    elif bringup_target and runner_core == "m0" and target_core == "lp":
        if args.lp_jtag_prebring_d0:
            lines.extend([
                "    # Pre-bring D0 up before LP; some BL808 debug paths depend on MM-side state",
                "    li   a0, 0x30007040",
                "    lw   a1, 0(a0)",
                "    ori  a1, a1, 0x100",
                "    sw   a1, 0(a0)",
                "    fence iorw, iorw",
                "    li   a0, 0x3EF80000",
                "    li   a1, 0x0000006F",
                "    sw   a1, 0(a0)",
                "    li   a0, 0x30000000",
                "    li   a1, 0x3EF80000",
                "    sw   a1, 0(a0)",
                "    fence iorw, iorw",
                "    li   a0, 0x30007000",
                "    lw   a1, 0(a0)",
                "    li   a2, 0x00001000",
                "    or   a1, a1, a2",
                "    sw   a1, 0(a0)",
                "    fence iorw, iorw",
                "    li   a0, 0x30007040",
                "    lw   a1, 0(a0)",
                "    li   a2, -257",
                "    and  a1, a1, a2",
                "    sw   a1, 0(a0)",
                "    fence iorw, iorw",
                "    li   a2, 500000",
                "0:  addi a2, a2, -1",
                "    bnez a2, 0b",
                "",
            ])
        lines.extend([
            "    # Ungate MCU security/debug clocks used by the RISC-V debug module",
            "    li   a0, 0x20000580",
            "    lw   a1, 0(a0)",
            "    ori  a1, a1, 0x4",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    li   a0, 0x20000584",
            "    lw   a1, 0(a0)",
            "    ori  a1, a1, 0x18",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Hold LP reset while programming its boot address",
            "    li   a0, 0x20000548",
            "    lw   a1, 0(a0)",
            "    ori  a1, a1, 0x8",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Write \"j self\" to the LP WRAM window",
            "    li   a0, 0x22050000",
            "    li   a1, 0x0000006F",
            "    sw   a1, 0(a0)",
            "    # Set LP boot address: PDS_CPU_CORE_CFG13 = 0x22050000",
            "    li   a0, 0x2000E144",
            "    li   a1, 0x22050000",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Enable and reset LP E902 CORET/mtime clock: PDS_CPU_CORE_CFG8",
            "    li   a0, 0x2000E130",
            "    lw   a1, 0(a0)",
            "    li   a2, 0x80000000",
            "    not  a2, a2",
            "    and  a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    li   a2, 0x40000000",
            "    not  a2, a2",
            "    and  a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    li   a2, 0x40000000",
            "    or   a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    li   a2, 0x40000000",
            "    not  a2, a2",
            "    and  a1, a1, a2",
            "    li   a2, 0xFFFFFC00",
            "    and  a1, a1, a2",
            "    ori  a1, a1, 159",
            "    li   a2, 0x80000000",
            "    or   a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Enable LP clock: PDS_CPU_CORE_CFG0 |= bit 28",
            "    li   a0, 0x2000E110",
            "    lw   a1, 0(a0)",
            "    li   a2, 0x10000000",
            "    or   a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "    # Release only LP reset bit in GLB_SWRST_CFG2",
            "    li   a0, 0x20000548",
            "    lw   a1, 0(a0)",
            "    li   a2, -9",
            "    and  a1, a1, a2",
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
        ])

    lines.extend([
        "    # Delay for target core to start before moving the JTAG pads",
        "    li   a2, 5000000",
        "1:  addi a2, a2, -1",
        "    bnez a2, 1b",
        "",
    ])

    parm_updates = lp_jtag_parm_cfg0_bit_updates(args) if target_core == "lp" else ()
    if parm_updates:
        lines.extend([
            "    # LP JTAG route experiments in GLB_PARM_CFG0",
            "    li   a0, 0x20000510",
            "    lw   a1, 0(a0)",
        ])
        for name, mask, action in parm_updates:
            lines.extend([
                f"    # {action} {name} (mask 0x{mask:08X})",
                f"    li   a2, 0x{mask:08X}",
            ])
            if action == "set":
                lines.append("    or   a1, a1, a2")
            else:
                lines.extend([
                    "    not  a2, a2",
                    "    and  a1, a1, a2",
                ])
        lines.extend([
            "    sw   a1, 0(a0)",
            "    fence iorw, iorw",
            "",
        ])

    lines.append("    # Switch configured GPIOs to the requested core's JTAG function")
    for signal, pin in jtag_gpio_pin_labels(args):
        value = gpio_val_tdo if signal == "TDO" else gpio_val
        lines.extend([
            f"    # GPIO{pin} = JTAG {signal}",
            f"    li   a1, {value}",
            f"    li   a0, 0x{gpio_cfg_addr(pin):08X}",
            "    sw   a1, 0(a0)",
        ])
    lines.extend([
        "",
        "2:  j    2b",
        "",
    ])
    return "\n".join(lines)


def build_jtag_switch_stub(
    target_core: str,
    runner_core: str,
    *,
    bringup_target: bool,
    args: argparse.Namespace,
    work_dir: Path,
    log_path: Path,
) -> Path:
    gcc = find_tool(args.riscv_gcc, "riscv64-unknown-elf-gcc")
    if runner_core == "d0":
        objcopy = find_tool(args.objcopy_rv64, "riscv64-unknown-elf-objcopy")
        march = "rv64imafdc"
        mabi = "lp64d"
    else:
        objcopy = find_tool(args.objcopy_rv32, "riscv32-unknown-elf-objcopy",
                            "riscv64-unknown-elf-objcopy")
        march = "rv32imafc"
        mabi = "ilp32f"
    entry = jtag_switch_stub_entry(runner_core)
    switch_dir = work_dir / "jtag-switch"
    switch_dir.mkdir(parents=True, exist_ok=True)
    mode = "bringup" if bringup_target else "preserve"
    stem = f"{runner_core}-to-{target_core}-{mode}"
    asm_path = switch_dir / f"{stem}.S"
    elf_path = switch_dir / f"{stem}.elf"
    bin_path = switch_dir / f"{stem}.bin"
    asm_path.write_text(
        jtag_switch_stub_source(
            target_core,
            runner_core,
            bringup_target=bringup_target,
            args=args,
        ),
        encoding="utf-8",
    )

    cmd = [
        gcc,
        f"-march={march}",
        f"-mabi={mabi}",
        "-nostdlib",
        "-nostartfiles",
        f"-Ttext=0x{entry:08X}",
        "-o",
        str(elf_path),
        str(asm_path),
    ]
    append_log(log_path, f"\n# build {runner_core}->{target_core} JTAG mux switch stub\n")
    proc = run_logged(cmd, cwd=REPO_ROOT, log_path=log_path, env=harness_env())
    if proc.returncode != 0:
        raise RuntimeError(
            f"failed to build {runner_core}->{target_core} JTAG mux switch stub; see {log_path}"
        )
    objcopy_cmd = [objcopy, "-O", "binary", str(elf_path), str(bin_path)]
    proc = run_logged(objcopy_cmd, cwd=REPO_ROOT, log_path=log_path, env=harness_env())
    if proc.returncode != 0:
        raise RuntimeError(
            f"failed to objcopy {runner_core}->{target_core} JTAG mux switch stub; see {log_path}"
        )
    return bin_path


def program_jtag_mux_via_stub(
    session: OpenOcdSession,
    target_core: str,
    runner_core: str,
    *,
    bringup_target: bool,
    args: argparse.Namespace,
    work_dir: Path,
    log_path: Path,
) -> None:
    """Run the mux switch on the current JTAG core before the TAP disappears."""
    entry = jtag_switch_stub_entry(runner_core)
    image_path = build_jtag_switch_stub(
        target_core,
        runner_core,
        bringup_target=bringup_target,
        args=args,
        work_dir=work_dir,
        log_path=log_path,
    )
    mode = "bring-up" if bringup_target else "preserve-target"
    pin_map = ", ".join(f"{signal}=GPIO{pin}" for signal, pin in jtag_gpio_pin_labels(args))
    append_log(
        log_path,
        f"\n# run {runner_core}->{target_core} JTAG mux switch stub ({mode}; {pin_map})\n",
    )
    session.command(f"load_image {image_path} 0x{entry:08X} bin", timeout_s=30)
    session.command(f"resume 0x{entry:08X}", timeout_s=5)
    time.sleep(5)
    append_log(log_path, "\n# stop bootstrap OpenOCD after JTAG pads move away\n")
    session.stop_process()


def program_jtag_mux_registers(
    session: OpenOcdSession,
    core: str,
    *,
    bringup_target: bool,
    args: argparse.Namespace,
) -> None:
    """Program the configured BL808 GPIO pins to the requested core's JTAG function."""
    if core == "d0":
        if bringup_target:
            session.command("mww 0x2000E010 0x00000000", timeout_s=20)
            session.command("mww 0x3EF80000 0x0000006F", timeout_s=20)
            session.command("mww 0x30000000 0x3EF80000", timeout_s=20)
            session.command("mww 0x30007040 0x00000000", timeout_s=20)
            session.command("mww 0x30007000 0x00005005", timeout_s=20)
    elif core == "lp":
        if bringup_target:
            session.command("mww 0x2000E010 0x00000000", timeout_s=20)
            session.command("mww 0x22050000 0x0000006F", timeout_s=20)
            session.command("mww 0x2000E144 0x22050000", timeout_s=20)
            session.command("mww 0x20000548 0x00000000", timeout_s=20)
            session.command("mww 0x2000E110 0x10000000", timeout_s=20)

    parm_updates = lp_jtag_parm_cfg0_bit_updates(args) if core == "lp" else ()
    if parm_updates:
        current = session.command("mdw 0x20000510 1", timeout_s=20)
        match = re.search(r"0x20000510:\s+([0-9a-fA-F]+)", current)
        if match:
            value = int(match.group(1), 16)
            for _name, mask, action in parm_updates:
                if action == "set":
                    value |= mask
                else:
                    value &= ~mask
            session.command(f"mww 0x20000510 0x{value:08X}", timeout_s=20)

    gpio_val, gpio_val_tdo = jtag_gpio_values(args, core)
    for signal, pin in jtag_gpio_pin_labels(args):
        value = gpio_val_tdo if signal == "TDO" else gpio_val
        session.command(f"mww 0x{gpio_cfg_addr(pin):08X} {value}", timeout_s=20)


def make_openocd_session(
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    test_name: str,
    core: str,
    log_suffix: str,
) -> OpenOcdSession:
    interface = jtag_interface_for_core(args, defaults, core)
    target = jtag_target_for_core(args, defaults, core)
    openocd = jtag_openocd_for_core(args, core)
    env = sudo_env(args)
    if core == "lp":
        env = dict(env or os.environ.copy())
        env["BL808_XUANTIE_ASYNC_HALT"] = "1"
    return OpenOcdSession(
        openocd=openocd,
        interface=interface,
        target=target,
        host=args.telnet_host,
        port=args.telnet_port,
        log_path=work_dir / "logs" / f"{test_name}.{log_suffix}.openocd.log",
        attach=args.attach_openocd,
        dry_run=args.dry_run,
        openocd_sudo=args.openocd_sudo,
        env=env,
    )


def start_openocd_with_recovery(
    session: OpenOcdSession,
    *,
    args: argparse.Namespace,
    log_path: Path,
    reason: str,
    attempts: int = 2,
    reset_adapter: bool = True,
) -> None:
    if args.attach_openocd:
        session.start()
        return

    last_exc: Exception | None = None
    for attempt in range(max(1, attempts)):
        reset_reason = f"before {reason}" if attempt == 0 else f"retry {attempt + 1} after {reason} failure"
        if reset_adapter:
            reset_ftdi_adapter(args, log_path, reason=reset_reason)
        else:
            append_log(log_path, f"\n# FTDI reset skipped ({reset_reason}; preserving JTAG mux)\n")
        try:
            start_offset = session.log_path.stat().st_size if session.log_path.exists() else 0
            session.start()
            startup_text = session.log_path.read_text(
                encoding="utf-8",
                errors="replace",
            )[start_offset:]
            scan_error = openocd_startup_scan_error(startup_text)
            if scan_error is not None:
                raise RuntimeError(f"OpenOCD startup scan failed: {scan_error}")
            return
        except Exception as exc:
            last_exc = exc
            session.stop_process()
            append_log(log_path, f"\n# OpenOCD start attempt {attempt + 1} failed: {exc}\n")
            if not reset_adapter:
                break
    assert last_exc is not None
    raise last_exc


def initial_jtag_command_with_recovery(
    session: OpenOcdSession,
    command: str,
    *,
    args: argparse.Namespace,
    log_path: Path,
    timeout_s: float,
    reason: str,
    attempts: int = 2,
) -> str:
    def capture_m0_halt_failure_diagnostics(exc: Exception) -> None:
        if args.jtag_core != "m0" or args.dry_run:
            return
        append_log(
            log_path,
            "\n# M0 non-async halt diagnostics after command failure: "
            f"{exc}\n",
        )

        def diag(diag_command: str, timeout: float = 3) -> str:
            try:
                text = session.command(diag_command, timeout_s=timeout)
            except Exception as diag_exc:
                append_log(log_path, f"# diag {diag_command}: {diag_exc}\n")
                return ""
            cleaned = text.replace("\x00", "").strip()
            lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
            values = [
                line
                for line in lines
                if re.fullmatch(r"0x[0-9a-fA-F]+", line)
            ]
            summary = values[-1] if values else (lines[-1] if lines else "ok")
            append_log(log_path, f"# diag {diag_command}: {summary}\n")
            return cleaned

        diag("riscv dmi_read 0x11")  # DMSTATUS
        diag("riscv dmi_read 0x16")  # ABSTRACTCS
        sbcs_text = diag("riscv dmi_read 0x38")  # SBCS / system bus access
        sbcs_values = re.findall(r"(?m)^\s*0x([0-9a-fA-F]+)\s*$", sbcs_text)
        if sbcs_values:
            sbcs = int(sbcs_values[-1], 16)
            if sbcs == 0:
                append_log(
                    log_path,
                    "# diag SBA: DM_SBCS is zero; non-halting JTAG flash "
                    "cannot use RISC-V system-bus access\n",
                )
            else:
                sbasize = (sbcs >> 5) & 0x7F
                sbaccess32 = bool(sbcs & 0x4)
                append_log(
                    log_path,
                    "# diag SBA: "
                    f"DM_SBCS=0x{sbcs:08x}, sbasize={sbasize}, "
                    f"sbaccess32={int(sbaccess32)}\n",
                )
        diag("riscv dmi_read 0x70")  # XuanTie CUSTOMCS
        diag("riscv dmi_read 0x7f")  # XuanTie COMPID
        diag("riscv dmi_write 0x71 0x02000000")  # CUSTOMCMD type 2: PC sample
        time.sleep(0.05)
        diag("riscv dmi_read 0x04")  # DATA0 / sampled PC

    last_exc: Exception | None = None
    for attempt in range(max(1, attempts)):
        try:
            return session.command(command, timeout_s=timeout_s)
        except Exception as exc:
            last_exc = exc
            capture_m0_halt_failure_diagnostics(exc)
            if args.attach_openocd or attempt + 1 >= max(1, attempts):
                break
            append_log(
                log_path,
                f"\n# retry {attempt + 2} after {reason} command failed: {exc}\n",
            )
            session.stop_process()
            if args.jtag_core == "m0":
                pulse_target_reset_via_ftdi(
                    args,
                    log_path,
                    reason=f"retry {attempt + 2} after {reason} command failure",
                )
            else:
                reset_ftdi_adapter(
                    args,
                    log_path,
                    reason=f"retry {attempt + 2} after {reason} command failure",
                )
            session.start()
    assert last_exc is not None
    raise last_exc


def jtag_attach_attempts(args: argparse.Namespace, core: str) -> int:
    if core == "lp":
        return args.lp_attach_retries
    if core == "d0":
        return max(3, args.lp_attach_retries)
    return 2


def parse_misa_value(text: str) -> int | None:
    match = re.search(r"misa\s+\(/32\):\s+0x([0-9a-fA-F]+)", text)
    if not match:
        match = re.search(r"misa\s+\(/64\):\s+0x([0-9a-fA-F]+)", text)
    if not match:
        match = re.search(r"misa(?:=|\s+)\s*0x([0-9a-fA-F]+)", text)
    if not match:
        return None
    return int(match.group(1), 16)


def lp_rvdm_identity_ok(text: str) -> tuple[bool, str]:
    misa = parse_misa_value(text)
    if misa is None:
        return False, "LP RVDM attach did not report misa"
    has_e = bool(misa & (1 << (ord("E") - ord("A"))))
    has_i = bool(misa & (1 << (ord("I") - ord("A"))))
    if has_e and not has_i:
        return True, f"misa=0x{misa:08x}"
    return False, (
        f"misa=0x{misa:08x} is not LP/E902 RV32E "
        "(this looks like the M0/E907 path)"
    )


def verify_jtag_core_identity(session: OpenOcdSession, core: str, args: argparse.Namespace) -> None:
    if args.dry_run:
        append_log(session.log_path, f"\n# DRY-RUN {core.upper()} identity check skipped\n")
        return
    if core == "lp" and args.lp_jtag_mode == "raw-had":
        session.command("reg pc", timeout_s=5)
        return
    text = session.command("reg misa", timeout_s=5)
    if core == "lp":
        ok, detail = lp_rvdm_identity_ok(text)
    else:
        misa = parse_misa_value(text)
        if misa is None:
            ok = False
            detail = "attach did not report misa"
        elif core == "m0":
            mxl = (misa >> 30) & 0x3
            has_i = bool(misa & (1 << (ord("I") - ord("A"))))
            has_e = bool(misa & (1 << (ord("E") - ord("A"))))
            ok = mxl == 1 and has_i and not has_e
            detail = f"misa=0x{misa:08x}"
            if not ok:
                detail += " is not M0/E907 RV32I"
        elif core == "d0":
            mxl = (misa >> 62) & 0x3
            has_i = bool(misa & (1 << (ord("I") - ord("A"))))
            ok = mxl == 2 and has_i
            detail = f"misa=0x{misa:016x}"
            if not ok:
                detail += " is not D0/C906 RV64"
        else:
            ok = True
            detail = f"misa=0x{misa:x}"
    append_log(session.log_path, f"\n# {core.upper()} identity check: {detail}\n")
    if not ok:
        raise RuntimeError(f"{core.upper()} identity check failed: {detail}")


def prepare_jtag_session(
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    test_name: str,
    reset_target: bool | None = None,
) -> OpenOcdSession:
    core = args.jtag_core
    if reset_target is None:
        reset_target = not args.no_jtag_reset
    main_session = make_openocd_session(
        args=args,
        defaults=defaults,
        work_dir=work_dir,
        test_name=test_name,
        core=core,
        log_suffix=core,
    )

    try:
        if args.no_jtag_mux:
            start_openocd_with_recovery(
                main_session,
                args=args,
                log_path=main_session.log_path,
                reason=f"{core} OpenOCD start",
                attempts=jtag_attach_attempts(args, core),
            )
            if reset_target:
                initial_jtag_command_with_recovery(
                    main_session,
                    "reset halt",
                    args=args,
                    log_path=main_session.log_path,
                    timeout_s=10,
                    reason=f"{core} reset halt",
                    attempts=jtag_attach_attempts(args, core),
                )
            else:
                initial_jtag_command_with_recovery(
                    main_session,
                    "halt",
                    args=args,
                    log_path=main_session.log_path,
                    timeout_s=5,
                    reason=f"{core} halt",
                    attempts=jtag_attach_attempts(args, core),
                )
            verify_jtag_core_identity(main_session, core, args)
            return main_session

        bootstrap_core = args.jtag_mux_bootstrap_core
        if args.attach_openocd and core != bootstrap_core:
            raise RuntimeError(
                "--attach-openocd cannot switch to a different JTAG target config; "
                "drop --attach-openocd so the harness can restart OpenOCD after the mux switch"
            )

        if core != bootstrap_core:
            bootstrap = make_openocd_session(
                args=args,
                defaults=defaults,
                work_dir=work_dir,
                test_name=test_name,
                core=bootstrap_core,
                log_suffix=f"{bootstrap_core}-mux",
            )
            mux_completed = False
            try:
                try:
                    start_openocd_with_recovery(
                        bootstrap,
                        args=args,
                        log_path=bootstrap.log_path,
                        reason=f"{bootstrap_core} mux bootstrap",
                        attempts=jtag_attach_attempts(args, bootstrap_core),
                    )
                    bootstrap_command = "reset halt" if reset_target else "halt"
                    initial_jtag_command_with_recovery(
                        bootstrap,
                        bootstrap_command,
                        args=args,
                        log_path=bootstrap.log_path,
                        timeout_s=10 if reset_target else 5,
                        reason=f"{bootstrap_core} {bootstrap_command}",
                        attempts=jtag_attach_attempts(args, bootstrap_core),
                    )
                    if (
                        (bootstrap_core == "m0" and core in ("d0", "lp"))
                        or (bootstrap_core == "d0" and core == "m0")
                    ):
                        program_jtag_mux_via_stub(
                            bootstrap,
                            core,
                            bootstrap_core,
                            bringup_target=reset_target,
                            args=args,
                            work_dir=work_dir,
                            log_path=bootstrap.log_path,
                        )
                    else:
                        program_jtag_mux_registers(
                            bootstrap,
                            core,
                            bringup_target=reset_target,
                            args=args,
                        )
                    mux_completed = True
                    time.sleep(0.5)
                except Exception as exc:
                    if core != "lp" or reset_target:
                        raise
                    message = (
                        f"\n# preserve-mode {bootstrap_core}->LP mux bootstrap failed: {exc}\n"
                        "# trying direct LP attach in case the JTAG pads are already muxed to LP\n"
                    )
                    append_log(bootstrap.log_path, message)
                    append_log(main_session.log_path, message)
            finally:
                bootstrap.close()
            if mux_completed and core == "lp" and args.lp_jtag_cjtag_escape:
                run_lp_jtag_cjtag_escape(args, main_session.log_path)
            if mux_completed and core != "lp":
                reset_ftdi_adapter(args, main_session.log_path, reason=f"after mux to {core}")

        start_openocd_with_recovery(
            main_session,
            args=args,
            log_path=main_session.log_path,
            reason=f"{core} OpenOCD start",
            attempts=jtag_attach_attempts(args, core),
            reset_adapter=(core != "lp"),
        )
        if core == bootstrap_core:
            if reset_target:
                initial_jtag_command_with_recovery(
                    main_session,
                    "reset halt",
                    args=args,
                    log_path=main_session.log_path,
                    timeout_s=10,
                    reason=f"{core} reset halt",
                    attempts=jtag_attach_attempts(args, core),
                )
            else:
                initial_jtag_command_with_recovery(
                    main_session,
                    "halt",
                    args=args,
                    log_path=main_session.log_path,
                    timeout_s=5,
                    reason=f"{core} halt",
                    attempts=jtag_attach_attempts(args, core),
                )
            verify_jtag_core_identity(main_session, core, args)
            program_jtag_mux_registers(
                main_session,
                core,
                bringup_target=reset_target,
                args=args,
            )
        elif reset_target:
            initial_jtag_command_with_recovery(
                main_session,
                "halt",
                args=args,
                log_path=main_session.log_path,
                timeout_s=5,
                reason=f"{core} halt after mux",
                attempts=jtag_attach_attempts(args, core),
            )
        verify_jtag_core_identity(main_session, core, args)
        return main_session
    except Exception:
        main_session.close()
        raise


def prepare_jtag_session_with_recovery(
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
    test_name: str,
    reset_target: bool | None = None,
) -> OpenOcdSession:
    try:
        return prepare_jtag_session(
            args=args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=test_name,
            reset_target=reset_target,
        )
    except Exception as exc:
        if args.jtag_core != "m0":
            raise
        recovery_log = work_dir / "logs" / f"{test_name}.m0-recovery.openocd.log"
        append_log(
            recovery_log,
            "# M0 attach failed; pulsing target reset before retry: "
            f"{exc}\n",
        )
        if not target_reset_recovery_allowed(args):
            append_log(
                recovery_log,
                "# automatic target reset recovery skipped by no-reset/attach mode\n",
            )
            raise
        pulse_target_reset_via_ftdi(
            args,
            recovery_log,
            reason="recover M0 JTAG mux",
        )
        return prepare_jtag_session(
            args=args,
            defaults=defaults,
            work_dir=work_dir,
            test_name=test_name,
            reset_target=reset_target,
        )


def run_hardware_test(
    test: dict[str, Any],
    *,
    args: argparse.Namespace,
    defaults: dict[str, Any],
    work_dir: Path,
) -> TestResult:
    start = time.monotonic()
    required = list(test.get("required", []))
    required_secondary = list(test.get("required_secondary", []))
    forbidden = list(defaults.get("forbidden", [])) + list(test.get("forbidden", []))
    uart_baud = int(args.uart_baud or defaults.get("uart_baud", 230_400))
    flash_baud = int(args.flash_baud or uart_baud)
    serial_dtr = modem_control_state(args.serial_dtr)
    serial_rts = modem_control_state(args.serial_rts)
    timeout_s = float(test.get("timeout", 30))

    try:
        test_reset_capture = bool(test.get("jtag_flash_reset_capture", False))
        test_jtag_flash_runtime_jtag = test.get("jtag_flash_runtime_jtag")
        if args.jtag_flash_reset_capture and not args.jtag_flash:
            raise RuntimeError("--jtag-flash-reset-capture requires --jtag-flash")
        if args.jtag_flash_runtime_jtag and not args.jtag_flash:
            raise RuntimeError("--jtag-flash-runtime-jtag requires --jtag-flash")
        if args.uart_anchor_flash and (args.jtag_flash or args.jtag_load):
            raise RuntimeError(
                "--uart-anchor-flash is mutually exclusive with --jtag-flash and --jtag-load"
            )
        jtag_flash_reset_capture = bool(
            args.jtag_flash
            and (args.jtag_flash_reset_capture or test_reset_capture)
        )
        jtag_flash_runtime_jtag = bool(
            args.jtag_flash_runtime_jtag
            or (
                jtag_flash_reset_capture
                and test_jtag_flash_runtime_jtag is not False
            )
        )
        jtag_flash_reset_via_runtime_jtag = bool(
            jtag_flash_reset_capture
            and jtag_flash_runtime_jtag
            and not args.no_jtag_reset
        )
        jtag_flash_external_reset_capture = bool(
            jtag_flash_reset_capture
            and not jtag_flash_reset_via_runtime_jtag
        )
        runtime_jtag_disabled = bool(
            (args.uart_anchor_flash and not args.uart_anchor_runtime_jtag)
            or (jtag_flash_reset_capture and not jtag_flash_runtime_jtag)
        )
        outputs = build_firmware(test, args=args, work_dir=work_dir)
        if args.build_only:
            return TestResult(test["name"], True, time.monotonic() - start, "built")

        if args.uart is None and not args.dry_run:
            raise RuntimeError("--uart is required unless --build-only or --dry-run is used")
        if required_secondary and args.secondary_uart is None and not args.dry_run:
            raise RuntimeError("--secondary-uart is required for this test")

        flash_port = args.flash_port or args.uart
        if not args.no_flash:
            if args.uart_anchor_flash:
                if args.no_jtag and not args.uart_anchor_existing:
                    raise RuntimeError("--uart-anchor-flash requires JTAG; remove --no-jtag")
                if flash_port is None and not args.dry_run:
                    raise RuntimeError("--flash-port or --uart is required for UART anchor flashing")
                flash_firmware_over_uart_anchor(
                    test,
                    args=args,
                    defaults=defaults,
                    work_dir=work_dir,
                    outputs=outputs,
                    flash_port=flash_port or "<uart>",
                    flash_baud=flash_baud,
                    dtr=serial_dtr,
                    rts=serial_rts,
                )
            elif args.jtag_flash:
                if args.no_jtag:
                    raise RuntimeError("--jtag-flash requires JTAG; remove --no-jtag")
                flash_firmware_over_jtag(
                    test,
                    args=args,
                    defaults=defaults,
                    work_dir=work_dir,
                    outputs=outputs,
                )
            elif not args.jtag_load:
                if flash_port is None and not args.dry_run:
                    raise RuntimeError("--flash-port or --uart is required for flashing")
                if args.manual_boot_reset:
                    wait_for_manual_boot_reset(args, test["name"])
                flash_firmware(
                    test,
                    args=args,
                    work_dir=work_dir,
                    outputs=outputs,
                    flash_port=flash_port or "<uart>",
                    flash_baud=flash_baud,
                )

        session: OpenOcdSession | None = None
        primary: SerialCapture | None = None
        secondary: SerialCapture | None = None
        jtag_memory_log: JtagMemoryLogCapture | None = None
        pre_host_actions: list[RunningHostAction] = []
        pre_host_output = ""

        try:
            if (
                jtag_flash_reset_via_runtime_jtag
                and not args.no_jtag
                and not runtime_jtag_disabled
                and session is None
            ):
                session = prepare_jtag_session_with_recovery(
                    args=args,
                    defaults=defaults,
                    work_dir=work_dir,
                    test_name=test["name"],
                )

            if args.dry_run:
                print(f"DRY-RUN: open primary UART {args.uart or '<uart>'} at {uart_baud}")
                if args.secondary_uart:
                    print(f"DRY-RUN: open secondary UART {args.secondary_uart} at {uart_baud}")
            else:
                primary = SerialCapture(
                    args.uart or "",
                    uart_baud,
                    "primary",
                    work_dir / "logs" / f"{test['name']}.primary.uart.log",
                    dtr=serial_dtr,
                    rts=serial_rts,
                )
                if args.secondary_uart:
                    secondary = SerialCapture(
                        args.secondary_uart,
                        uart_baud,
                        "secondary",
                        work_dir / "logs" / f"{test['name']}.secondary.uart.log",
                        dtr=serial_dtr,
                        rts=serial_rts,
                    )
                if jtag_flash_reset_via_runtime_jtag:
                    time.sleep(SERIAL_CAPTURE_OPEN_SETTLE_S)

            for action_index, action in enumerate(test.get("pre_host_actions", [])):
                if args.dry_run:
                    print(
                        "DRY-RUN: start pre-capture host action "
                        f"{action_index}: {command_to_text(host_action_command(action))}"
                    )
                    continue
                running = start_host_action(
                    test["name"],
                    action_index,
                    action,
                    work_dir=work_dir,
                    log_label=f"prehost{action_index}",
                )
                pre_host_actions.append(running)
                action_ok, action_reason, action_output = wait_host_action_ready(
                    running,
                    inherited_forbidden=forbidden,
                )
                pre_host_output += action_output
                if not action_ok:
                    return TestResult(
                        test["name"],
                        False,
                        time.monotonic() - start,
                        f"pre host action {action_index}: {action_reason}",
                    )

            if args.manual_target_reset:
                wait_for_manual_target_reset(args, test["name"])

            anchor_reboot_requested = bool(
                args.uart_anchor_flash and args.uart_anchor_reset_after_flash
            )
            if (
                args.target_reset_before_capture
                or (
                    (runtime_jtag_disabled or jtag_flash_external_reset_capture)
                    and not args.manual_target_reset
                    and not anchor_reboot_requested
                )
            ):
                reset_log = work_dir / "logs" / f"{test['name']}.target-reset.log"
                if args.uart_anchor_flash:
                    reset_reason = "after UART anchor flash before UART capture"
                elif jtag_flash_reset_capture:
                    reset_reason = "after JTAG flash before UART/JTAG capture"
                else:
                    reset_reason = "before UART capture"
                if primary is not None:
                    primary.reset_buffers()
                if secondary is not None:
                    secondary.reset_buffers()
                pulse_target_reset_via_ftdi(
                    args,
                    reset_log,
                    reason=reset_reason,
                )

            if args.no_jtag or runtime_jtag_disabled:
                if args.dry_run:
                    print("DRY-RUN: skip OpenOCD/JTAG")
            else:
                if args.jtag_load and jtag_m0_lp_pair(outputs) is not None:
                    session = load_m0_lp_firmware_over_jtag(
                        test,
                        args=args,
                        defaults=defaults,
                        work_dir=work_dir,
                        outputs=outputs,
                        primary=primary,
                        secondary=secondary,
                    )
                elif args.jtag_load and (
                    jtag_m0_d0_pair(outputs) is not None
                    or jtag_m0_d0_lp_set(outputs) is not None
                ):
                    session = load_m0_d0_firmware_over_jtag(
                        test,
                        args=args,
                        defaults=defaults,
                        work_dir=work_dir,
                        outputs=outputs,
                        primary=primary,
                        secondary=secondary,
                    )
                else:
                    if session is None:
                        session = prepare_jtag_session_with_recovery(
                            args=args,
                            defaults=defaults,
                            work_dir=work_dir,
                            test_name=test["name"],
                        )
                    resume_command = "resume"
                    if args.jtag_load:
                        entry = load_firmware_over_jtag(
                            test,
                            session=session,
                            outputs=outputs,
                        )
                        if primary is not None:
                            primary.reset_buffers()
                        if secondary is not None:
                            secondary.reset_buffers()
                        resume_command = f"resume 0x{entry:08X}"
                    elif jtag_flash_reset_via_runtime_jtag:
                        if primary is not None:
                            primary.reset_buffers()
                        if secondary is not None:
                            secondary.reset_buffers()
                    if (args.jtag_breakpoint_symbol or args.jtag_breakpoint_address or
                            args.jtag_watchpoint_address or args.jtag_watchpoint_symbol):
                        run_jtag_breakpoint_snapshots(
                            session,
                            args=args,
                            test=test,
                            defaults=defaults,
                            outputs=outputs,
                            log_path=session.log_path,
                            resume_command=resume_command,
                        )
                    else:
                        initial_jtag_command_with_recovery(
                            session,
                            resume_command,
                            args=args,
                            log_path=session.log_path,
                            timeout_s=10,
                            reason=f"{args.jtag_core} resume",
                        )

            if args.no_jtag or runtime_jtag_disabled:
                log_name = (
                    f"{test['name']}.runtime-jtag.log"
                    if runtime_jtag_disabled
                    else f"{test['name']}.openocd.log"
                )
                if args.uart_anchor_flash:
                    if args.manual_target_reset:
                        log_msg = (
                            "Runtime JTAG skipped by UART anchor flash mode; "
                            "image was flashed through the M0 UART anchor, then run by manual target reset.\n"
                        )
                    elif args.uart_anchor_reset_after_flash:
                        log_msg = (
                            "Runtime JTAG skipped by UART anchor flash mode; "
                            "image was flashed through the M0 UART anchor, then rebooted by anchor command.\n"
                        )
                    else:
                        log_msg = (
                            "Runtime JTAG skipped by UART anchor flash mode; "
                            "image was flashed through the M0 UART anchor, then run via target nSRST.\n"
                        )
                elif runtime_jtag_disabled:
                    log_msg = (
                        "Runtime JTAG skipped by JTAG flash reset-capture mode; "
                        "image was flashed with JTAG, then run via target nSRST.\n"
                    )
                else:
                    log_msg = "JTAG skipped by --no-jtag; no reset or failure snapshot available.\n"
                skip_log = work_dir / "logs" / log_name
                ensure_parent(skip_log)
                skip_log.write_text(log_msg, encoding="utf-8")
            else:
                stale_skip_log = work_dir / "logs" / f"{test['name']}.runtime-jtag.log"
                if stale_skip_log.exists():
                    stale_skip_log.unlink()
                assert session is not None

            if args.dry_run:
                return TestResult(test["name"], True, time.monotonic() - start, "dry-run")

            assert primary is not None
            if args.jtag_memory_log:
                if session is None:
                    raise RuntimeError("--jtag-memory-log requires runtime JTAG")
                m0_outputs = [output for output in outputs.values() if output.core == "bl808m0"]
                if not m0_outputs:
                    raise RuntimeError("--jtag-memory-log requires a bl808m0 build output")
                jtag_memory_log = JtagMemoryLogCapture(
                    session,
                    m0_outputs[0],
                    work_dir / "logs" / f"{test['name']}.jtag-memory.log",
                )
            serials = [primary] + ([secondary] if secondary is not None else [])
            deadline = time.monotonic() + timeout_s
            input_text = test.get("input")
            input_after = test.get("input_after")
            input_sent = False
            host_output = pre_host_output
            pending_host_actions = list(enumerate(test.get("host_actions", [])))
            active_host_action: RunningHostAction | None = None
            reason = ""
            ok = False

            while time.monotonic() < deadline:
                for serial_port in serials:
                    serial_port.read_available()
                if jtag_memory_log is not None:
                    jtag_memory_log.read_available()
                pre_host_output = ""
                for running in pre_host_actions:
                    pre_host_output += read_running_host_action_output(running)

                combined = (
                    "".join(serial.output for serial in serials)
                    + (jtag_memory_log.output if jtag_memory_log is not None else "")
                    + pre_host_output
                    + host_output
                )
                secondary_output = secondary.output if secondary is not None else ""

                if input_text is not None and not input_sent:
                    if input_after is None or input_after in combined:
                        primary.write_text(input_text)
                        input_sent = True

                forbidden_marker = check_forbidden(combined, forbidden)
                if forbidden_marker is not None:
                    reason = f"forbidden marker {forbidden_marker!r}"
                    break

                if active_host_action is not None:
                    finished = finish_host_action(
                        active_host_action,
                        inherited_forbidden=forbidden,
                    )
                    if finished is not None:
                        action_index = active_host_action.index
                        action_ok, action_reason, action_output = finished
                        active_host_action = None
                        host_output += action_output
                        combined += action_output
                        if not action_ok:
                            for serial_port in serials:
                                serial_port.drain_available()
                            if jtag_memory_log is not None:
                                jtag_memory_log.read_available()
                            reason = f"host action {action_index}: {action_reason}"
                            pending_host_actions = []
                            break

                if active_host_action is None:
                    still_pending_actions: list[tuple[int, dict[str, Any]]] = []
                    started_action = False
                    for action_index, action in pending_host_actions:
                        after_marker = action.get("after_marker")
                        if started_action or (after_marker and after_marker not in combined):
                            still_pending_actions.append((action_index, action))
                            continue
                        active_host_action = start_host_action(
                            test["name"],
                            action_index,
                            action,
                            work_dir=work_dir,
                            marker_output=combined,
                        )
                        started_action = True
                    pending_host_actions = still_pending_actions

                if reason:
                    break

                if active_host_action is not None:
                    time.sleep(0.02)
                    continue

                missing = missing_required(combined, required)
                missing_secondary = missing_required(secondary_output, required_secondary)
                if not missing and not missing_secondary and not pending_host_actions:
                    ok = True
                    reason = "ok"
                    break

                time.sleep(0.02)

            if active_host_action is not None:
                stop_host_action(active_host_action)
                active_host_action = None

            if not ok and not reason:
                combined = (
                    "".join(serial.output for serial in serials)
                    + (jtag_memory_log.output if jtag_memory_log is not None else "")
                    + host_output
                )
                missing = missing_required(combined, required)
                missing_secondary = missing_required(
                    secondary.output if secondary is not None else "",
                    required_secondary,
                )
                pending = [
                    str(action_index) for action_index, _ in pending_host_actions
                ]
                reason = (
                    f"timeout after {timeout_s:.1f}s; "
                    f"missing {missing + missing_secondary!r}; "
                    f"pending host actions {pending!r}"
                )

            if ok:
                if session is not None and bool(test.get("jtag_poll_after_success", True)):
                    session.command("poll", timeout_s=3)
            else:
                if session is not None:
                    snapshot = list(test.get("jtag_snapshot", defaults.get("jtag_snapshot", [])))
                    snapshot_symbols: dict[str, int] | None = None
                    symbol_names = jtag_snapshot_symbol_names(snapshot)
                    if symbol_names:
                        m0_outputs = [
                            output for output in outputs.values()
                            if output.core == "bl808m0"
                        ]
                        if not m0_outputs:
                            raise RuntimeError(
                                "symbolic JTAG snapshot requires a bl808m0 build output"
                            )
                        snapshot_symbols = elf_symbol_addresses(
                            m0_outputs[0].elf,
                            symbol_names,
                            required=False,
                        )
                    capture_jtag_snapshot(
                        session,
                        snapshot,
                        halt_first=True,
                        symbols=snapshot_symbols,
                    )

            return TestResult(test["name"], ok, time.monotonic() - start, reason)
        finally:
            if primary is not None:
                primary.close()
            if secondary is not None:
                secondary.close()
            if jtag_memory_log is not None:
                jtag_memory_log.close()
            if session is not None:
                session.close()
            for running in pre_host_actions:
                stop_host_action(running)
    except Exception as exc:
        return TestResult(test["name"], False, time.monotonic() - start, str(exc))


def print_test_list(manifest: dict[str, Any]) -> None:
    print("Hardware validation tests:")
    for test in manifest["tests"]:
        tiers = ",".join(test.get("tiers", []))
        builds = ", ".join(
            f"{item['id']}:{item['core']}->{item.get('flash', 'no-flash')}"
            for item in test.get("build", [])
        )
        print(f"  {test['name']:<22} [{tiers:<10}] {builds}")

    ports = list_serial_ports()
    print("\nSerial ports:")
    if ports:
        for port in ports:
            print(f"  {port}")
    else:
        print("  none detected")


def print_preflight(name: str, status: str, detail: str) -> None:
    print(f"  {status:<4} {name:<24} {detail}", flush=True)


def try_open_uart(
    port: str,
    baud: int,
    *,
    dtr: bool | None,
    rts: bool | None,
) -> tuple[bool, str]:
    try:
        import serial  # type: ignore
    except ImportError as exc:
        return False, f"pyserial import failed: {exc}"

    try:
        ser = open_serial_device(
            serial,
            port=port,
            baud=baud,
            timeout=0,
            write_timeout=1,
            dtr=dtr,
            rts=rts,
        )
        ser.close()
    except Exception as exc:
        return False, str(exc)
    return True, "open ok"


def probe_uart_bootloader(
    port: str,
    baud: int,
    *,
    dtr: bool | None,
    rts: bool | None,
    retries: int = 3,
) -> tuple[bool, str]:
    try:
        import serial  # type: ignore
    except Exception as exc:
        return False, f"pyserial unavailable: {exc}"

    sync = bytes([0x55]) * max(1, int(0.006 * baud / 10))
    bootinfo = bytes.fromhex("5000080038F0002000000018")
    received = bytearray()
    try:
        ser = serial.Serial(
            port,
            baud,
            timeout=0.1,
            write_timeout=1,
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
        )
        if dtr is not None:
            ser.dtr = dtr
        if rts is not None:
            ser.rts = rts
        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:
            pass

        for attempt in range(max(1, retries)):
            ser.write(sync)
            ser.flush()
            time.sleep(0.3)
            ser.write(bootinfo)
            ser.flush()
            deadline = time.monotonic() + 0.8
            while time.monotonic() < deadline:
                chunk = ser.read(1000)
                if chunk:
                    received += chunk
                    if received.startswith(b"OK"):
                        return True, (
                            f"UART bootloader handshake ok on attempt {attempt + 1}; "
                            f"rx={received.hex()}"
                        )
                else:
                    time.sleep(0.02)
            if attempt + 1 < max(1, retries):
                time.sleep(0.2)
        return False, (
            "UART bootloader handshake failed; "
            f"rx={received.hex() or '<empty>'}"
        )
    except Exception as exc:
        return False, str(exc)
    finally:
        try:
            ser.close()  # type: ignore[name-defined]
        except Exception:
            pass


def run_uart_boot_probe(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    defaults = manifest.get("defaults", {})
    baud = int(args.flash_baud or args.uart_baud or defaults.get("uart_baud", 230_400))
    port = args.flash_port or args.uart
    if not port:
        print("UART boot probe requires --flash-port or --uart", flush=True)
        return 2
    dtr = modem_control_state(args.serial_dtr)
    rts = modem_control_state(args.serial_rts)
    print("UART bootloader probe", flush=True)
    print(f"port={port}", flush=True)
    print(f"baud={baud}", flush=True)
    ok, detail = probe_uart_bootloader(port, baud, dtr=dtr, rts=rts)
    status = "PASS" if ok else "FAIL"
    print(f"{status} {detail}", flush=True)
    if not ok:
        print(
            "Hold BOOT, reset or power-cycle the BL808, release BOOT, then retry.",
            flush=True,
        )
    return 0 if ok else 1


def macos_ftdi_visible(vid_text: str, pid_text: str) -> tuple[bool, str]:
    if sys.platform != "darwin":
        return False, "not macOS"
    try:
        vid = int(vid_text, 0)
        pid = int(pid_text, 0)
    except ValueError:
        return False, "invalid VID/PID"

    try:
        proc = subprocess.run(
            ["ioreg", "-p", "IOUSB", "-l", "-w0"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
    except Exception as exc:
        return False, f"ioreg failed: {exc}"
    if proc.returncode != 0:
        return False, "ioreg failed"

    text = proc.stdout
    vid_marker = f'"idVendor" = {vid}'
    pid_marker = f'"idProduct" = {pid}'
    if vid_marker in text and pid_marker in text:
        entitlement = "NeedsDeviceAccessEntitlement" in text
        detail = f"visible as {vid_text}:{pid_text}"
        if entitlement:
            detail += "; macOS reports NeedsDeviceAccessEntitlement"
        return True, detail
    return False, f"{vid_text}:{pid_text} not visible in IOUSB"


def run_preflight(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    defaults = manifest.get("defaults", {})
    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)
    configure_sudo_askpass(args, work_dir)
    log_path = work_dir / "logs" / "preflight.log"
    log_path.write_text("", encoding="utf-8")
    failures = 0

    print("hardware validation preflight", flush=True)
    print(f"work_dir={work_dir}", flush=True)

    def check(name: str, ok: bool, detail: str, *, warn: bool = False) -> None:
        nonlocal failures
        status = "PASS" if ok else ("WARN" if warn else "FAIL")
        print_preflight(name, status, detail)
        append_log(log_path, f"{status} {name}: {detail}\n")
        if not ok and not warn:
            failures += 1

    try:
        import serial  # type: ignore
        check("pyserial", True, f"version {getattr(serial, 'VERSION', 'unknown')}")
    except Exception as exc:
        check("pyserial", False, str(exc))

    for name, tool in (
        ("nim", args.nim),
        ("openocd", args.openocd),
        ("bflb-iot-tool", "bflb-iot-tool"),
        ("host compiler", args.cc_host),
        ("pkg-config", args.pkg_config),
    ):
        found = harness_which(tool) if name == "bflb-iot-tool" else shutil.which(tool)
        check(name, found is not None, found or f"{tool!r} not found")

    if args.jtag_core == "lp":
        lp_openocd = Path(jtag_openocd_for_core(args, "lp"))
        if lp_openocd == Path(args.openocd):
            found = shutil.which(args.openocd)
            check("LP OpenOCD", found is not None, found or f"{args.openocd!r} not found")
        else:
            check("LP OpenOCD", True, str(lp_openocd))

    try:
        rv32 = find_tool(args.objcopy_rv32, "riscv32-unknown-elf-objcopy",
                         "riscv64-unknown-elf-objcopy")
        check("rv32 objcopy", True, rv32)
    except RuntimeError as exc:
        check("rv32 objcopy", False, str(exc))

    try:
        rv64 = find_tool(args.objcopy_rv64, "riscv64-unknown-elf-objcopy")
        check("rv64 objcopy", True, rv64)
    except RuntimeError as exc:
        check("rv64 objcopy", False, str(exc))

    needs_jtag_switch_stub = (
        not args.no_jtag
        and not args.no_jtag_mux
        and (
            (args.jtag_mux_bootstrap_core == "m0" and args.jtag_core in ("d0", "lp"))
            or (args.jtag_mux_bootstrap_core == "d0" and args.jtag_core == "m0")
        )
    )
    if needs_jtag_switch_stub:
        try:
            riscv_gcc = find_tool(args.riscv_gcc, "riscv64-unknown-elf-gcc")
            check("riscv gcc", True, riscv_gcc)
        except RuntimeError as exc:
            check("riscv gcc", False, str(exc))

    upload_script = resolve_repo_path(args.upload_script)
    check("upload script", upload_script.exists(), str(upload_script))

    ports = list_serial_ports()
    check("serial ports", bool(ports), ", ".join(ports) if ports else "none detected")
    uart_baud = int(args.uart_baud or defaults.get("uart_baud", 230_400))
    serial_dtr = modem_control_state(args.serial_dtr)
    serial_rts = modem_control_state(args.serial_rts)
    if args.uart:
        in_list = args.uart in ports
        check("primary UART listed", in_list, args.uart, warn=not in_list)
        ok, detail = try_open_uart(args.uart, uart_baud, dtr=serial_dtr, rts=serial_rts)
        check("primary UART open", ok, detail)
    else:
        check("primary UART", False, "--uart not supplied", warn=True)

    if args.secondary_uart:
        in_list = args.secondary_uart in ports
        check("secondary UART listed", in_list, args.secondary_uart, warn=not in_list)
        ok, detail = try_open_uart(args.secondary_uart, uart_baud, dtr=serial_dtr, rts=serial_rts)
        check("secondary UART open", ok, detail)

    visible, visible_detail = macos_ftdi_visible(args.ftdi_reset_vid, args.ftdi_reset_pid)
    check("FTDI visible", visible, visible_detail, warn=(sys.platform != "darwin"))

    helper = build_ftdi_reset_helper(args, log_path)
    check(
        "FTDI reset helper",
        helper is not None,
        str(helper) if helper else "unavailable",
        warn=not args.ftdi_reset_required,
    )
    srst_helper = build_ftdi_srst_pulse_helper(args, log_path)
    check(
        "FTDI target nSRST helper",
        srst_helper is not None,
        str(srst_helper) if srst_helper else "unavailable",
        warn=not args.ftdi_reset_required,
    )
    if args.lp_jtag_cjtag_escape:
        tms_helper = build_ftdi_tms_escape_helper(args, log_path)
        check(
            "FTDI TMS escape helper",
            tms_helper is not None,
            str(tms_helper) if tms_helper else "unavailable",
        )

    ok, detail = probe_ftdi_reset(args, log_path, reason="preflight")
    check("FTDI reset/open", ok, detail, warn=not args.ftdi_reset_required)

    session: OpenOcdSession | None = None
    try:
        prepare = prepare_jtag_session_with_recovery if args.jtag_core == "m0" else prepare_jtag_session
        session = prepare(
            args=args,
            defaults=defaults,
            work_dir=work_dir,
            test_name="preflight",
            reset_target=args.preflight_reset_target,
        )
        initial_jtag_command_with_recovery(
            session,
            "halt",
            args=args,
            log_path=session.log_path,
            timeout_s=10,
            reason=f"{args.jtag_core} preflight halt",
        )
        initial_jtag_command_with_recovery(
            session,
            "poll",
            args=args,
            log_path=session.log_path,
            timeout_s=5,
            reason=f"{args.jtag_core} preflight poll",
        )
        initial_jtag_command_with_recovery(
            session,
            "resume",
            args=args,
            log_path=session.log_path,
            timeout_s=10,
            reason=f"{args.jtag_core} preflight resume",
        )
        check("OpenOCD attach", True, "connected")
    except Exception as exc:
        check("OpenOCD attach", False, str(exc))
    finally:
        if session is not None:
            session.close()

    print("\nPreflight Summary", flush=True)
    if failures:
        print(f"  FAIL {failures} blocking check(s); see {log_path}", flush=True)
        return 1
    print(f"  PASS all blocking checks; see {log_path}", flush=True)
    return 0


def hardware_lock_required(args: argparse.Namespace) -> bool:
    return not (
        args.list
        or args.build_only
        or args.uart_anchor_build_only
        or args.dry_run
    )


def main_locked(args: argparse.Namespace, manifest: dict[str, Any]) -> int:
    if args.manual_target_reset:
        args.no_jtag_reset = True

    if args.probe_uart_boot:
        return run_uart_boot_probe(args, manifest)

    if args.uart_anchor_probe:
        return run_uart_anchor_probe(args, manifest)

    if args.uart_anchor_build_only:
        return run_uart_anchor_build_only(args, manifest)

    if args.preflight:
        return run_preflight(args, manifest)

    if args.uart_anchor_flash_image is not None:
        return run_uart_anchor_prebuilt(args, manifest)

    work_dir = args.work_dir
    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "logs").mkdir(parents=True, exist_ok=True)
    configure_sudo_askpass(args, work_dir)
    defaults = manifest.get("defaults", {})
    tests = select_tests(manifest, args.tier, args.test)
    results: list[TestResult] = []

    print(f"hardware validation tier={args.tier} tests={len(tests)}", flush=True)
    print(f"work_dir={work_dir}", flush=True)
    if args.uart:
        print(f"uart={args.uart}", flush=True)
    if args.secondary_uart:
        print(f"secondary_uart={args.secondary_uart}", flush=True)

    for test in tests:
        print(f"\n== {test['name']} ==", flush=True)
        result = run_hardware_test(test, args=args, defaults=defaults, work_dir=work_dir)
        results.append(result)
        status = "PASS" if result.ok else "FAIL"
        print(f"{status} {result.name} ({result.elapsed:.1f}s): {result.reason}", flush=True)
        if not result.ok and not args.keep_going:
            break

    print("\nSummary", flush=True)
    width = max([len(result.name) for result in results] + [4])
    for result in results:
        status = "PASS" if result.ok else "FAIL"
        print(f"  {status:<4} {result.name:<{width}} {result.elapsed:6.1f}s  {result.reason}")

    failed = [result for result in results if not result.ok]
    return 1 if failed else 0


def main() -> int:
    args = parse_args()
    manifest = load_manifest(args.manifest)

    if args.list:
        print_test_list(manifest)
        return 0

    if not hardware_lock_required(args):
        return main_locked(args, manifest)

    lock_path = args.work_dir / "hardware.lock"
    try:
        with HardwareRunLock(lock_path):
            return main_locked(args, manifest)
    except RuntimeError as exc:
        print(f"FAIL {exc}", flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
