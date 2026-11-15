"""Exercise the production host command mailbox and ACK handoff."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_ipc_host_lifetime import CHECKS as HOST_CHECKS, HOST, ROOT, program
from test_wifi_disconnect_tx import procedure

PLATFORM = r"""
var
  commandA, commandB: array[64, uint8]
  messageA, messageB: array[1100, uint8]
  triggers, copies: int
  nestedResult: cint
  onCopy, onTrigger, onIrqAck: proc()
  exactCopy: uint32
proc command(index: int): pointer =
  if index == 0: addr commandA[0] else: addr commandB[0]
proc message(index: int): pointer =
  if index == 0: addr messageA[0] else: addr messageB[0]
proc mailboxTrigger(address: uint; value: uint32) =
  if address == IpcEmb2AppAck and onIrqAck != nil: onIrqAck()
  if address == IpcApp2EmbTrigger and value == IpcIrqA2eMsg:
    inc triggers
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) != nil
    if onTrigger != nil: onTrigger()
proc mailboxCopy(size: uint32) =
  inc copies
  if exactCopy != 0: doAssert size == exactCopy, "copy read beyond the message length"
  if onCopy != nil:
    let action = onCopy
    onCopy = nil
    interrupt(action)
"""

CHECKS = r"""
proc mailboxAck(context, owner: pointer): uint8 {.cdecl.} =
  doAssert context == cast[pointer](0xA0), "ACK context was rebound"
  acknowledged(context, owner)
