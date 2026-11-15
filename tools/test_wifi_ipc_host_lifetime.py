"""Exercise host IPC dispatch, list operations, and allocation on native Nim."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

HOST = ROOT / "src/bl808/wifi/ipc_host"

PLATFORM = r"""
const Scale = sizeof(pointer).uint div 4
var
  envA, envB: array[IpcHostEnvSize.int * 2 + 32, uint8]
  poolA, poolB: array[SharedEnvSize.int * 2 + 32, uint8]
  callbackTable: array[8, pointer]
  enabled = true
  onAccess: proc(base: pointer; offset: uint; write: bool)
  onSave: proc()
  pendingIrq: proc()
  onCfm: proc(pthis, hostId: pointer)
  onAck, onDebug, onTbtt: proc()
  seen: seq[uint]
  seenContexts: seq[uint]
  ackCalls, debugCalls, tbttCalls, alternateCalls: int
  debugReturn: uint8
  incoming: bool
proc ptrAt(base: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](base) + offset * Scale)
proc interrupt(callback: proc()) =
  if enabled: callback()
  else: pendingIrq = callback
proc ipcHostIrqSave(): uint32 =
  if enabled and onSave != nil:
    let callback = onSave
    onSave = nil
    callback()
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc ipcHostIrqRestore(state: uint32) =
  enabled = (state and 8) != 0
  if enabled and pendingIrq != nil:
    let callback = pendingIrq
    pendingIrq = nil
    callback()
proc loadPtr(base: pointer; offset: uint): pointer =
  result = cast[ptr pointer](ptrAt(base, offset))[]
  if onAccess != nil: onAccess(base, offset, false)
proc storePtr(base: pointer; offset: uint; value: pointer) =
  cast[ptr pointer](ptrAt(base, offset))[] = value
  if onAccess != nil: onAccess(base, offset, true)
proc loadU32(base: pointer; offset: uint): uint32 =
  result = cast[ptr uint32](ptrAt(base, offset))[]
  if onAccess != nil: onAccess(base, offset, false)
proc storeU32(base: pointer; offset: uint; value: uint32) =
  cast[ptr uint32](ptrAt(base, offset))[] = value
  if onAccess != nil: onAccess(base, offset, true)
proc loadU8(base: pointer; offset: uint): uint8 =
  cast[ptr uint8](ptrAt(base, offset))[]
proc storeU8(base: pointer; offset: uint; value: uint8) =
  cast[ptr uint8](ptrAt(base, offset))[] = value
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, size.int * Scale.int)
  dst
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int * Scale.int)
  dst
proc regRead(address: uint): uint32 = 0
proc regWrite(address: uint; value: uint32) = discard
"""

CHECKS = r"""
proc confirmed(pthis, hostId: pointer): cint {.cdecl.} =
  doAssert enabled == incoming, "callback IRQ state changed"
  seen.add(cast[uint](hostId))
  seenContexts.add(cast[uint](pthis))
  if onCfm != nil: onCfm(pthis, hostId)
  0
proc alternate(pthis, hostId: pointer): cint {.cdecl.} =
  inc alternateCalls
  0
proc acknowledged(pthis, hostId: pointer): uint8 {.cdecl.} =
  doAssert enabled == incoming
  inc ackCalls
  if onAck != nil: onAck()
  1
proc debugged(pthis, hostId: pointer): uint8 {.cdecl.} =
  doAssert enabled == incoming
  inc debugCalls
  result = debugReturn
  if onDebug != nil: onDebug()
proc tbtt(pthis: pointer) {.cdecl.} =
  doAssert enabled == incoming
  inc tbttCalls
  if onTbtt != nil: onTbtt()
proc E(): pointer = addr envA[0]
proc F(): pointer = addr envB[0]
proc P(): pointer = addr poolA[0]
proc Q(): pointer = addr poolB[0]
proc node(pool: pointer; index: uint): pointer =
  ptrAt(pool, SharedTxdesc0Off + index * SharedTxdescHostSize)
proc queue(env: pointer; offset: uint): pointer = loadPtr(env, offset)
proc length(list: pointer): int =
  var current = loadPtr(list, 0)
  var last: pointer
  while current != nil:
    inc result
    doAssert result <= NxTxDescCnt.int, "list cycle or duplicate ownership"
    last = current
    current = loadPtr(current, 0)
  doAssert loadPtr(list, 4) == last, "orphan list tail"
