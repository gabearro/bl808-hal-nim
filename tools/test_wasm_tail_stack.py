"""Exercise guest and host tail calls in the full WASM interpreter."""

from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
GUEST = """(module
  (type $step (func (param i32) (result i32)))
  (import "env" "finish" (func $host (type $step)))
  (table 2 funcref)
  (elem (i32.const 0) $indirect $host)

  (func $direct (type $step) (param $remaining i32) (result i32)
    local.get $remaining
    i32.eqz
    if
      i32.const 42
      return
    end
    i32.const 100
    block
      i32.const 200
      local.get $remaining
      i32.const 1
      i32.sub
      return_call $direct
    end
    unreachable)

  (func $indirect (type $step) (param $remaining i32) (result i32)
    local.get $remaining
    i32.eqz
    if
      i32.const 42
      return
    end
    i32.const 100
    block
      i32.const 200
      local.get $remaining
      i32.const 1
      i32.sub
      i32.const 0
      return_call_indirect (type $step)
    end
    unreachable)

  (func $hostDirect (result i32)
    i32.const 100
    i32.const 42
    return_call $host)

  (func $hostIndirect (result i32)
    i32.const 100
    i32.const 42
    i32.const 1
    return_call_indirect (type $step))

  ;; Each wrapper keeps an operand live below the tail caller's frame.
  (func (export "direct") (result i32)
    i32.const 1000
    i32.const 10000
    call $direct
    i32.add)

  (func (export "indirect") (result i32)
    i32.const 1000
    i32.const 10000
    call $indirect
    i32.add)

  (func (export "hostDirect") (result i32)
    i32.const 1000
    call $hostDirect
    i32.add)

  (func (export "hostIndirect") (result i32)
    i32.const 1000
    call $hostIndirect
    i32.add))
"""


@pytest.fixture(scope="module")
def tail_stack_test(tmp_path_factory):
    out = tmp_path_factory.mktemp("wasm-tail-stack")
    wat, guest, runner = (out / name for name in ("guest.wat", "guest.wasm", "runner"))
    wat.write_text(GUEST)
    subprocess.run(["wat2wasm", str(wat), "-o", str(guest)], check=True)
    subprocess.run(
        ["nim", "c", "-d:release", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
         "--path:src", "--checks:on", "--assertions:on", f"--nimcache:{out / 'nimcache'}",
         f"--out:{runner}", "tools/test_wasm_tail_stack.nim"], cwd=ROOT, check=True,
    )
    return runner, guest


@pytest.mark.parametrize("name", ["direct", "indirect", "hostDirect", "hostIndirect"])
def test_tail_stack(tail_stack_test, name):
    runner, guest = tail_stack_test
    subprocess.run([str(runner), str(guest), name], check=True, timeout=10)
