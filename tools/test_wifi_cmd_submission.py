"""Exercise command ownership across the real mailbox and ACK handoff."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

WIFI = ROOT / "src/bl808/wifi"
CMDS = WIFI / "cmds"

PLATFORM = r"""
const Scale = sizeof(pointer).uint div 4
type
  BlHw = object
  RecvInd = proc(context, hostId: pointer): uint8 {.cdecl.}
  Allocation = object
    memory: pointer
    size: uint
    released: bool
var
  allocations: seq[Allocation]
  hw: array[512, uint8]
  env: array[320, uint8]
  shared: array[1100, uint8]
  operations: array[64, pointer]
  enabled = true
  incoming = true
  mutexDepth: int
  mutexSaved: uint32
  pending: proc()
  onPublish, onSourceFree: proc()
  waitCalls, publications, sourceFrees, commandFrees: int
  failAllocation: bool
  nimFwDbgIpcMsgAckMismatch: uint32
proc H(): pointer = addr hw[0]
proc E(): pointer = addr env[0]
proc S(): pointer = addr shared[0]
proc checkAccess(base: pointer) =
  for allocation in allocations:
    let offset = cast[uint](base) - cast[uint](allocation.memory)
    if offset < allocation.size * Scale:
      doAssert not allocation.released, "command access after completion"
proc ptrAt(base: pointer; offset: uint): pointer =
  checkAccess(base)
  cast[pointer](cast[uint](base) + offset * Scale)
proc opPtr(offset: uint): pointer = operations[offset div 4]
proc osMalloc(size: uint): pointer =
  if failAllocation: return nil
  result = alloc0((size * Scale).int)
  allocations.add(Allocation(memory: result, size: size))
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  checkAccess(dst)
  checkAccess(src)
  copyMem(dst, src, size.int * Scale.int)
  dst
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  checkAccess(dst)
  zeroMem(dst, size.int * Scale.int)
  dst
proc zero(dst: pointer; size: uint) = discard c_memset(dst, 0, size.csize_t)
proc c_printf(fmt: cstring): cint
  {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}
proc bl_os_printf(fmt: cstring)
  {.importc: "printf", header: "<stdio.h>", cdecl, varargs.}
proc interrupt(action: proc()) =
  if enabled: action()
  else:
    doAssert pending == nil
    pending = action
proc ipcHostIrqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc ipcHostIrqRestore(state: uint32) =
  enabled = (state and 8) != 0
  if enabled and pending != nil:
    let action = pending
    pending = nil
    action()
proc regRead(address: uint): uint32 = 0
proc regWrite(address: uint; value: uint32) =
  if address == IpcApp2EmbTrigger and value == IpcIrqA2eMsg:
    inc publications
    if onPublish != nil:
      let action = onPublish
      onPublish = nil
      interrupt(action)
proc roundUp4(value: uint32): uint32 = (value + 3) and not 3'u32
proc mutexCreate(): pointer {.cdecl.} = cast[pointer](1)
proc mutexLock(mutex: pointer): int32 {.cdecl.} =
  if mutexDepth == 0: mutexSaved = ipcHostIrqSave()
  inc mutexDepth
  0
proc mutexUnlock(mutex: pointer): int32 {.cdecl.} =
  dec mutexDepth
  doAssert mutexDepth >= 0
  if mutexDepth == 0: ipcHostIrqRestore(mutexSaved)
  0
"""

ADAPTER = r"""
proc freeMemory(memory: pointer) {.cdecl.} =
  if memory == nil: return
  var found = false
  for allocation in allocations.mitems:
    if allocation.memory == memory:
      doAssert not allocation.released, "allocation released twice"
      allocation.released = true
      found = true
      if allocation.size == BlCmdSize:
        inc commandFrees
      elif allocation.size == 12:
        inc sourceFrees
        if onSourceFree != nil:
          let action = onSourceFree
          onSourceFree = nil
          action()
      break
  doAssert found, "released an unknown allocation"