proc setup() =
  onAccess = nil
  onSave = nil
  pendingIrq = nil
  onCfm = nil
  onAck = nil
  onDebug = nil
  onTbtt = nil
  enabled = true
  incoming = true
  seen.setLen(0)
  seenContexts.setLen(0)
  ackCalls = 0
  debugCalls = 0
  debugReturn = 1
  tbttCalls = 0
  alternateCalls = 0
  envA = default(typeof(envA))
  envB = default(typeof(envB))
  poolA = default(typeof(poolA))
  poolB = default(typeof(poolB))
  for i in IpcHostEnvSize.int * 2 ..< envA.len:
    envA[i] = 0xA5
    envB[i] = 0xA5
  for i in SharedEnvSize.int * 2 ..< poolA.len:
    poolA[i] = 0xA5
    poolB[i] = 0xA5
  callbackTable = default(typeof(callbackTable))
  callbackTable[0] = cast[pointer](confirmed)
  callbackTable[4] = cast[pointer](acknowledged)
  callbackTable[5] = cast[pointer](debugged)
  callbackTable[6] = cast[pointer](tbtt)
  callbackTable[7] = cast[pointer](tbtt)
  ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xA0))
  ipc_host_init(F(), addr callbackTable[0], Q(), cast[pointer](0xB0))
  when declared(ipcHostActiveDispatch): doAssert ipcHostActiveDispatch == nil
proc complete(env: pointer; count: int) =
  for index in 1 .. count:
    let entry = listPopFront(queue(env, EnvListFreeOff))
    doAssert entry != nil
    storePtr(entry, TxdescHostHostIdOff, cast[pointer](index))
    listPushBack(queue(env, EnvListCfmOff), entry)
proc submit(env: pointer; hostId: uint): pointer =
  result = ipc_host_txdesc_get(env)
  doAssert result != nil
  ipc_host_txdesc_push(env, cast[pointer](hostId))
  doAssert loadPtr(result, TxdescHostHostIdOff) == cast[pointer](hostId)
