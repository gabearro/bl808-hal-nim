"""Exercise command failure, cancellation, and late completion ownership."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_cmd_submission import CHECKS as SUBMISSION_CHECKS, CMDS, WIFI, program as submission_program
from test_wifi_disconnect_tx import ROOT, procedure

ADAPTER = r"""
proc eventWait(event: pointer; bits: uint32; clear, all: cint;
               ticks: uint32): uint32 {.cdecl.} =
  inc waitCalls
  if (loadU32(event, 0) and bits) != 0: return loadU32(event, 0) and bits
  if onWait != nil:
    let action = onWait
    onWait = nil
    action()
  elif not forceTimeout:
    finishAck()
    finishCfm()
  if forceTimeout: return 0
  loadU32(event, 0) and bits
"""

CHECKS = r"""
proc sourceMessage(size = 12'u; declared = 4'u32): pointer =
  result = osMalloc(size)
  storeU16(result, LmacMsgIdOff, MM_TIM_UPDATE_REQ)
  storeU32(result, LmacMsgParamLenOff, declared)
proc sendSource(source: pointer; blocking = false): cint =
  if blocking: storeU16(source, LmacMsgIdOff, MM_RESET_REQ)
  blSendMsg(cast[ptr BlHw](H()), ptrAt(source, 8), blocking.cint, MM_RESET_CFM, nil)
proc requestWithBuffer(): cint =
  let source = sourceMessage()
  storeU16(source, LmacMsgIdOff, MM_RESET_REQ)
  blSendMsg(cast[ptr BlHw](H()), ptrAt(source, 8), 1, MM_RESET_CFM, addr reply[0])
proc checkReleased() =
  doAssert liveAllocations() == 0, "command or source left without an owner"
  doAssert loadU32(H(), MgrQueueSzOff) == 0
proc checkPending() =
  doAssert liveAllocations() == 1, "pending ACK did not retain exactly one command"
  doAssert loadU32(H(), MgrQueueSzOff) == 1
  let command = loadPtr(E(), EnvMsgA2eHostidOff)
  doAssert command != nil
  doAssert loadPtr(command, CmdE2aMsgOff) == nil
  doAssert loadPtr(command, CmdCompleteOff) == nil
  doAssert not wifiCmdMgrRecoverIfCrashed(H()), "recovery reused a pending ACK slot"
  finishAck()
  checkReleased()
  doAssert wifiCmdMgrRecoverIfCrashed(H())
  doAssert loadU32(H(), MgrStateOff) != RwnxCmdMgrStateCrashed
proc canceled(context, command, message: pointer): cint {.cdecl.} =
  inc callbackCalls
  when TestCase == "callback_reinit": bl_cmd_mgr_init(H())
  else: cmdMgrDrain(H())
  checkAccess(command)
  doAssert commandFrees == 0, "confirmation callback lost its command"
  callbackReturn
proc nested(context, command, message: pointer): cint {.cdecl.} =
  inc callbackCalls
  doAssert command != nil, "nested confirmation was redispatched as unsolicited"
  if callbackCalls == 1:
    discard cmdMgrMsgind(H(), message, cast[pointer](nested))
  0
proc distinctMessage(context, command, message: pointer): cint {.cdecl.} =
  inc callbackCalls
  doAssert command != nil, "distinct confirmation lost its queued command"
  if callbackCalls == 1:
    var nextMessage: array[32, uint8]
    storeU16(addr nextMessage[0], IpcE2aMsgIdOff, MM_RESET_CFM)
    discard cmdMgrMsgind(H(), addr nextMessage[0], cast[pointer](distinctMessage))
  0