proc eventCreate(): pointer {.cdecl.} = osMalloc(4)
proc eventDelete(event: pointer) {.cdecl.} = freeMemory(event)
proc eventSend(event: pointer; bits: uint32): uint32 {.cdecl.} =
  result = loadU32(event, 0) or bits
  storeU32(event, 0, result)
proc finishAck()
proc finishCfm()
proc eventWait(event: pointer; bits: uint32; clear, all: cint;
               ticks: uint32): uint32 {.cdecl.} =
  inc waitCalls
  finishAck()
  finishCfm()
  result = loadU32(event, 0) and bits
  doAssert result == 1
proc envCb(env: pointer; offset: uint): pointer = loadPtr(env, offset)
"""

CHECKS = r"""
proc acknowledge(context, owner: pointer): uint8 {.cdecl.} =
  doAssert context == H()
  discard cmdMgrLlind(context, owner)
  0
proc finishAck() =
  if loadPtr(E(), EnvMsgA2eHostidOff) == nil: return
  storeU8(S(), SharedMsgBodyOff + LmacMsgSrcIdOff, loadU8(E(), EnvMsgA2eCntOff))
  var scope: IpcHostDispatchScope
  doAssert beginIpcHostDispatch(scope, E())
  ipcHostMsgAckHandler(E(), addr scope)
  endIpcHostDispatch(scope)
proc finishCfm() =
  var msg: array[32, uint8]
  storeU16(addr msg[0], IpcE2aMsgIdOff, MM_RESET_CFM)
  discard cmdMgrMsgind(H(), addr msg[0], nil)
proc request(nonblock = true; confirmation = false): cint =
  let source = osMalloc(12)
  storeU16(source, LmacMsgIdOff, if nonblock: MM_TIM_UPDATE_REQ else: MM_RESET_REQ)
  storeU32(source, LmacMsgParamLenOff, 4)
  let param = ptrAt(source, LmacMsgParamOff)
  blSendMsg(cast[ptr BlHw](H()), param, confirmation.cint, MM_RESET_CFM, nil)
proc liveAllocations(): int =
  for allocation in allocations:
    if not allocation.released: inc result
proc install(state: bool) =
  allocations.setLen(0)
  hw = default(typeof(hw))
  env = default(typeof(env))
  shared = default(typeof(shared))
  operations[OpFreeOff div 4] = cast[pointer](freeMemory)
  operations[OpMutexCreateOff div 4] = cast[pointer](mutexCreate)
  operations[OpMutexLockOff div 4] = cast[pointer](mutexLock)
  operations[OpMutexUnlockOff div 4] = cast[pointer](mutexUnlock)
  operations[OpEventGroupCreateOff div 4] = cast[pointer](eventCreate)
  operations[OpEventGroupDeleteOff div 4] = cast[pointer](eventDelete)
  operations[OpEventGroupSendOff div 4] = cast[pointer](eventSend)
  operations[OpEventGroupWaitOff div 4] = cast[pointer](eventWait)
  enabled = state
  incoming = state
  mutexDepth = 0
  pending = nil
  onPublish = nil
  onSourceFree = nil
  waitCalls = 0
  sourceFrees = 0
  commandFrees = 0
  publications = 0
  failAllocation = false
  bl_cmd_mgr_init(H())
  storePtr(H(), BlHwIpcEnvOff, E())
  storePtr(E(), EnvSharedOff, S())
  storePtr(E(), EnvPthisOff, H())
  storePtr(E(), 16, cast[pointer](acknowledge))
proc flushInterrupts() =
  ipcHostIrqRestore(8)
  enabled = incoming
