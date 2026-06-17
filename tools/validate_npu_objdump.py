#!/usr/bin/env python3
"""Recover BL808 BLAI/NPU symbols and MMIO clues from vendor objects.

This is intentionally a discovery tool, not an equivalence checker. The first
pure-Nim NPU milestone needs repeatable evidence for SDK symbols, call edges,
and register/immediate constants before layer execution is implemented.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
THEAD_MATTR = (
    "+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov,"
    "+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadmempair,+xtheadsync"
)
DEFAULT_KEYWORDS = ("npu", "blai", "cnn", "bflb_mtimer", "blai_inst")
REGISTER_WINDOWS = {
    "MM_GLB": (0x30000000, 0x30001000),
    "MM_MISC": (0x30005000, 0x30006000),
    "CODEC_MISC": (0x3001F000, 0x30020000),
    "BLAI": (0x30024000, 0x30025000),
}


def tool_path(name: str, env_name: str | None = None) -> str:
    if env_name and os.environ.get(env_name):
        return os.environ[env_name]
    found = shutil.which(name)
    if found:
        return found
    if name == "llvm-objdump":
        homebrew = Path("/opt/homebrew/opt/llvm/bin/llvm-objdump")
        if homebrew.exists():
            return str(homebrew)
    raise RuntimeError(f"missing required tool: {name}")


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, errors="ignore")


def candidate_roots(args: argparse.Namespace) -> list[Path]:
    roots: list[Path] = []
    for item in args.input:
        roots.append(item)
    for env_name in ("BL808_M1S_SDK", "BLAI_NPU_TOOLCHAIN"):
        value = os.environ.get(env_name)
        if value:
            roots.append(Path(value))
    return roots


def is_candidate(path: Path, keywords: tuple[str, ...]) -> bool:
    lower = str(path).lower()
    return any(keyword in lower for keyword in keywords)


def iter_inputs(roots: Iterable[Path], keywords: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    for root in roots:
        if not root.exists():
            raise RuntimeError(f"input path not found: {root}")
        if root.is_file():
            out.append(root)
            continue
        for suffix in ("*.a", "*.o", "*.elf"):
            for path in root.rglob(suffix):
                if is_candidate(path, keywords):
                    out.append(path)
    return sorted(set(out))


def parse_symbols(nm: str, path: Path) -> list[dict[str, str]]:
    try:
        text = run([nm, "-g", "--defined-only", str(path)])
    except subprocess.CalledProcessError as exc:
        return [{"error": f"nm failed: {exc}"}]
    symbols: list[dict[str, str]] = []
    for line in text.splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+([A-Za-z])\s+(.+)$", line.strip())
        if not match:
            continue
        addr, kind, name = match.groups()
        symbols.append({"address": f"0x{int(addr, 16):x}", "kind": kind, "name": name})
    return symbols


def function_symbol_names(symbols: list[dict[str, str]]) -> set[str]:
    return {
        symbol["name"]
        for symbol in symbols
        if symbol.get("kind", "").upper() in {"T", "W"} and "name" in symbol
    }


def parse_disassembly(objdump: str, path: Path, symbols: list[dict[str, str]]) -> dict[str, object]:
    text = run([objdump, "-dr", f"--mattr={THEAD_MATTR}", str(path)])
    symbol_names = function_symbol_names(symbols)
    current = None
    calls: dict[str, set[str]] = defaultdict(set)
    immediates: dict[str, list[str]] = defaultdict(list)
    register_hits: dict[str, list[dict[str, str]]] = defaultdict(list)
    stores: dict[str, list[str]] = defaultdict(list)

    for line in text.splitlines():
        fn_match = re.match(r"^([0-9a-fA-F]+) <([^>]+)>:$", line.strip())
        if fn_match:
            name = fn_match.group(2)
            if not symbol_names or name in symbol_names:
                current = name
            elif not name.startswith(".L"):
                current = None
            continue
        if current is None:
            continue

        reloc_call = re.search(r"R_RISCV_(?:CALL|CALL_PLT)\s+([^\s]+)", line)
        if reloc_call:
            target = reloc_call.group(1)
            if not target.startswith(".L"):
                calls[current].add(target)

        target_call = re.search(r"\b(?:jal|j)\s+[0-9a-fA-Fx]+ <([^>]+)>", line)
        if target_call:
            target = target_call.group(1)
            if target in symbol_names or not target.startswith(".L"):
                calls[current].add(target)

        if re.search(r"\b(?:sw|sd|sh|sb)\b", line):
            stores[current].append(line.strip())

        for imm in re.findall(r"0x[0-9a-fA-F]+", line):
            value = int(imm, 16)
            for window_name, (start, end) in REGISTER_WINDOWS.items():
                if start <= value < end:
                    register_hits[current].append({
                        "window": window_name,
                        "address": f"0x{value:08x}",
                        "line": line.strip(),
                    })
                    immediates[current].append(f"0x{value:08x}")

    return {
        "calls": {fn: sorted(callees) for fn, callees in sorted(calls.items())},
        "register_hits": dict(sorted(register_hits.items())),
        "store_lines": dict(sorted(stores.items())),
        "register_immediates": {
            fn: sorted(set(values)) for fn, values in sorted(immediates.items())
        },
    }


def summarize(path: Path, *, nm: str, objdump: str, keywords: tuple[str, ...]) -> dict[str, object]:
    symbols = parse_symbols(nm, path)
    interesting_symbols = [
        symbol for symbol in symbols
        if "name" in symbol and any(k in symbol["name"].lower() for k in keywords)
    ]
    disassembly = parse_disassembly(objdump, path, symbols)
    return {
        "path": str(path),
        "symbols_total": len([symbol for symbol in symbols if "name" in symbol]),
        "interesting_symbols": interesting_symbols,
        **disassembly,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="THEAD-aware BL808 BLAI/NPU SDK objdump recovery helper"
    )
    parser.add_argument("input", nargs="*", type=Path,
                        help="SDK/toolchain archive, object, ELF, or directory.")
    parser.add_argument("--keyword", action="append", default=[],
                        help="Candidate path/symbol keyword. May be repeated.")
    parser.add_argument("--json-out", type=Path, default=None,
                        help="Write full machine-readable recovery summary.")
    parser.add_argument("--limit", type=int, default=80,
                        help="Maximum number of candidate binaries to inspect.")
    args = parser.parse_args()

    keywords = tuple(k.lower() for k in (args.keyword or DEFAULT_KEYWORDS))
    roots = candidate_roots(args)
    if not roots:
        print(
            "No NPU inputs configured. Set BL808_M1S_SDK and/or "
            "BLAI_NPU_TOOLCHAIN, or pass paths explicitly.",
            file=sys.stderr,
        )
        return 2

    try:
        objdump = tool_path("llvm-objdump", "LLVM_OBJDUMP")
        nm = tool_path("riscv64-unknown-elf-nm")
        inputs = iter_inputs(roots, keywords)
        if not inputs:
            print("No candidate NPU/BLAI objects or archives found.", file=sys.stderr)
            return 3
        summaries = [
            summarize(path, nm=nm, objdump=objdump, keywords=keywords)
            for path in inputs[:args.limit]
        ]
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        print(f"tool failed: {exc}", file=sys.stderr)
        return 1

    report = {
        "inputs": [str(path) for path in inputs],
        "inspected": len(summaries),
        "keywords": list(keywords),
        "thead_mattr": THEAD_MATTR,
        "summaries": summaries,
    }

    print(f"Candidate binaries: {len(inputs)}")
    print(f"Inspected:          {len(summaries)}")
    for item in summaries:
        print("")
        print(item["path"])
        print(f"  symbols: {item['symbols_total']}")
        print(f"  interesting symbols: {len(item['interesting_symbols'])}")
        print(f"  functions with calls: {len(item['calls'])}")
        print(f"  functions with register hits: {len(item['register_hits'])}")
        for symbol in item["interesting_symbols"][:12]:
            print(f"    {symbol['kind']} {symbol['address']} {symbol['name']}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print("")
        print(f"json_out={args.json_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
