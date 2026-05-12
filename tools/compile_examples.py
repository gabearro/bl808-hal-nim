#!/usr/bin/env python3
"""Compile-check all BL808 example programs without linking firmware images."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nim", default="nim", help="Nim compiler executable")
    parser.add_argument(
        "--build-dir",
        default=REPO_ROOT / "build" / "example-compile",
        type=Path,
        help="Directory for nimcache, output JSON, and failure logs",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="Continue after a compile failure",
    )
    parser.add_argument(
        "--no-kernel",
        action="store_true",
        help="Do not pass -d:bl808kernel",
    )
    return parser.parse_args()


def collect_examples() -> list[tuple[str, Path]]:
    items: list[tuple[str, Path]] = []
    for src in sorted((REPO_ROOT / "examples").glob("*.nim")):
        name = src.stem
        if name.startswith("m0_"):
            items.append(("bl808m0", src))
        elif name.startswith("d0_"):
            items.append(("bl808d0", src))
        elif name.startswith("lp_"):
            items.append(("bl808lp", src))

    ipc_demo = REPO_ROOT / "examples" / "ipc_demo.nim"
    if ipc_demo.exists():
        items.append(("bl808m0", ipc_demo))
        items.append(("bl808d0", ipc_demo))

    return items


def compile_one(args: argparse.Namespace, core: str, src: Path) -> tuple[bool, Path | None]:
    name = src.stem
    nimcache = args.build_dir / "nimcache" / core / name
    out = args.build_dir / "out" / core / name
    log = args.build_dir / "logs" / f"{name}.{core}.log"
    nimcache.mkdir(parents=True, exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    log.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        args.nim,
        "c",
        "--compileOnly",
        f"-d:{core}",
        f"--nimcache:{nimcache}",
        f"--out:{out}",
        str(src.relative_to(REPO_ROOT)),
    ]
    if not args.no_kernel:
        cmd.insert(4, "-d:bl808kernel")

    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode == 0:
        return True, None

    log.write_text(proc.stdout, encoding="utf-8")
    return False, log


def main() -> int:
    args = parse_args()
    start = time.monotonic()
    examples = collect_examples()
    failures: list[tuple[str, Path]] = []

    print(f"example compile-check tests={len(examples)}", flush=True)
    for core, src in examples:
        name = f"{src.stem}:{core}"
        ok, log = compile_one(args, core, src)
        if ok:
            print(f"PASS {name}", flush=True)
            continue

        assert log is not None
        print(f"FAIL {name}: see {log.relative_to(REPO_ROOT)}", flush=True)
        failures.append((name, log))
        if not args.keep_going:
            break

    elapsed = time.monotonic() - start
    print("", flush=True)
    print(f"Summary: checked={len(examples)} failed={len(failures)} elapsed={elapsed:.1f}s", flush=True)
    for name, log in failures:
        print(f"  FAIL {name:<32} {log.relative_to(REPO_ROOT)}", flush=True)

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
