#!/usr/bin/env python3
"""Build a cooperative Nim M0 application for the resident USB UART anchor.

This tool only builds an image. Installation uses hw_validate.py and its
hardware lock, so a build cannot accidentally overwrite the resident anchor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
APP_FLASH_OFFSET = 0x40000
APP_RAM_BASE = 0x22030000
APP_RAM_CAPACITY = 112 * 1024
APP_HEADER_SIZE = 32
APP_MAGIC = 0x31414D55  # "UMA1"
APP_VERSION = 1


def checksum(data: bytes) -> int:
    value = 0
    for byte in data:
        value = ((value << 5) ^ (value >> 27) ^ byte) & 0xFFFFFFFF
    return value


def symbols(nm_output: str) -> dict[str, int]:
    result = {}
    for line in nm_output.splitlines():
        words = line.split()
        if len(words) == 3 and words[1] in {"T", "D", "B", "A"}:
            result[words[2]] = int(words[0], 16)
    return result


def package_app(payload: bytes, elf_symbols: dict[str, int]) -> bytes:
    required = ("anchor_app_init", "anchor_app_poll", "_ebss")
    missing = [name for name in required if name not in elf_symbols]
    if missing:
        raise ValueError(f"application missing symbols: {', '.join(missing)}")
    if not payload or len(payload) > APP_RAM_CAPACITY:
        raise ValueError("application code/data exceeds the 112 KiB WRAM slot")
    memory_len = elf_symbols["_ebss"] - APP_RAM_BASE
    if not len(payload) <= memory_len <= APP_RAM_CAPACITY:
        raise ValueError("application BSS extends outside its WRAM slot")
    offsets = [elf_symbols[name] - APP_RAM_BASE for name in required[:2]]
    if any(offset < 0 or offset >= len(payload) or offset & 1 for offset in offsets):
        raise ValueError("application entry point is outside its code image")
    header = struct.pack(
        "<IHHIIIIII", APP_MAGIC, APP_VERSION, APP_HEADER_SIZE,
        len(payload), memory_len, offsets[0], offsets[1], checksum(payload), 0,
    )
    assert len(header) == APP_HEADER_SIZE
    return header + payload


def build(source: Path, out_dir: Path) -> tuple[Path, Path]:
    nim = shutil.which("nim")
    objcopy = shutil.which("riscv64-unknown-elf-objcopy")
    nm = shutil.which("riscv64-unknown-elf-nm")
    if not nim or not objcopy or not nm:
        raise RuntimeError("nim and riscv64-unknown-elf binutils are required")
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / "app.elf"
    raw = out_dir / "app.bin"
    image = out_dir / "app.anchor.bin"
    subprocess.run([
        nim, "c", "-d:bl808kernel", "-d:bl808m0",
        "-d:bl808UsbAnchorApp", f"--nimcache:{out_dir / 'nimcache'}",
        f"--out:{elf}", str(source),
    ], cwd=REPO, check=True)
    subprocess.run([objcopy, "-O", "binary", str(elf), str(raw)],
                   cwd=REPO, check=True)
    symbol_output = subprocess.run([nm, "-n", str(elf)], cwd=REPO,
                                   check=True, capture_output=True, text=True).stdout
    payload = raw.read_bytes()
    image.write_bytes(package_app(payload, symbols(symbol_output)))
    manifest = {
        "kind": "bl808-usb-anchor-app-v1",
        "source": str(source),
        "image": str(image),
        "flash_offset": APP_FLASH_OFFSET,
        "load_address": APP_RAM_BASE,
        "image_bytes": image.stat().st_size,
        "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return image, out_dir / "manifest.json"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="cooperative Nim app source")
    parser.add_argument("--out-dir", type=Path,
                        default=Path("build/usb-anchor-app"))
    args = parser.parse_args()
    source = args.source.resolve()
    if not source.is_file() or source.suffix != ".nim":
        parser.error("source must be an existing Nim file")
    image, manifest = build(source, args.out_dir.resolve())
    print(f"Application image: {image} ({image.stat().st_size} bytes)")
    print(f"Manifest: {manifest}")
    print("Install through a responding resident anchor with:")
    print("  .venv/bin/python tools/hw_validate.py --uart-anchor-flash-image "
          f"{image} --uart-anchor-flash-image-address 0x{APP_FLASH_OFFSET:X} "
          "--uart-anchor-existing --no-jtag --uart-anchor-reset-after-flash "
          "--uart <current-runtime-uart>")


if __name__ == "__main__":
    main()
