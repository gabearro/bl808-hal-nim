"""Check the Op primitive (src/bl808/wifi/fw/op.nim) by exhaustive model.

A machine owns one Op and issues stamped carriers (timer expiries, frame
confirmations, indications) for each operation it starts. Every sequence of
go, finish and the delivery of any carrier ever issued, up to a bounded
length, is run against the real procs. A machine that ends its operation on
the first current delivery must see each operation completed at most once,
and a stale delivery must change nothing.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program


MODEL = r'''
import std/sequtils
type Model = object
  op: Op
  issued: seq[uint32]       # stamps of every carrier handed out
  lastGo: uint32
  completions: seq[uint32]  # stamps that completed an operation

proc step(m: var Model; action: int) =
  ## action 0: go and hand out one carrier; 1: hand out a second carrier of
  ## the live operation; 2: finish; 3+: deliver carrier action-3.
  case action
  of 0:
    let stamp = opGo(m.op)
    doAssert stamp != 0 and stamp notin m.issued
    m.lastGo = stamp
    m.issued.add stamp
  of 1:
    if m.op.live: m.issued.add m.lastGo
  of 2:
    opFinish(m.op)
  else:
    let stamp = m.issued[action - 3]
    let before = m.op
    if opCurrent(m.op, stamp):
      doAssert m.op.live and stamp == m.lastGo
      m.completions.add stamp
      opFinish(m.op)
    else:
      doAssert m.op == before, "a stale delivery changed the operation"
      doAssert not m.op.live or stamp != m.lastGo

proc check(m: Model) =
  for stamp in m.completions:
    doAssert m.completions.count(stamp) == 1, "an operation completed twice"

var explored = 0
proc explore(m: Model; depth: int) =
  inc explored
  check(m)
  if depth == 0: return
  for action in 0 ..< 3 + m.issued.len:
    var next = m
    step(next, action)
    explore(next, depth - 1)

explore(Model(), 7)
doAssert explored > 10_000

# The serial skips zero when it wraps, so a zero stamp never matches.
var op = Op(serial: high(uint32))
doAssert opGo(op) == 1 and opCurrent(op, 1) and not opCurrent(op, 0)
opFinish(op)
doAssert not opCurrent(op, 1)
doAssert opEnvStamp(opStampEnv(0xA5A5_0001'u32)) == 0xA5A5_0001'u32
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_op_model(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, (FW / "op.nim").read_text() + MODEL)