for state in [false, true]:
  install(state)
  forceTimeout = false
  onWait = nil
  onAck = nil
  onCommandFree = nil
  callbackCalls = 0
  callbackReturn = 0
  reply = default(typeof(reply))
  onEventDelete = nil
  when TestCase in ["oversize", "truncated", "nil_source"]:
    when TestCase == "nil_source":
      let command = osMalloc(BlCmdSize)
      doAssert cmdMgrQueue(H(), command) < 0
    else:
      let declared = if TestCase == "oversize": 501'u32 else: 65540'u32
      doAssert sendSource(sourceMessage(declared = declared)) == -Emsgsize,
        "invalid message was admitted"
    doAssert publications == 0 and waitCalls == 0
    checkReleased()
  elif TestCase == "limit":
    doAssert sendSource(sourceMessage(508, 500)) == 0
    doAssert publications == 1
    finishAck()
    checkReleased()
  elif TestCase in ["busy", "busy_blocking"]:
    let foreign = cast[pointer](0xDEAD)
    storePtr(E(), EnvMsgA2eHostidOff, foreign)
    doAssert sendSource(sourceMessage(), TestCase == "busy_blocking") < 0,
      "mailbox rejection was reported as success"
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == foreign
    doAssert publications == 0
    checkReleased()
  elif TestCase in ["timeout_ack", "timeout_cfm", "timeout_deferred"]:
    forceTimeout = true
    when TestCase == "timeout_cfm": onWait = proc() = finishAck()
    when TestCase == "timeout_deferred": doAssert request() == 0
    doAssert request(false, true) == -Etimedout, "timeout did not reach caller"
    doAssert loadU32(H(), MgrStateOff) == RwnxCmdMgrStateCrashed
    when TestCase == "timeout_cfm":
      checkReleased()
      finishCfm()
      doAssert wifiCmdMgrRecoverIfCrashed(H())
    else:
      checkPending()
    forceTimeout = false
    doAssert request(false) == 0
    checkReleased()
  elif TestCase == "timeout_batch":
    for index in 0 ..< 3: doAssert request() == 0
    forceTimeout = true
    doAssert request(false, true) == -Etimedout
    doAssert publications == 1
    checkPending()
    doAssert publications == 1, "canceled deferred commands were published"
  elif TestCase == "timeout_cfm_buffer":
    forceTimeout = true
    doAssert requestWithBuffer() == -Etimedout
    checkPending()
    let before = reply
    finishCfm()
    doAssert reply == before
  elif TestCase == "late_event_delete":
    forceTimeout = true
    onEventDelete = proc() = finishAck()
    doAssert request(false, true) == -Etimedout
    checkReleased()
    doAssert wifiCmdMgrRecoverIfCrashed(H())
  elif TestCase in ["drain_wait", "drain_pending"]:
    when TestCase == "drain_wait":
      onWait = proc() = cmdMgrDrain(H())
      doAssert request(false, true) == -Epipe, "drained wait reported success"
    else:
      doAssert request() == 0
      doAssert request() == 0
      cmdMgrDrain(H())
    checkPending()
  elif TestCase in ["callback_drain", "callback_decline", "callback_drain_pending", "callback_reinit"]:
    doAssert request(confirmation = true) == 0
    when TestCase != "callback_drain_pending": finishAck()
    when TestCase == "callback_decline": callbackReturn = 1
    var message: array[32, uint8]
    storeU16(addr message[0], IpcE2aMsgIdOff, MM_RESET_CFM)
    discard cmdMgrMsgind(H(), addr message[0], cast[pointer](canceled))
    doAssert callbackCalls == 1
    when TestCase == "callback_drain_pending": checkPending()
    else:
      checkReleased()
      when TestCase == "callback_reinit":
        doAssert request(false) == 0
        checkReleased()
      else: doAssert wifiCmdMgrRecoverIfCrashed(H())
  elif TestCase in ["nested_confirmation", "nested_same_message", "nested_distinct_message"]:
    doAssert request(confirmation = true) == 0
    when TestCase != "nested_confirmation":
      doAssert request(confirmation = true) == 0
    finishAck()
    when TestCase != "nested_confirmation": finishAck()
    var message: array[32, uint8]
    storeU16(addr message[0], IpcE2aMsgIdOff, MM_RESET_CFM)
    when TestCase == "nested_distinct_message":
      discard cmdMgrMsgind(H(), addr message[0], cast[pointer](distinctMessage))
      doAssert callbackCalls == 2, "distinct nested confirmation was dropped"
    else:
      discard cmdMgrMsgind(H(), addr message[0], cast[pointer](nested))
      doAssert callbackCalls == 1
      when TestCase == "nested_same_message":
        doAssert liveAllocations() == 1
        finishCfm()
    checkReleased()
  elif TestCase == "stale_ack":
    doAssert request() == 0
    let command = loadPtr(E(), EnvMsgA2eHostidOff)
    finishAck()
    discard cmdMgrLlind(H(), command)
    checkReleased()
  elif TestCase == "event_failure":
    eventFailure = true
    doAssert request(false) == -Enomem
    doAssert publications == 0
    eventFailure = false
    checkReleased()
  elif TestCase == "deferred_failure":
    doAssert request() == 0
    onAck = proc() = storePtr(E(), EnvSharedOff, nil)
    onWait = proc() = finishAck()
    doAssert request(false, true) < 0, "deferred push failure reported success"
    checkReleased()
    doAssert loadU32(H(), MgrStateOff) == RwnxCmdMgrStateCrashed
    doAssert not wifiCmdMgrRecoverIfCrashed(H())
    storePtr(E(), EnvSharedOff, S())
    doAssert wifiCmdMgrRecoverIfCrashed(H())
  elif TestCase == "init_pending":
    doAssert request() == 0
    bl_cmd_mgr_init(H())
    checkPending()
  elif TestCase == "zero_capacity":
    storeU32(H(), MgrMaxQueueSzOff, 0)
    doAssert request() == -Enomem
    doAssert publications == 0
    checkReleased()
  elif TestCase == "drain_reentry":
    doAssert request() == 0
    doAssert request() == 0
    onCommandFree = proc() =
      doAssert not wifiCmdMgrRecoverIfCrashed(H())
      doAssert request() == -Epipe, "queue reopened during drain"
    cmdMgrDrain(H())
    checkPending()
  doAssert mutexDepth == 0 and enabled == state
  for allocation in allocations: dealloc(allocation.memory)