proc prepareMailbox(state: bool; length = 16'u32) =
  onCopy = nil
  onTrigger = nil
  onIrqAck = nil
  exactCopy = 0
  setup()
  storePtr(E(), 16, cast[pointer](mailboxAck))
  enabled = state
  incoming = state
  onCopy = nil
  onTrigger = nil
  exactCopy = 0
  triggers = 0
  copies = 0
  nestedResult = -9
  commandA = default(typeof(commandA))
  commandB = default(typeof(commandB))
  messageA = default(typeof(messageA))
  messageB = default(typeof(messageB))
  for index in 0 .. 1:
    storePtr(command(index), BlCmdA2eMsgOff, message(index))
    storeU32(message(index), 4, length - 8)
    for offset in 8'u ..< length.uint: storeU8(message(index), offset, (offset + index.uint).uint8)
proc send(index = 0; length = 16'u16): cint = ipc_host_msg_push(E(), command(index), length)
proc acknowledge(sequence: uint8) =
  storeU8(P(), SharedMsgBodyOff + LmacMsgSrcIdOff, sequence)
  ipc_host_irq(E(), IpcIrqE2aMsgAck)
proc drainPending(state: bool) =
  if pendingIrq != nil:
    incoming = true
    ipcHostIrqRestore(8)
    incoming = state
    enabled = state

for state in [false, true]:
  prepareMailbox(state)
  when TestCase == "normal":
    doAssert send() == 0 and triggers == 1
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(0)
    acknowledge(0)
    doAssert ackCalls == 1 and loadPtr(E(), EnvMsgA2eHostidOff) == nil
    doAssert loadU8(E(), EnvMsgA2eCntOff) == 1
  elif TestCase == "preserve_header":
    storeU8(message(0), LmacMsgSrcIdOff, 9)
    let original = messageA
    doAssert send() == 0
    doAssert messageA == original, "sending rewrote the source message"
    doAssert loadU8(P(), SharedMsgBodyOff + LmacMsgSrcIdOff) == 9
  elif TestCase in ["reserve", "copy_interrupt"]:
    when TestCase == "reserve":
      onAccess = proc(base: pointer; offset: uint; write: bool) =
        if base == E() and offset == EnvMsgA2eHostidOff and not write:
          onAccess = nil
          interrupt(proc() = nestedResult = send(1))
    else:
      onCopy = proc() = nestedResult = send(1)
    doAssert send() == 0
    drainPending(state)
    doAssert nestedResult == -1 and triggers == 1,
      "two senders acquired the same mailbox"
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(0)
    doAssert loadU8(P(), SharedMsgBodyOff + 8) == 8
  elif TestCase == "ack_mismatch":
    doAssert send() == 0
    acknowledge(7)
    doAssert ackCalls == 0, "mismatched ACK reached the command callback"
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(0)
    doAssert loadU8(E(), EnvMsgA2eCntOff) == 0
    acknowledge(0)
    doAssert ackCalls == 1
  elif TestCase == "duplicate":
    doAssert send() == 0
    acknowledge(0)
    acknowledge(0)
    doAssert ackCalls == 1 and loadU8(E(), EnvMsgA2eCntOff) == 1
  elif TestCase in ["ack_snapshot", "ack_reset"]:
    doAssert send() == 0
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == E() and offset == EnvMsgA2eHostidOff and write:
        onAccess = nil
        interrupt(proc() =
          when TestCase == "ack_reset":
            ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
            storePtr(E(), EnvMsgA2eHostidOff, command(1))
          else:
            storePtr(E(), 16, cast[pointer](alternate))
            storePtr(E(), EnvPthisOff, cast[pointer](0xCC)))
    acknowledge(0)
    onAccess = nil
    drainPending(state)
    when TestCase == "ack_reset":
      doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(1)
      doAssert loadU8(E(), EnvMsgA2eCntOff) == 0
      if state: doAssert ackCalls == 0
    else:
      doAssert alternateCalls == 0 and ackCalls == 1, "ACK callback was rebound during handoff"
  elif TestCase == "next_from_ack":
    doAssert send() == 0
    onAck = proc() =
      onAck = nil
      doAssert send(1) == 0
    acknowledge(0)
    doAssert ackCalls == 1 and triggers == 2
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(1)
    ipc_host_irq(E(), IpcIrqE2aMsgAck)
    doAssert ackCalls == 1 and loadPtr(E(), EnvMsgA2eHostidOff) == command(1)
    acknowledge(1)
    doAssert ackCalls == 2
  elif TestCase == "wrap":
    storeU8(E(), EnvMsgA2eCntOff, 255)
    doAssert send() == 0
    acknowledge(255)
    doAssert loadU8(E(), EnvMsgA2eCntOff) == 0
    doAssert send(1) == 0
    acknowledge(0)
    doAssert ackCalls == 2
  elif TestCase == "bad_length":
    for length in [0'u16, 1, 3, 7, 509, 65535]:
      doAssert send(length=length) == -1
    doAssert triggers == 0 and copies == 0
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == nil
  elif TestCase == "short_no_reads":
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      doAssert base != message(0), "short message header was read"
    for length in 0'u16 .. 7: doAssert send(length=length) == -1
    onAccess = nil
  elif TestCase == "nil_callback":
    storePtr(E(), 16, nil)
    doAssert send() == 0
    acknowledge(0)
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == nil
    doAssert loadU8(E(), EnvMsgA2eCntOff) == 1 and ackCalls == 0
  elif TestCase == "dispatch_reset":
    doAssert send() == 0
    onIrqAck = proc() =
      onIrqAck = nil
      ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
      storePtr(E(), EnvMsgA2eHostidOff, command(1))
    acknowledge(0)
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == command(1)
    doAssert loadU8(E(), EnvMsgA2eCntOff) == 0 and ackCalls == 0
  elif TestCase == "bad_declared_length":
    for length in [0'u32, 9, 501, 65536, high(uint32)]:
      storeU32(message(0), 4, length)
      doAssert send() == -1
    doAssert copies == 0 and triggers == 0
  elif TestCase == "lengths":
    for length in [8'u16, 9, 10, 11, 12, 505, 506, 507, 508]:
      prepareMailbox(state, length.uint32)
      exactCopy = length.uint32
      for offset in 0'u ..< SharedMsgBodySize.uint: storeU8(P(), SharedMsgBodyOff + offset, 0xA5)
      doAssert send(length=length) == 0
      for offset in 0'u ..< length.uint:
        doAssert loadU8(P(), SharedMsgBodyOff + offset) == loadU8(message(0), offset)
      for offset in length.uint ..< ((length.uint + 3) and not 3'u):
        doAssert loadU8(P(), SharedMsgBodyOff + offset) == 0
      acknowledge(0)
  elif TestCase == "null":
    doAssert ipc_host_msg_push(nil, command(0), 16) == -1
    doAssert ipc_host_msg_push(E(), nil, 16) == -1
    storePtr(command(0), BlCmdA2eMsgOff, nil)
    doAssert send() == -1 and triggers == 0
  doAssert enabled == state
  doAssert pendingIrq == nil
  doAssert ipcHostActiveDispatch == nil
"""


def mailbox_source(case: str, mutation: str = "") -> str:
    base = program("nested", None).split('\nconst TestCase =', 1)[0]
    base = base.replace("proc regWrite(address: uint; value: uint32) = discard",
                        "proc mailboxTrigger(address: uint; value: uint32)\n"
                        "proc regWrite(address: uint; value: uint32) = mailboxTrigger(address, value)")
    base = base.replace("proc c_memcpy(dst, src: pointer; size: csize_t): pointer =\n",
                        "proc mailboxCopy(size: uint32)\n"
                        "proc c_memcpy(dst, src: pointer; size: csize_t): pointer =\n")
    base = base.replace("  copyMem(dst, src, size.int * Scale.int)\n  dst\n",
                        "  copyMem(dst, src, size.int * Scale.int)\n  mailboxCopy(size.uint32)\n  dst\n")
    setup = HOST_CHECKS.split("for initialIrq", 1)[0]
    alignment = procedure((HOST / "accessors.nim").read_text(), "roundUp4")
    source = (base + setup + PLATFORM + alignment + (HOST / "messages.nim").read_text()
              + f'\nconst TestCase = "{case}"\n' + CHECKS)
    if mutation:
        name = "ipc_host_msg_push" if mutation in {"publish_lock", "copy", "padding", "length", "minimum"} else "ipcHostMsgAckHandler"
        body = procedure(source, name)
        changed = body
        if mutation == "publish_lock":
            changed = changed.replace("  let saved = ipcHostIrqSave()\n", "")
            changed = changed.replace("  defer: ipcHostIrqRestore(saved)\n", "")
        elif mutation == "ack_lock":
            changed = changed.replace("    let saved = ipcHostIrqSave()\n", "")
            changed = changed.replace("    defer: ipcHostIrqRestore(saved)\n", "")
        elif mutation == "sequence":
            changed = changed.replace("if loadU8(shared, SharedMsgBodyOff + LmacMsgSrcIdOff) != sequence:", "if false:")
        elif mutation == "snapshot":
            changed = changed.replace("discard ack.callback(ack.context, ack.hostId)", "callRecvMsgAck(env, ack.hostId)")
        elif mutation == "lifetime":
            changed = changed.replace("  if scope.cancelled: return\n", "")
        elif mutation == "scope":
            changed = changed.replace("if scope == nil or not ipcHostDispatchCurrent(scope[], env): return", "if false: return")
        elif mutation == "copy":
            changed = changed.replace("msg, copyLen.csize_t", "msg, roundUp4(copyLen).csize_t")
        elif mutation == "padding":
            changed = changed.replace("if padding != 0:", "if false:")
        elif mutation == "length":
            changed = changed.replace("if loadU32(msg, LmacMsgParamLenOff) != copyLen - LmacMsgHeaderSize:", "if false:")
        elif mutation == "minimum":
            changed = changed.replace("copyLen < LmacMsgHeaderSize or ", "")
        assert body != changed
        source = source.replace(body, changed)
    return source


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["normal", "preserve_header", "reserve", "copy_interrupt",
    "ack_mismatch", "duplicate", "ack_snapshot", "ack_reset", "next_from_ack", "wrap",
    "bad_length", "bad_declared_length", "lengths", "null", "short_no_reads", "nil_callback", "dispatch_reset"])
def test_ipc_mailbox(tmp_path: Path, mode: str, case: str) -> None:
    result = run_case(tmp_path, mailbox_source(case), mode)
    assert result.returncode == 0, result.stdout


def run_case(tmp_path: Path, source: str, mode: str = "checked") -> subprocess.CompletedProcess:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", source)) -
                   set(re.findall(r"\b(nimFwDbg\w+): uint32", source)))
    source = "var\n" + "".join(f"  {name}: uint32\n" for name in debug) + source if debug else source
    path = tmp_path / "mailbox.nim"
    path.write_text(source)
    flags = {"checked": [], "release": ["-d:release"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    return subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", "--assertions:on", *flags[mode],
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)


@pytest.mark.parametrize(("mutation", "case"), [
    ("publish_lock", "reserve"), ("ack_lock", "ack_reset"), ("sequence", "ack_mismatch"),
    ("snapshot", "ack_snapshot"), ("lifetime", "ack_reset"), ("scope", "dispatch_reset"),
    ("copy", "lengths"), ("padding", "lengths"), ("length", "bad_declared_length"),
    ("minimum", "short_no_reads"),
])
def test_ipc_mailbox_guards(tmp_path: Path, mutation: str, case: str) -> None:
    result = run_case(tmp_path, mailbox_source(case, mutation))
    assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
