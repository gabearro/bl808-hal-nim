#!/usr/bin/env python3
"""Inspect SDK-generated BLAI `blai_model_bin[]` headers.

This is intentionally small and dependency-free. It mirrors the recovered
generated-model size-table layout used by the Nim NPU driver without trying to
compile or evaluate arbitrary C.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
from pathlib import Path
from typing import Any


ARRAY_RE = re.compile(
    r"static\s+const\s+uint8_t\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\[\]\s*="
    r"\s*\{(?P<body>.*?)\}\s*;",
    re.DOTALL,
)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{1,2})")


def extract_uint8_array(path: Path, name: str = "blai_model_bin") -> bytes:
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in ARRAY_RE.finditer(text):
        if match.group("name") != name:
            continue
        values = [int(token, 16) for token in HEX_BYTE_RE.findall(match.group("body"))]
        if not values:
            raise ValueError(f"{path}: array {name!r} has no hex byte values")
        return bytes(values)
    raise ValueError(f"{path}: static const uint8_t {name}[] not found")


def u32le(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ValueError(f"u32 read at {offset} exceeds {len(data)} bytes")
    return struct.unpack_from("<I", data, offset)[0]


def entry(data: bytes, offset: int) -> dict[str, Any]:
    words = [u32le(data, offset + index * 4) for index in range(4)]
    prefix_bytes = words[0]
    return {
        "offset": offset,
        "prefix_bytes": prefix_bytes,
        "word1": words[1],
        "word2": words[2],
        "word3": words[3],
        "active": prefix_bytes != 0,
        "prefix_aligned": prefix_bytes % 16 == 0,
        "prefix_within_blob": prefix_bytes <= len(data),
        "valid": prefix_bytes != 0 and prefix_bytes % 16 == 0 and prefix_bytes <= len(data),
    }


def section(blob_bytes: int, offset: int, size: int) -> dict[str, Any]:
    end = offset + size
    return {
        "offset": offset,
        "bytes": size,
        "end_exclusive": end,
        "active": size != 0,
        "ordered": end >= offset,
        "within_blob": end <= blob_bytes,
        "valid": size != 0 and end >= offset and end <= blob_bytes,
    }


def inspect_blai_header(path: Path, array_name: str = "blai_model_bin") -> dict[str, Any]:
    data = extract_uint8_array(path, array_name)
    prefix = entry(data, 0)
    cpu_candidate = entry(data, 16) if len(data) >= 32 else {
        "offset": 16,
        "prefix_bytes": 0,
        "word1": 0,
        "word2": 0,
        "word3": 0,
        "active": False,
        "prefix_aligned": False,
        "prefix_within_blob": False,
        "valid": False,
    }
    second_entry_looks_cpu = (
        cpu_candidate["active"]
        and cpu_candidate["prefix_aligned"]
        and cpu_candidate["word3"] == 0
    )
    has_prefix_directory = (
        prefix["active"]
        and prefix["prefix_aligned"]
        and second_entry_looks_cpu
        and prefix["prefix_bytes"] > cpu_candidate["prefix_bytes"]
    )
    cpu = cpu_candidate if has_prefix_directory or second_entry_looks_cpu else prefix
    has_second_size_entry = (
        cpu["prefix_bytes"] != prefix["prefix_bytes"]
        or cpu["word1"] != prefix["word1"]
        or cpu["word2"] != prefix["word2"]
        or cpu["word3"] != prefix["word3"]
    )
    header_bytes = 32 if has_second_size_entry else 16
    payload_cursor = header_bytes
    cpu_instruction = section(len(data), payload_cursor, prefix["prefix_bytes"])
    payload_cursor = cpu_instruction["end_exclusive"]
    cpu_bias = section(len(data), payload_cursor, prefix["word1"])
    payload_cursor = cpu_bias["end_exclusive"]
    cpu_weight = section(len(data), payload_cursor, prefix["word2"])
    payload_cursor = cpu_weight["end_exclusive"]
    npu_instruction = section(len(data), payload_cursor, cpu["prefix_bytes"])
    payload_cursor = npu_instruction["end_exclusive"]
    npu_bias = section(len(data), payload_cursor, cpu["word1"])
    payload_cursor = npu_bias["end_exclusive"]
    npu_weight = section(len(data), payload_cursor, cpu["word2"])
    payload_cursor = npu_weight["end_exclusive"]
    sections = {
        "cpu_instruction": cpu_instruction,
        "cpu_bias": cpu_bias,
        "cpu_weight": cpu_weight,
        "npu_instruction": npu_instruction,
        "npu_bias": npu_bias,
        "npu_weight": npu_weight,
    }
    payload_fits = all(item["within_blob"] for item in sections.values())
    payload_total = sum(item["bytes"] for item in sections.values())
    npu_total = (
        npu_instruction["bytes"]
        + npu_bias["bytes"]
        + npu_weight["bytes"]
    )
    return {
        "path": str(path),
        "array": array_name,
        "array_bytes": len(data),
        "array_sha256": hashlib.sha256(data).hexdigest(),
        "prefix": prefix,
        "cpu": cpu,
        "has_prefix_directory": has_prefix_directory,
        "has_second_size_entry": has_second_size_entry,
        "header_bytes": header_bytes,
        "sections": sections,
        "payload_bytes_expected": payload_cursor,
        "payload_total": payload_total,
        "trailing_bytes": max(0, len(data) - payload_cursor),
        "payload_fits": payload_fits,
        "npu_payload_bytes": npu_total,
        "valid": prefix["valid"] and cpu["valid"] and payload_fits and npu_total > 0,
    }


def nim_uint8_array_source(data: bytes, const_name: str, values_per_line: int = 12) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", const_name):
        raise ValueError(f"invalid Nim const name: {const_name!r}")
    if values_per_line <= 0:
        raise ValueError("values_per_line must be positive")

    lines = [f"const {const_name}*: array[{len(data)}, uint8] = ["]
    for offset in range(0, len(data), values_per_line):
        chunk = data[offset : offset + values_per_line]
        values = ", ".join(f"0x{value:02X}'u8" for value in chunk)
        suffix = "," if offset + values_per_line < len(data) else ""
        lines.append(f"  {values}{suffix}")
    lines.append("]")
    return "\n".join(lines) + "\n"


def blai_header_nim_const_source(
    path: Path,
    const_name: str,
    array_name: str = "blai_model_bin",
    values_per_line: int = 12,
) -> str:
    return nim_uint8_array_source(
        extract_uint8_array(path, array_name), const_name, values_per_line)


def blai_header_nim_section_const_source(
    path: Path,
    section_name: str,
    const_name: str,
    array_name: str = "blai_model_bin",
    values_per_line: int = 12,
) -> str:
    data = extract_uint8_array(path, array_name)
    summary = inspect_blai_header(path, array_name)
    sections = summary["sections"]
    if section_name not in sections:
        raise ValueError(f"unknown generated section: {section_name!r}")
    section = sections[section_name]
    start = int(section["offset"])
    end = int(section["end_exclusive"])
    if not section["ordered"] or start < 0 or end < start or end > len(data):
        raise ValueError(f"invalid generated section window: {section_name!r}")
    return nim_uint8_array_source(
        data[start:end], const_name, values_per_line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("header", type=Path)
    parser.add_argument("--array", default="blai_model_bin")
    parser.add_argument(
        "--emit-nim-const",
        metavar="NAME",
        help="Emit the parsed byte array as a Nim `const NAME*: array[N, uint8]`.",
    )
    parser.add_argument(
        "--emit-nim-section",
        choices=[
            "cpu_instruction",
            "cpu_bias",
            "cpu_weight",
            "npu_instruction",
            "npu_bias",
            "npu_weight",
        ],
        help="Emit only one recovered generated-model section as a Nim const.",
    )
    parser.add_argument(
        "--values-per-line",
        type=int,
        default=12,
        help="Number of byte literals per Nim output line for --emit-nim-const.",
    )
    args = parser.parse_args()
    if args.emit_nim_const and args.emit_nim_section:
        print(
            blai_header_nim_section_const_source(
                args.header,
                args.emit_nim_section,
                args.emit_nim_const,
                args.array,
                args.values_per_line,
            ),
            end="",
        )
    elif args.emit_nim_const:
        print(
            blai_header_nim_const_source(
                args.header, args.emit_nim_const, args.array, args.values_per_line),
            end="",
        )
    else:
        print(json.dumps(inspect_blai_header(args.header, args.array), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