"""


def program(case: str, mutation: str | None = None) -> str:
    source = submission_program("unused").split('\nconst TestCase = "', 1)[0]
    source += SUBMISSION_CHECKS.split("for state in [false, true]:", 1)[0]
    source = source.replace("var\n  allocations:", "var\n  onWait, onAck, onCommandFree, onEventDelete: proc()\n  forceTimeout, eventFailure: bool\n  callbackCalls, callbackReturn: cint\n  reply: array[16, uint8]\n  allocations:", 1)
    source = source.replace(procedure(source, "eventWait"), ADAPTER)
    source = source.replace("proc eventCreate(): pointer {.cdecl.} = osMalloc(4)",
                            "proc eventCreate(): pointer {.cdecl.} =\n  if eventFailure: nil else: osMalloc(4)")
    source = source.replace("        inc commandFrees\n", "        inc commandFrees\n        if onCommandFree != nil:\n          let action = onCommandFree\n          onCommandFree = nil\n          action()\n")
    source = source.replace("proc eventDelete(event: pointer) {.cdecl.} = freeMemory(event)",
                            "proc eventDelete(event: pointer) {.cdecl.} =\n  freeMemory(event)\n  if onEventDelete != nil:\n    let action = onEventDelete\n    onEventDelete = nil\n    action()")
    init = procedure((WIFI / "cmds.nim").read_text(), "bl_cmd_mgr_init")
    # The submission harness omits the unused exported print/drain table slots.
    normalized_init = init.replace("  storePtr(cmdMgr, MgrPrintOff, cast[pointer](cmdMgrPrint))\n", "").replace(
        "  storePtr(cmdMgr, MgrDrainOff, cast[pointer](cmdMgrDrain))\n", "")
    start = source.index(normalized_init) + len(normalized_init)
    recovery = "\n" + procedure(
        (WIFI / "cmds.nim").read_text(), "wifiCmdMgrRecoverIfCrashed")
    source = source[:start] + recovery + source[start:]
    if mutation:
        replacements = {
            "length": [("  if loadU32(source, LmacMsgParamLenOff) > CmdMaxParamLen: return Emsgsize\n", "")],
            "retention": [("  let pending = cmdMailboxOwner(cmdMgr) == cmd\n", "  let pending = false\n")],
            "result": [("  let completionError = loadI32(cmd, CmdResultOff)\n", "  let completionError = 0'i32\n")],
            "reply": [("  if error != 0: storePtr(cmd, CmdE2aMsgOff, nil)\n", "")],
            "event": [("  storePtr(cmd, CmdCompleteOff, nil)\n", "")],
            "pin": [("      storeU16(cmd, CmdFlagsOff, loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagCallback)\n", "")],
            "nested": [("    if frame.manager == cmdMgr and frame.message == msg:\n      cmdMgrUnlock(cmdMgr)\n      return 0\n", "")],
            "source": [("  storePtr(cmd, CmdA2eMsgOff, nil)\n", "")],
            "ack": [("  if cmdIsQueued(cmdMgr, cmd):\n", "  discard loadU32(cmd, CmdTknOff)\n  if cmdIsQueued(cmdMgr, cmd):\n")],
            "drain": [("  storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateDraining)\n", "")],
            "recovery": [(" or\n      not listEmpty(ptrAt(cmdMgr, MgrCmdsOff))", ""),
                         (" or\n      cmdMailboxOwner(cmdMgr) != nil", "")],
        }[mutation]
        for before, after in replacements:
            assert before in source, (mutation, before)
            source = source.replace(before, after)
    return (source + f'\nconst TestCase = "{case}"\n' + CHECKS).replace(
        "  discard cmdMgrLlind(context, owner)\n", "  if onAck != nil:\n    let action = onAck\n    onAck = nil\n    action()\n  discard cmdMgrLlind(context, owner)\n")


CASES = ["oversize", "truncated", "nil_source", "limit", "busy", "busy_blocking",
         "timeout_ack", "timeout_cfm", "timeout_deferred", "timeout_batch", "drain_wait",
         "drain_pending", "callback_drain", "callback_decline", "stale_ack", "event_failure",
         "deferred_failure", "init_pending", "timeout_cfm_buffer", "late_event_delete",
         "zero_capacity", "drain_reentry", "nested_confirmation", "callback_drain_pending", "callback_reinit",
         "nested_same_message", "nested_distinct_message"]
MUTANTS = {"length": "oversize", "retention": "timeout_ack", "result": "timeout_ack",
           "reply": "timeout_cfm_buffer", "event": "timeout_ack", "pin": "callback_drain",
           "source": "limit", "ack": "stale_ack", "drain": "drain_reentry",
           "recovery": "timeout_ack", "nested": "nested_confirmation"}


def run(tmp_path: Path, case: str, mode: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    path = tmp_path / "cmd_lifecycle.nim"
    path.write_text(program(case, mutation))
    flags = {"checked": [], "release": ["-d:release"], "trace": ["-d:bl808WifiCmdTrace"],
             "asan": ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
                             *flags, "--checks:on", f"--nimcache:{tmp_path / 'cache'}",
                             f"-o:{tmp_path / 'test'}", str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation is None: assert result.returncode == 0, result.stdout
    else: assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "trace", "asan"])
def test_cmd_lifecycle(tmp_path: Path, case: str, mode: str) -> None:
    run(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTANTS)
def test_cmd_lifecycle_guard(tmp_path: Path, mutation: str) -> None:
    run(tmp_path, MUTANTS[mutation], "checked", mutation)