for state in [false, true]:
  install(state)
  when TestCase == "immediate_ack":
    onPublish = proc() = finishAck()
    doAssert request() == 0
    flushInterrupts()
  elif TestCase == "immediate_cfm":
    onPublish = proc() =
      finishCfm()
      finishAck()
    doAssert request(confirmation = true) == 0
    flushInterrupts()
  elif TestCase == "immediate_blocking":
    onPublish = proc() = finishAck()
    doAssert request(false) == 0
    flushInterrupts()
    doAssert waitCalls == 1
  elif TestCase == "accepted_result":
    onPublish = proc() =
      doAssert loadI32(loadPtr(E(), EnvMsgA2eHostidOff), CmdResultOff) == 0
    doAssert request() == 0
    flushInterrupts()
    finishAck()
  elif TestCase == "source_free_ack":
    onSourceFree = proc() = finishAck()
    doAssert request() == 0
  elif TestCase == "normal":
    doAssert request() == 0
    doAssert liveAllocations() == 1 and commandFrees == 0
    finishAck()
  elif TestCase == "deferred":
    doAssert request() == 0
    doAssert request() == 0
    doAssert publications == 1 and sourceFrees == 1
    finishAck()
    doAssert publications == 2 and sourceFrees == 2
    finishAck()
  elif TestCase == "deferred_immediate":
    doAssert request() == 0
    doAssert request() == 0
    onPublish = proc() = finishAck()
    finishAck()
    flushInterrupts()
  elif TestCase in ["cfm_first", "ack_first"]:
    doAssert request(confirmation = true) == 0
    when TestCase == "cfm_first": finishCfm()
    else: finishAck()
    doAssert commandFrees == 0 and liveAllocations() == 1
    when TestCase == "cfm_first": finishAck()
    else: finishCfm()
  elif TestCase in ["blocking", "blocking_cfm"]:
    doAssert request(false, TestCase == "blocking_cfm") == 0
    doAssert waitCalls == 1
  elif TestCase in ["rejected_crashed", "rejected_blocking"]:
    storeU32(H(), MgrStateOff, RwnxCmdMgrStateCrashed)
    doAssert request(TestCase != "rejected_blocking") == -Epipe
    doAssert publications == 0
  elif TestCase == "rejected_full":
    for index in 0 ..< RwnxCmdMaxQueued.int: doAssert request() == 0
    doAssert request() == -Enomem
    for index in 0 ..< RwnxCmdMaxQueued.int: finishAck()
  elif TestCase == "no_queue":
    storePtr(H(), MgrQueueOff, nil)
    doAssert request() == -Ebusy
  elif TestCase == "no_environment":
    storePtr(H(), BlHwIpcEnvOff, nil)
    doAssert request() == -Ebusy
  elif TestCase == "allocation_failure":
    let source = osMalloc(12)
    storeU16(source, LmacMsgIdOff, MM_TIM_UPDATE_REQ)
    failAllocation = true
    doAssert blSendMsg(cast[ptr BlHw](H()), ptrAt(source, 8), 0, 0, nil) == -Enomem
  doAssert liveAllocations() == 0, "submission left an allocation owned by nobody"
  doAssert mutexDepth == 0 and enabled == state, "submission changed incoming IRQ state"
  doAssert loadU32(H(), MgrQueueSzOff) == 0
  for allocation in allocations: dealloc(allocation.memory)
