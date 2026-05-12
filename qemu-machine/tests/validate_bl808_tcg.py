#!/usr/bin/env python3
"""
BL808 TCG integration checks.

This validates the execution path that qtest cannot observe directly:
  - M0 firmware releases the MM domain and D0 clock
  - D0 fetches instructions from its private XIP view at 0x58000000
  - SF_CTRL group-1 image offset retargeting changes which D0 flash image runs
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


FLASH_OFFSET_D0 = 0x100000
FLASH_OFFSET_D0_IMAGE = FLASH_OFFSET_D0 + 0x1000
FLASH_XIP_BASE = 0x58000000
OCRAM_BASE = 0x22020000
XRAM_BASE = 0x40000000
PDS_CTL2 = 0x2000E000 + 0x10
MM_GLB_MM_CLK_CTRL_CPU = 0x30007000
MM_GLB_MM_SW_SYS_RESET = 0x30007000 + 0x40
MM_GLB_CLK_CTRL_MMCPU0_EN = 1 << 12
SF_CTRL_ID1_OFFSET = 0x2000B000 + 0x0A4

M0_ENTRY = OCRAM_BASE + 0x100
D0_LOOP_PC = FLASH_XIP_BASE + 0x10
D0_SEXT_LOOP_PC = FLASH_XIP_BASE + 0x1C


def check_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def mmio_words_to_bytes(words: list[int]) -> bytes:
    return b"".join(word.to_bytes(4, "little") for word in words)


def synthetic_riscv32_elf(entry: int, code: bytes) -> bytes:
    phoff = 52
    phentsize = 32
    segment_offset = 0x1000
    ident = bytes([0x7F, ord("E"), ord("L"), ord("F"),
                   1, 1, 1, 0, 0]) + bytes(7)
    ehdr = struct.pack(
        "<16sHHIIIIIHHHHHH",
        ident,
        2,
        243,
        1,
        entry,
        phoff,
        0,
        0,
        52,
        phentsize,
        1,
        0,
        0,
        0,
    )
    phdr = struct.pack(
        "<IIIIIIII",
        1,
        segment_offset,
        entry,
        entry,
        len(code),
        len(code),
        0x7,
        0x1000,
    )
    padding = bytes(segment_offset - len(ehdr) - len(phdr))
    return ehdr + phdr + padding + code


def rv_lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def rv_addi(rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def rv_sw(rs2: int, rs1: int, imm: int) -> int:
    imm &= 0xFFF
    return (
        (((imm >> 5) & 0x7F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (2 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def rv_lw(rd: int, rs1: int, imm: int) -> int:
    imm &= 0xFFF
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03


def rv_jal_zero() -> int:
    return 0x0000006F


def rv_li32(rd: int, value: int) -> list[int]:
    hi = (value + 0x800) >> 12
    lo = value - (hi << 12)
    return [rv_lui(rd, hi), rv_addi(rd, rd, lo)]


def build_d0_flash_program(marker: int) -> bytes:
    words = [
        0x400002B7,                # lui  t0, 0x40000        ; XRAM_BASE
        rv_lui(6, marker >> 12),   # lui  t1, marker[31:12]
        rv_addi(6, 6, marker & 0xFFF),
        rv_sw(6, 5, 0),            # sw   t1, 0(t0)
        rv_jal_zero(),             # j    .
    ]
    return mmio_words_to_bytes(words)


def build_d0_signext_mmio_program() -> bytes:
    words = [
        rv_lui(5, 0xF0000),    # lui t0, 0xF0000        ; -> 0xFFFFFFFFF0000000 on RV64
        rv_lw(6, 5, 0),        # lw  t1, 0(t0)          ; BL808 core-id helper
        rv_lui(7, 0xE0201),    # lui t2, 0xE0201        ; -> 0xFFFFFFFFE0201000
        rv_lw(28, 7, 4),       # lw  t3, 4(t2)          ; D0 PLIC claim/complete alias
        0x40000EB7,            # lui t4, 0x40000        ; XRAM_BASE
        rv_sw(6, 29, 0),       # sw  t1, 0(t4)
        rv_sw(28, 29, 4),      # sw  t3, 4(t4)
        rv_jal_zero(),         # j   .
    ]
    return mmio_words_to_bytes(words)


def build_m0_release_elf(d0_offset: int | None, marker: int) -> bytes:
    words: list[int] = []

    if d0_offset is not None:
        words += rv_li32(5, SF_CTRL_ID1_OFFSET)
        words += rv_li32(6, d0_offset)
        words += [rv_sw(6, 5, 0)]

    words += rv_li32(5, PDS_CTL2)
    words += [rv_sw(0, 5, 0)]

    words += rv_li32(5, MM_GLB_MM_SW_SYS_RESET)
    words += [rv_sw(0, 5, 0)]

    words += rv_li32(5, MM_GLB_MM_CLK_CTRL_CPU)
    words += rv_li32(6, 0x00004005 | MM_GLB_CLK_CTRL_MMCPU0_EN)
    words += [rv_sw(6, 5, 0)]

    words += rv_li32(5, XRAM_BASE + 8)
    words += rv_li32(6, marker)
    words += [rv_sw(6, 5, 0), rv_jal_zero()]

    return synthetic_riscv32_elf(M0_ENTRY, mmio_words_to_bytes(words))


class TCGSession:
    def __init__(self, qemu_binary: Path, flash_path: Path, kernel_path: Path) -> None:
        self._qmp_dir = tempfile.TemporaryDirectory(prefix="bl808-tcg-")
        self._qmp_path = Path(self._qmp_dir.name) / "qmp.sock"
        self.proc = subprocess.Popen(
            [
                str(qemu_binary),
                "-M",
                f"bl808,flash-image={flash_path}",
                "-kernel",
                str(kernel_path),
                "-display",
                "none",
                "-serial",
                "none",
                "-monitor",
                "none",
                "-qmp",
                f"unix:{self._qmp_path},server=on,wait=off",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._qmp_socket = self._connect_qmp()
        self._qmp_reader = self._qmp_socket.makefile("r", encoding="utf-8")
        self._qmp_writer = self._qmp_socket.makefile("w", encoding="utf-8")
        self._qmp_read_message()
        self.qmp_command("qmp_capabilities")

    def close(self) -> None:
        self._qmp_reader.close()
        self._qmp_writer.close()
        self._qmp_socket.close()
        self._qmp_dir.cleanup()
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def _connect_qmp(self) -> socket.socket:
        deadline = time.monotonic() + 5.0
        while True:
            try:
                qmp_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                qmp_socket.connect(str(self._qmp_path))
                return qmp_socket
            except FileNotFoundError:
                pass
            except ConnectionRefusedError:
                pass

            qmp_socket.close()
            if self.proc.poll() is not None:
                raise RuntimeError("QEMU exited before QMP became available")
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out waiting for QMP socket")
            time.sleep(0.05)

    def _qmp_read_message(self) -> dict[str, Any]:
        line = self._qmp_reader.readline()
        if not line:
            raise RuntimeError("Unexpected EOF from QMP")
        return json.loads(line)

    def qmp_command(
        self, execute: str, arguments: dict[str, Any] | None = None
    ) -> Any:
        payload: dict[str, Any] = {"execute": execute}
        if arguments is not None:
            payload["arguments"] = arguments

        self._qmp_writer.write(json.dumps(payload) + "\n")
        self._qmp_writer.flush()

        while True:
            resp = self._qmp_read_message()
            if "return" in resp:
                return resp["return"]
            if "error" in resp:
                raise RuntimeError(f"QMP {execute!r} failed: {resp['error']!r}")

    def hmp_command(self, command: str) -> str:
        return self.qmp_command(
            "human-monitor-command", {"command-line": command}
        )

    def read_phys_words(self, addr: int, count: int) -> list[int]:
        dump = self.hmp_command(f"xp /{count}wx 0x{addr:x}")
        values = [int(match, 16) for match in re.findall(r"0x([0-9a-fA-F]+)", dump)]
        if len(values) != count:
            raise AssertionError(
                f"Expected {count} words from physical dump, got {len(values)}: {dump!r}"
            )
        return values

    def read_cpu_pcs(self) -> dict[int, int]:
        cpu_pcs: dict[int, int] = {}
        current_cpu: int | None = None

        for raw_line in self.hmp_command("info registers -a").splitlines():
            line = raw_line.strip()
            if line.startswith("CPU#"):
                current_cpu = int(line[4:])
                continue
            if current_cpu is None or not line.startswith("pc"):
                continue
            cpu_pcs[current_cpu] = int(line.split()[1], 16)
        return cpu_pcs

    def wait_for_markers(
        self,
        *,
        expected_d0_marker: int,
        expected_m0_marker: int,
        expected_sf_offset: int,
        timeout_s: float = 2.0,
    ) -> None:
        deadline = time.monotonic() + timeout_s
        last_words: list[int] = []
        last_offset = None
        last_d0_pc = None

        while time.monotonic() < deadline:
            time.sleep(0.05)
            self.qmp_command("stop")
            try:
                last_words = self.read_phys_words(XRAM_BASE, 4)
                last_offset = self.read_phys_words(SF_CTRL_ID1_OFFSET, 1)[0]
                last_d0_pc = self.read_cpu_pcs().get(1)
                if (
                    last_words[0] == expected_d0_marker
                    and last_words[2] == expected_m0_marker
                    and last_offset == expected_sf_offset
                    and last_d0_pc == D0_LOOP_PC
                ):
                    return
            finally:
                if time.monotonic() < deadline:
                    self.qmp_command("cont")

        raise AssertionError(
            "Timed out waiting for BL808 TCG markers: "
            f"xram={last_words!r} sf_offset={last_offset!r} d0_pc={last_d0_pc!r}"
        )

    def wait_for_d0_signext_mmio(
        self,
        *,
        expected_core_id: int,
        expected_plic_claim: int,
        expected_m0_marker: int,
        timeout_s: float = 2.0,
    ) -> None:
        deadline = time.monotonic() + timeout_s
        last_words: list[int] = []
        last_d0_pc = None

        while time.monotonic() < deadline:
            time.sleep(0.05)
            self.qmp_command("stop")
            try:
                last_words = self.read_phys_words(XRAM_BASE, 4)
                last_d0_pc = self.read_cpu_pcs().get(1)
                if (
                    last_words[0] == expected_core_id
                    and last_words[1] == expected_plic_claim
                    and last_words[2] == expected_m0_marker
                    and last_d0_pc == D0_SEXT_LOOP_PC
                ):
                    return
            finally:
                if time.monotonic() < deadline:
                    self.qmp_command("cont")

        raise AssertionError(
            "Timed out waiting for BL808 D0 sign-extended MMIO markers: "
            f"xram={last_words!r} d0_pc={last_d0_pc!r}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--qemu",
        default="/Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64",
        help="Path to qemu-system-riscv64 with the BL808 machine installed",
    )
    args = parser.parse_args()

    qemu_binary = Path(args.qemu)
    if not qemu_binary.is_file():
        print(f"QEMU binary not found: {qemu_binary}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="bl808-tcg-test-") as temp_dir:
        temp_path = Path(temp_dir)
        flash_path = temp_path / "flash.bin"
        flash_sext_path = temp_path / "flash-sext.bin"
        default_m0_path = temp_path / "m0-default.elf"
        retarget_m0_path = temp_path / "m0-retarget.elf"
        sext_m0_path = temp_path / "m0-sext.elf"

        flash_image = bytearray(b"\xFF" * (FLASH_OFFSET_D0_IMAGE + 0x100))
        flash_image[FLASH_OFFSET_D0:FLASH_OFFSET_D0 + 20] = build_d0_flash_program(0x22222222)
        flash_image[FLASH_OFFSET_D0_IMAGE:FLASH_OFFSET_D0_IMAGE + 20] = build_d0_flash_program(0x11111111)
        flash_path.write_bytes(flash_image)
        flash_image[FLASH_OFFSET_D0_IMAGE:FLASH_OFFSET_D0_IMAGE + 32] = build_d0_signext_mmio_program()
        flash_sext_path.write_bytes(flash_image)

        default_m0_path.write_bytes(build_m0_release_elf(None, 0xCAFE0001))
        retarget_m0_path.write_bytes(
            build_m0_release_elf(FLASH_OFFSET_D0, 0xCAFE0002)
        )
        sext_m0_path.write_bytes(build_m0_release_elf(None, 0xCAFE0003))

        default_session = TCGSession(qemu_binary, flash_path, default_m0_path)
        try:
            default_session.wait_for_markers(
                expected_d0_marker=0x11111111,
                expected_m0_marker=0xCAFE0001,
                expected_sf_offset=FLASH_OFFSET_D0_IMAGE,
            )
        finally:
            default_session.close()

        retarget_session = TCGSession(qemu_binary, flash_path, retarget_m0_path)
        try:
            retarget_session.wait_for_markers(
                expected_d0_marker=0x22222222,
                expected_m0_marker=0xCAFE0002,
                expected_sf_offset=FLASH_OFFSET_D0,
            )
        finally:
            retarget_session.close()

        sext_session = TCGSession(qemu_binary, flash_sext_path, sext_m0_path)
        try:
            sext_session.wait_for_d0_signext_mmio(
                expected_core_id=0xDEAD5500,
                expected_plic_claim=0x00000000,
                expected_m0_marker=0xCAFE0003,
            )
        finally:
            sext_session.close()

    print("BL808 TCG D0 XIP validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
