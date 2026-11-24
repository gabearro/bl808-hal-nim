#!/usr/bin/env python3
"""Exercise an interpreter branch with more than 128 result values."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "wasm-branch-stack"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    results = " ".join(["i32"] * 129)
    values = "\n".join(f"      i32.const {i}" for i in range(129))
    wat = f"""(module
      (type $many (func (result {results})))
      (func (export "run") (type $many)
        (block (type $many)
{values}
          br 0))
      (func (export "ret") (type $many)
{values}
        return))
"""
    (OUT / "guest.wat").write_text(wat)
    subprocess.run(["wat2wasm", str(OUT / "guest.wat"), "-o", str(OUT / "guest.wasm")],
                   cwd=ROOT, check=True)
    subprocess.run(["nim", "c", "-r", "-d:release", "--skipUserCfg",
                    "--skipParentCfg", "--skipProjCfg", f"--path:{ROOT / 'src'}",
                    "--checks:on", "--assertions:on",
                    f"--nimcache:{OUT / 'nimcache'}", f"--out:{OUT / 'host-test'}",
                    "tools/test_wasm_branch_stack.nim", str(OUT / "guest.wasm")],
                   cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