"""


def program(case: str, mutation: str | None = None) -> str:
    layout = f'import "{WIFI / "host_table_layout.nim"}"\n' + (CMDS / "layout.nim").read_text()
    known = set(re.findall(r"^  (\w+) =", layout, re.M))
    for path in [WIFI / "ipc_host/layout.nim", WIFI / "msg_tx/layout/host_cmd.nim"]:
        added = []
        selected = False
        for line in path.read_text().splitlines():
            match = re.match(r"  (\w+) =", line)
            if match:
                selected = match[1] not in known
                if selected: known.add(match[1])
            if selected and (match or line.startswith("    ")):
                added.append(line)
        layout += "\nconst\n" + "\n".join(added) + "\n"
    accessors = (CMDS / "accessors.nim").read_text()
    accessors = accessors[accessors.index("proc loadPtr"):]
    # Use native-sized pointer slots while retaining production field offsets.
    accessors += "\n" + procedure((WIFI / "msg_tx/accessors.nim").read_text(), "loadU8")
    accessors += "\n" + procedure((WIFI / "msg_tx/accessors.nim").read_text(), "storeU8")
    runtime = (WIFI / "ipc_host/runtime.nim").read_text()
    runtime = runtime[:runtime.index("template ipcHostIrqSave")] + runtime[runtime.index("proc beginIpcHostDispatch"):]
    enqueue = (CMDS / "queue_parts/enqueue.nim").read_text()
    lifecycle = (CMDS / "queue_parts/lifecycle.nim").read_text()
    send = procedure((WIFI / "msg_tx/core.nim").read_text(), "blSendMsg")
    if mutation == "queue_reread":
        target = "  if nonblock: return status\n"
        assert target in enqueue
        enqueue = enqueue.replace(target, "  if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagNonblock) != 0: return status\n")
    elif mutation == "late_result":
        target = "  storeI32(cmd, CmdResultOff, if nonblock: 0'i32 else: Eintr)"
        assert target in enqueue
        enqueue = enqueue.replace(target, "  storeI32(cmd, CmdResultOff, Eintr)")
        enqueue = enqueue.replace("  if nonblock: return status\n",
                                  "  if nonblock:\n    storeI32(cmd, CmdResultOff, 0)\n    return status\n")
    elif mutation == "caller_reread":
        target = "  queue(hw, cmd)\n"
        assert target in send
        send = send.replace(target, "  let status = queue(hw, cmd)\n  if nonblock: loadI32(cmd, BlCmdResultOff).cint else: status\n")
    elif mutation == "rejection_leak":
        body = procedure(lifecycle, "releaseOwnedCommand")
        target = "  if source != nil: osFree(source)\n"
        assert target in body
        lifecycle = lifecycle.replace(body, body.replace(target, ""))
    return (layout + (WIFI / "msg_tx/layout/message_ids.nim").read_text()
            + (CMDS / "types.nim").read_text() + PLATFORM + accessors
            + (CMDS / "list_helpers.nim").read_text() + ADAPTER
            + runtime + procedure((WIFI / "ipc_host/messages.nim").read_text(), "ipc_host_msg_push")
            + procedure((WIFI / "ipc_host/irq.nim").read_text(), "ipcHostMsgAckHandler")
            + (CMDS / "os_wrappers.nim").read_text()
            + lifecycle
            + (CMDS / "queue_parts/complete.nim").read_text()
            + (CMDS / "queue_parts/firmware_push.nim").read_text() + enqueue
            + (CMDS / "dispatch_parts/ack.nim").read_text()
            + (CMDS / "dispatch_parts/message.nim").read_text()
            + (CMDS / "dispatch_parts/print_drain.nim").read_text()
            + procedure((WIFI / "cmds.nim").read_text(), "bl_cmd_mgr_init").replace(
                "  storePtr(cmdMgr, MgrPrintOff, cast[pointer](cmdMgrPrint))\n", "").replace(
                "  storePtr(cmdMgr, MgrDrainOff, cast[pointer](cmdMgrDrain))\n", "")
            + procedure((WIFI / "msg_tx/core.nim").read_text(), "isNonBlockingMsg") + send
            + f'\nconst TestCase = "{case}"\n' + CHECKS)


CASES = ["immediate_ack", "immediate_cfm", "immediate_blocking", "accepted_result",
         "source_free_ack", "normal", "deferred", "deferred_immediate",
         "cfm_first", "ack_first", "blocking", "blocking_cfm", "rejected_crashed",
         "rejected_blocking", "rejected_full", "no_queue", "no_environment", "allocation_failure"]
MUTANTS = {"queue_reread": "immediate_ack", "late_result": "immediate_ack",
           "caller_reread": "immediate_ack", "rejection_leak": "rejected_crashed"}


def run(tmp_path: Path, case: str, mode: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = tmp_path / "cmd_submission.nim"
    source.write_text(program(case, mutation))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "trace": command += ["-d:bl808WifiCmdTrace"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "trace", "asan"])
def test_cmd_submission(tmp_path: Path, case: str, mode: str) -> None:
    run(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTANTS)
def test_cmd_submission_guard(tmp_path: Path, mutation: str) -> None:
    run(tmp_path, MUTANTS[mutation], "checked", mutation)