proc dispatch(env: pointer; extra = 0'u32) =
  ipc_host_irq(env, (1'u32 shl IpcIrqE2aTxCfmPos) or extra)
proc checkPartition(env, pool: pointer) =
  var visited: seq[pointer]
  for offset in [EnvListFreeOff, EnvListOngoingOff, EnvListCfmOff]:
    let list = queue(env, offset)
    discard length(list)
    var entry = loadPtr(list, 0)
    while entry != nil:
      doAssert entry notin visited, "descriptor has multiple owners"
      visited.add(entry)
      entry = loadPtr(entry, 0)
  doAssert visited.len == NxTxDescCnt.int
  for i in 0'u ..< NxTxDescCnt.uint:
    doAssert node(pool, i) in visited

for initialIrq in [false, true]:
  setup()
  when TestCase == "pre_pop":
    if not initialIrq: continue
  complete(E(), if TestCase in ["after_pop", "snapshot", "submit_atomic"]: 1 else: 2)
  enabled = initialIrq
  incoming = initialIrq
  when TestCase == "nested":
    onCfm = proc(pthis, hostId: pointer) =
      if cast[uint](hostId) == 1: dispatch(E())
    dispatch(E())
    doAssert seen == @[1'u, 2'u]
    doAssert length(queue(E(), EnvListFreeOff)) == 4
    checkPartition(E(), P())
  elif TestCase in ["reinit", "new_pool", "shared_pool", "aba", "nested_reset"]:
    var replacement: pointer
    let targetEnv = if TestCase == "shared_pool": F() else: E()
    let targetPool = if TestCase == "new_pool": Q() else: P()
    var reset = false
    onCfm = proc(pthis, hostId: pointer) =
      if TestCase == "nested_reset" and cast[uint](hostId) == 1:
        dispatch(E())
        return
      if reset: return
      reset = true
      ipc_host_init(targetEnv, addr callbackTable[0], targetPool, cast[pointer](0xCC))
      if TestCase == "aba":
        ipc_host_init(targetEnv, addr callbackTable[0], Q(), cast[pointer](0xDD))
        ipc_host_init(targetEnv, addr callbackTable[0], targetPool, cast[pointer](0xCC))
      replacement = submit(targetEnv, 0x99)
    dispatch(E(), IpcIrqE2aMsgAck or IpcIrqE2aTbttPrim or IpcIrqE2aTbttSec)
    doAssert reset
    doAssert loadPtr(replacement, TxdescHostHostIdOff) == cast[pointer](0x99),
      "old dispatch cleared a replacement host ID"
    doAssert length(queue(targetEnv, EnvListFreeOff)) == 3,
      "old dispatch returned a live descriptor to the free list"
    doAssert length(queue(targetEnv, EnvListOngoingOff)) == 1
    doAssert seen == (if TestCase == "nested_reset": @[1'u, 2'u] else: @[1'u])
    doAssert ackCalls == 0 and tbttCalls == 0,
      "old status bits called replacement callbacks"
    checkPartition(targetEnv, targetPool)
  elif TestCase == "independent":
    onCfm = proc(pthis, hostId: pointer) =
      if cast[uint](hostId) == 1:
        ipc_host_init(F(), addr callbackTable[0], Q(), cast[pointer](0xDD))
    dispatch(E())
    doAssert seen == @[1'u, 2'u]
    doAssert length(queue(E(), EnvListFreeOff)) == 4
    checkPartition(E(), P())
    checkPartition(F(), Q())
  elif TestCase in ["ack_reset", "debug_reset", "tbtt_reset"]:
    let restart = proc() =
      onAck = nil
      onDebug = nil
      onTbtt = nil
      debugReturn = 1
      ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
      storePtr(E(), EnvMsgA2eHostidOff, cast[pointer](0xEE))
    when TestCase == "ack_reset":
      storePtr(E(), EnvMsgA2eHostidOff, cast[pointer](0xDD))
      onAck = restart
      ipc_host_irq(E(), IpcIrqE2aMsgAck or IpcIrqE2aTbttPrim or IpcIrqE2aTbttSec)
      doAssert ackCalls == 1 and tbttCalls == 0
    elif TestCase == "debug_reset":
      storePtr(E(), EnvDbgArrayOff, cast[pointer](0xDD))
      debugReturn = 0
      onDebug = restart
      ipc_host_irq(E(), IpcIrqE2aDbg or IpcIrqE2aTbttPrim or IpcIrqE2aTbttSec)
      doAssert debugCalls == 1 and tbttCalls == 0
    else:
      onTbtt = restart
      ipc_host_irq(E(), IpcIrqE2aTbttPrim or IpcIrqE2aTbttSec)
      doAssert tbttCalls == 1
    doAssert loadPtr(E(), EnvMsgA2eHostidOff) == cast[pointer](0xEE)
    checkPartition(E(), P())
  elif TestCase == "pre_pop":
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == E() and offset == EnvSharedOff and not write:
        onAccess = nil
        onSave = proc() =
          ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
          complete(E(), 1)
          storePtr(node(P(), 0), TxdescHostHostIdOff, cast[pointer](0x99))
    dispatch(E())
    doAssert seen.len == 0
    doAssert length(queue(E(), EnvListCfmOff)) == 1,
      "retired consumer removed a replacement completion"
    doAssert loadPtr(node(P(), 0), TxdescHostHostIdOff) == cast[pointer](0x99)
    checkPartition(E(), P())
  elif TestCase in ["after_pop", "snapshot"]:
    # A pending interrupt is delivered after the final queued node is detached.
    let cfm = queue(E(), EnvListCfmOff)
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == cfm and offset == 0 and write:
        onAccess = nil
        interrupt(proc() =
          if TestCase == "after_pop":
            ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
            discard submit(E(), 0x99)
          else:
            storePtr(E(), 0, cast[pointer](alternate))
            storePtr(E(), EnvPthisOff, cast[pointer](0xCC)))
    dispatch(E())
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq and pendingIrq != nil: ipcHostIrqRestore(8)
    if initialIrq:
      if TestCase == "after_pop":
        doAssert seen.len == 0, "retired completion callback still ran"
        doAssert loadPtr(node(P(), 0), TxdescHostHostIdOff) == cast[pointer](0x99)
      else:
        doAssert alternateCalls == 0 and seen == @[1'u]
        doAssert seenContexts == @[0xA0'u], "callback context was rebound"
  elif TestCase == "init_atomic":
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == E() and offset == EnvSharedOff and write:
        onAccess = nil
        interrupt(proc() =
          doAssert queue(E(), EnvListFreeOff) != nil
          checkPartition(E(), P())
          doAssert loadPtr(E(), EnvPthisOff) == cast[pointer](0xCC),
            "interrupt observed a partially initialized IPC environment")
    ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC))
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq: ipcHostIrqRestore(8)
  elif TestCase == "submit_atomic":
    # An init during free-list removal must wait until publication is complete.
    listInit(queue(E(), EnvListCfmOff))
    for i in 0'u ..< NxTxDescCnt.uint: storePtr(node(P(), i), TxdescHostHostIdOff, nil)
    let free = queue(E(), EnvListFreeOff)
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == free and offset == 0 and write:
        onAccess = nil
        interrupt(proc() = ipc_host_init(E(), addr callbackTable[0], P(), cast[pointer](0xCC)))
    ipc_host_txdesc_push(E(), cast[pointer](0x99))
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq: ipcHostIrqRestore(8)
    doAssert length(queue(E(), EnvListFreeOff)) == 4
    doAssert length(queue(E(), EnvListOngoingOff)) == 0
    checkPartition(E(), P())
  elif TestCase == "pop":
    onCfm = nil
    let list = queue(E(), EnvListCfmOff)
    let first = loadPtr(list, 0)
    let added = listPopFront(queue(E(), EnvListFreeOff))
    # Use a one-element queue so a producer can expose the cached-next window.
    let second = loadPtr(first, 0)
    storePtr(first, 0, nil)
    storePtr(list, 4, first)
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == first and offset == 0 and not write:
        onAccess = nil
        interrupt(proc() = listPushBack(list, added))
    doAssert listPopFront(list) == first
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq: ipcHostIrqRestore(8)
    doAssert loadPtr(list, 0) == added and length(list) == 1,
      "interrupted pop lost an appended descriptor"
    discard second
  elif TestCase == "push":
    onCfm = nil
    let list = queue(E(), EnvListCfmOff)
    let entry = node(P(), 0)
    listInit(list)
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == list and offset == 0 and write:
        onAccess = nil
        interrupt(proc() = discard listPopFront(list))
    listPushBack(list, entry)
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq: ipcHostIrqRestore(8)
    doAssert length(list) == 0, "interrupted append left an orphan tail"
  elif TestCase == "txbuf":
    let first = ptrAt(P(), SharedTxbufOff)
    var nested: pointer
    onAccess = proc(base: pointer; offset: uint; write: bool) =
      if base == first and offset == 0 and not write:
        onAccess = nil
        interrupt(proc() = nested = ipc_host_txbuf_get(E()))
    let outer = ipc_host_txbuf_get(E())
    doAssert enabled == initialIrq
    onAccess = nil
    if not initialIrq: ipcHostIrqRestore(8)
    doAssert outer != nil and nested != nil and outer != nested,
      "buffer reservation issued the same slot twice"
  else:
    {.error: "Unknown test case".}
  if TestCase notin ["pop", "push", "txbuf", "after_pop", "snapshot", "init_atomic", "submit_atomic"]:
    doAssert enabled == initialIrq
  for i in IpcHostEnvSize.int * 2 ..< envA.len:
    doAssert envA[i] == 0xA5 and envB[i] == 0xA5
  for i in SharedEnvSize.int * 2 ..< poolA.len:
    doAssert poolA[i] == 0xA5 and poolB[i] == 0xA5
  enabled = initialIrq
  doAssert pendingIrq == nil
  when declared(ipcHostActiveDispatch): doAssert ipcHostActiveDispatch == nil
"""


def program(case: str, mutation: str | None) -> str:
    layout = (HOST / "layout.nim").read_text()
    types = (HOST / "callback_types.nim").read_text()
    runtime = HOST / "runtime.nim"
    runtime_types = runtime.read_text().split("template ipcHostIrqSave", 1)[0] if runtime.exists() else ""
    helpers = "\n".join(procedure(runtime.read_text(), name) for name in [
        "beginIpcHostDispatch", "endIpcHostDispatch", "ipcHostDispatchCurrent",
        "ipcHostInvalidate"]) if runtime.exists() else ""
    sources = {name: (HOST / name).read_text() for name in [
        "list_helpers.nim", "callbacks.nim", "init.nim", "tx_shared.nim", "irq.nim"]}
    if mutation:
        file, name = {
            "invalidate": ("init.nim", "ipc_host_init"),
            "pop_lock": ("list_helpers.nim", "listPopFront"),
            "push_lock": ("list_helpers.nim", "listPushBack"),
            "txbuf_lock": ("tx_shared.nim", "ipc_host_txbuf_get"),
            "dispatch_guard": ("irq.nim", "ipc_host_irq"),
            "completion_guard": ("irq.nim", "ipcHostTxCfmHandler"),
            "callback_snapshot": ("irq.nim", "ipcHostTxCfmHandler"),
            "init_lock": ("init.nim", "ipc_host_init"),
            "submit_lock": ("tx_shared.nim", "ipc_host_txdesc_push"),
            "ancestors": ("runtime", "ipcHostInvalidate"),
            "pre_pop_guard": ("irq.nim", "ipcHostTxCfmHandler"),
            "ack_guard": ("irq.nim", "ipc_host_irq"),
            "debug_guard": ("irq.nim", "ipc_host_irq"),
            "tbtt_guard": ("irq.nim", "ipc_host_irq"),
            "debug_loop": ("irq.nim", "ipcHostDbgHandler"),
        }[mutation]
        if mutation == "ancestors":
            assert "    scope = scope.previous\n" in helpers
            helpers = helpers.replace("    scope = scope.previous\n", "    scope = nil\n")
            file = "init.nim"
            name = "ipc_host_init"
        body = procedure(sources[file], name)
        if mutation == "invalidate":
            target = "  ipcHostInvalidate(env, sharedEnv)\n"
            assert target in body
            changed = body.replace(target, "")
        elif mutation == "dispatch_guard":
            target = "    if scope.cancelled: return\n"
            assert target in body
            changed = body.replace(target, "")
        elif mutation == "completion_guard":
            target = "      if scope.cancelled: return\n"
            assert body.count(target) == 2
            before, after = body.rsplit(target, 1)
            changed = before + after
        elif mutation == "pre_pop_guard":
            target = "      if scope.cancelled: return\n"
            assert body.count(target) == 2
            changed = body.replace(target, "", 1)
        elif mutation == "callback_snapshot":
            target = "      discard completion.callback(completion.context, completion.hostId)\n"
            assert target in body
            changed = body.replace(target, "      callSendDataCfm(env, completion.hostId)\n")
        elif mutation in {"ack_guard", "debug_guard", "tbtt_guard"}:
            call = {"ack_guard": "ipcHostMsgAckHandler(env, addr scope)",
                    "debug_guard": "ipcHostDbgHandler(env, addr scope)",
                    "tbtt_guard": "callTbtt(env, 24)"}[mutation]
            target = f"    {call}\n    if scope.cancelled: return\n"
            assert target in body
            changed = body.replace(target, f"    {call}\n")
        elif mutation == "debug_loop":
            assert "while not scope.cancelled:" in body
            assert "if scope.cancelled or status != 0'u8:" in body
            changed = body.replace("while not scope.cancelled:", "while true:").replace(
                "if scope.cancelled or status != 0'u8:", "if status != 0'u8:")
        elif mutation == "ancestors":
            changed = body
        else:
            target = "  let saved = ipcHostIrqSave()\n"
            assert target in body
            changed = body.replace(target, "  let saved = 0'u32\n", 1)
        sources[file] = sources[file].replace(body, changed)
    joined = "\n".join(sources.values())
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", joined)))
    )
    return (layout + types + runtime_types + PLATFORM + helpers + debug + joined
            + f'\nconst TestCase = "{case}"\n' + CHECKS)


CASES = ["nested", "reinit", "new_pool", "shared_pool", "aba", "nested_reset",
         "independent", "pop", "push", "txbuf", "after_pop", "snapshot",
         "init_atomic", "submit_atomic", "pre_pop", "ack_reset", "debug_reset", "tbtt_reset"]
MUTANTS = {"invalidate": "reinit", "pop_lock": "pop", "push_lock": "push",
           "txbuf_lock": "txbuf", "dispatch_guard": "reinit",
           "completion_guard": "reinit", "callback_snapshot": "snapshot",
           "init_lock": "init_atomic", "submit_lock": "submit_atomic",
           "ancestors": "nested_reset", "pre_pop_guard": "pre_pop",
           "ack_guard": "ack_reset", "debug_guard": "debug_reset",
           "tbtt_guard": "tbtt_reset", "debug_loop": "debug_reset"}


def run(tmp_path: Path, case: str, mode: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "ipc_host_lifetime.nim"
    path.write_text(program(case, mutation))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ipc_host_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTANTS)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ipc_host_lifetime_guards(tmp_path: Path, mutation: str, mode: str) -> None:
    run(tmp_path, MUTANTS[mutation], mode, mutation)
