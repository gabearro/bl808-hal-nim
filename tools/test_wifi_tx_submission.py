"""Exercise host formatting and submission together with the real IPC allocator."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_ipc_host_lifetime import CHECKS as IPC_CHECKS, HOST, program as ipc_program

TX = ROOT / "src/bl808/wifi/tx"


def prelude() -> str:
    source = ipc_program("nested", None).split('\nconst TestCase = "', 1)[0]
    source += IPC_CHECKS.split("for initialIrq in", 1)[0]
    for name in ["listInit", "listPick", "listPushBack", "listPopFront"]:
        source = source.replace(name, "ipc" + name[0].upper() + name[1:])
    source = source.replace(
        "  zeroMem(dst, size.int * Scale.int)",
        "  let factor = if dst in [cast[pointer](addr envA[0]), cast[pointer](addr envB[0]), "
        "cast[pointer](addr poolA[0]), cast[pointer](addr poolB[0])]: Scale.int else: 1\n"
        "  zeroMem(dst, size.int * factor)",
    ).replace(
        "  copyMem(dst, src, size.int * Scale.int)",
        "  let factor = if dst in [cast[pointer](addr envA[0]), cast[pointer](addr envB[0])]: Scale.int else: 1\n"
        "  copyMem(dst, src, size.int * factor)",
    ).replace(
        "proc regWrite(address: uint; value: uint32) = discard",
        "proc recordPublication()\nproc regWrite(address: uint; value: uint32) =\n"
        "  if address == IpcApp2EmbTrigger: recordPublication()",
    )
    source += (
        f'from "{TX.parent / "host_table_layout"}" import '
        "WifiHostStaTableCount, WifiHostStaTableOffset, WifiHostStaEntrySize, WifiHostVifCount\n"
    )
    layout = (TX / "layout.nim").read_text().replace("  TxHdrSize = 24'u\n", "")
    types = "".join((TX / "types_parts" / name).read_text() for name in [
        "packet_views.nim", "station_views.nim", "tx_descriptor_views.nim"])
    types = types.replace("txdescPrefixPadding*: array[12, uint8]", "txdescPrefixPadding*: array[12 * Scale.int, uint8]")
    types = types.replace("hostDescPadding*: array[4, uint8]", "hostDescPadding*: array[4 * Scale.int, uint8]")
    source += layout + types + "\nconst TxHdrSize = sizeof(TxHdrView).uint\n"
    source += r"""
type
  Pbuf = object
  KeTxFc = object
  Publication = tuple[node, buffer: pointer, packetAddress: uint32,
                      marker: uint8, length: uint32]
var
  wifi_hw: BlHwView
  txCntrlStaTrigger, txCntrlStaTriggerPending: uint32
  packets: array[4, PbufView]
  packetBytes: array[4, array[256, uint8]]
  released: array[4, int]
  publications: seq[Publication]
  onFree: proc()
  onPublish, onPrint: proc()
  printCalls: int
  criticalStack: seq[uint32]
proc bl_os_enter_critical() = criticalStack.add(ipcHostIrqSave())
proc bl_os_exit_critical() =
  let state = criticalStack.pop()
  ipcHostIrqRestore(state)
proc bl_os_printf(text: cstring) =
  inc printCalls
  if onPrint != nil:
    let callback = onPrint
    onPrint = nil
    callback()
proc bl_irq_handler() = discard
proc bl_tx_try_flush*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.}
proc pbuf_free(p: ptr Pbuf): uint8 =
  var index = -1
  for i in 0 ..< packets.len:
    if cast[pointer](p) == addr packets[i]: index = i
  doAssert index >= 0, "released an unowned source packet"
  inc released[index]
  doAssert released[index] == 1, "released the source packet twice"
  doAssert enabled == incoming
  if onFree != nil:
    let callback = onFree
    onFree = nil
    callback()
  1
"""
    views = (TX / "views.nim").read_text()
    # Network parsers below this point are irrelevant to descriptor submission.
    views = views.split("proc udpHeaderAt", 1)[0]
    source += views
    source += (TX / "queue_parts/addressing.nim").read_text()
    source += (TX / "queue_parts/header_fields.nim").read_text()
    source += (TX / "queue_parts/list_ops.nim").read_text()
    source += (TX / "queue_parts/flow_control.nim").read_text()
    source += r"""
proc recordPublication() =
  let wrapper = loadPtr(queue(E(), EnvListOngoingOff), 4)
  doAssert wrapper != nil
  let buffer = loadPtr(wrapper, TxdescHostHostIdOff)
  let descriptor = txdescUpperHost(wrapper)
  publications.add((wrapper, buffer, descriptor.pbufAddr,
                    descriptor.ethDest[5], descriptor.pbufChainedLen))
  if onPublish != nil: onPublish()
proc install() =
  setup()
  wifi_hw = default(BlHwView)
  wifi_hw.ipcEnv = E()
  wifi_hw.vifs[0].linksNum = 1
  wifi_hw.stas[0].isUsed = 1
  packets = default(typeof(packets))
  packetBytes = default(typeof(packetBytes))
  released = default(typeof(released))
  txCntrlStaTrigger = 0
  txCntrlStaTriggerPending = 0
  publications.setLen(0)
  onFree = nil
  onPublish = nil
  onPrint = nil
  printCalls = 0
  criticalStack.setLen(0)
proc enqueue(index: int; stationIndex = 0) =
  let bytes = addr packetBytes[index][0]
  packets[index] = PbufView(payload: bytes, len: 160, totLen: 160)
  let header = txHdrView(bytes)
  header.pbuf = addr packets[index]
  header.len = 160
  setTxHdrStaId(header, stationIndex.uint8)
  let ethernet = ethernetHeaderAt(bufferAt(bytes, PbufLinkEncapsulationHlen.uint))
  ethernet.dst[5] = (index + 1).uint8
  ethernet.src[5] = (index + 21).uint8
  ethernet.ethertype = 0x0008
  let station = addr wifi_hw.stas[stationIndex]
  station.isUsed = 1
  station.staIdx = stationIndex.uint8
  listPushBack(addr station.waitingList, header)
  txCntrlStaTrigger = txCntrlStaTrigger or bitSta(stationIndex)
proc checkPublished(count: int) =
  doAssert publications.len == count
  var used: seq[pointer]
  for record in publications:
    doAssert record.node notin used, "two transmissions used the same descriptor"
    used.add(record.node)
    doAssert record.packetAddress == cast[uint32](cast[uint](record.buffer)),
      "formatted descriptor and published buffer do not match"
    let ethernet = ethernetHeaderAt(bufferAt(txbufHostBuf(record.buffer), PbufLinkEncapsulationHlen.uint))
    doAssert record.marker == ethernet.dst[5]
    doAssert record.length == 160 - LinkOffsetLen.uint32
proc resetHost(env: pointer; pool: pointer) =
  ipc_host_init(env, addr callbackTable[0], pool, cast[pointer](0xCC))
  wifi_hw.ipcEnv = env
proc markConfirmed(count: int) =
  for index in 0 ..< count:
    let entry = ipcListPopFront(queue(E(), EnvListOngoingOff))
    doAssert entry != nil
    ipcListPushBack(queue(E(), EnvListCfmOff), entry)
"""
    return source


CHECKS = {
    "nested_free": r"""
for state in [false, true]:
  install()
  incoming = state
  enabled = state
  enqueue(0)
  onFree = proc() =
    enqueue(1)
    bl_tx_try_flush(0, nil)
  bl_tx_try_flush(0, nil)
  doAssert enabled == state
  checkPublished(2)
  doAssert released == [1, 1, 0, 0]
  doAssert length(queue(E(), EnvListOngoingOff)) == 2
  doAssert length(queue(E(), EnvListFreeOff)) == 2
  doAssert criticalStack.len == 0
""",
    "free_count": r"""
for state in [false, true]:
  install()
  enabled = state
  for occupied in 0 .. 4:
    for ac in 0 .. 3:
      doAssert ipc_host_txdesc_left(E(), ac.cint, 0) == (4 - occupied).cint,
        "free count does not follow the descriptor list"
      doAssert enabled == state
    if occupied < 4: discard submit(E(), (occupied + 1).uint)
""",
    "exhaust_buffer": r"""
install()
enqueue(0)
let returned = ipc_host_txbuf_get(E())
doAssert returned != nil
for i in 1 .. 3: doAssert ipc_host_txbuf_get(E()) != nil
bl_tx_try_flush(0, nil)
doAssert publications.len == 0 and released[0] == 0
doAssert length(queue(E(), EnvListFreeOff)) == 4
doAssert not listEmpty(addr wifi_hw.stas[0].waitingList)
ipc_host_txbuf_free(returned)
bl_tx_try_flush(0, nil)
doAssert publications.len == 1 and publications[0].buffer == returned
doAssert released[0] == 1
checkPartition(E(), P())
""",
    "free_count_completion": r"""
for state in [false, true]:
  install()
  incoming = state
  enabled = state
  for i in 0 .. 3: discard submit(E(), (i + 1).uint)
  doAssert ipc_host_txdesc_left(E(), 0, 0) == 0
  markConfirmed(2)
  dispatch(E())
  doAssert ipc_host_txdesc_left(E(), 0, 0) == 2
  markConfirmed(2)
  dispatch(E())
  doAssert ipc_host_txdesc_left(E(), 0, 0) == 4
  checkPartition(E(), P())
""",
    "free_count_invalid": r"""
install()
doAssert ipc_host_txdesc_left(nil, 0, 0) == 0
let free = queue(E(), EnvListFreeOff)
storePtr(free, 4, nil)
doAssert ipc_host_txdesc_left(E(), 0, 0) == 0
storePtr(free, 4, node(P(), 3))
storePtr(node(P(), 3), 0, node(P(), 0))
doAssert ipc_host_txdesc_left(E(), 0, 0) == 0
storePtr(E(), EnvListFreeOff, nil)
doAssert ipc_host_txdesc_left(E(), 0, 0) == 0
""",
    "free_count_irq": r"""
install()
let free = queue(E(), EnvListFreeOff)
onAccess = proc(base: pointer; offset: uint; write: bool) =
  if base == free and offset == 0 and not write:
    onAccess = nil
    interrupt(proc() = discard submit(E(), 1))
doAssert ipc_host_txdesc_left(E(), 0, 0) == 4
doAssert ipc_host_txdesc_left(E(), 0, 0) == 3
checkPartition(E(), P())
""",
    "exhaust_descriptor": r"""
install()
for i in 0 .. 3: discard submit(E(), (i + 1).uint)
publications.setLen(0)
enqueue(0)
bl_tx_try_flush(0, nil)
doAssert publications.len == 0 and released[0] == 0
doAssert not listEmpty(addr wifi_hw.stas[0].waitingList)
for i in 0 .. 3:
  doAssert loadU32(ptrAt(P(), SharedTxbufOff + i.uint * SharedTxbufSize), 0) == 0
checkPartition(E(), P())
""",
    "other_sta_resource_wait": r"""
for shortage in ["descriptor", "buffer"]:
  install()
  enqueue(0)
  bl_tx_try_flush(0, nil)
  let firstBuffer = publications[0].buffer
  for i in 1 .. 3:
    if shortage == "descriptor":
      discard submit(E(), (i + 1).uint)
    else:
      doAssert ipc_host_txbuf_get(E()) != nil
  publications.setLen(0)
  enqueue(1, 1)
  bl_tx_try_flush(0, nil)
  doAssert released[1] == 0 and publications.len == 0
  let reports = printCalls
  for _ in 0 .. 2: bl_tx_try_flush(0, nil)
  doAssert printCalls == reports

  onCfm = proc(context, hostId: pointer) =
    doAssert hostId == firstBuffer
    ipc_host_txbuf_free(hostId)
    txCntrlStaTriggerPending = bitSta(0)
    if shortage == "descriptor":
      # The callback runs before its own descriptor is returned.
      bl_tx_try_flush(0, nil)
      doAssert released[1] == 0
  markConfirmed(1)
  dispatch(E())
  bl_tx_try_flush(0, nil)
  doAssert released[1] == 1, "a station lost its only wake while resources were held by another"
  doAssert publications.len == 1 and publications[0].marker == 2
  doAssert txdescUpperHost(publications[0].node).staId == 1
  checkPartition(E(), P())
""",
    "resource_wait_reset": r"""
install()
for i in 0 .. 3: discard submit(E(), (i + 1).uint)
enqueue(0, 1)
bl_tx_try_flush(0, nil)
doAssert released[0] == 0
publications.setLen(0)
resetHost(E(), P())
bl_tx_try_flush(0, nil)
doAssert publications.len == 0, "old resource wake leaked into a replacement pool"
doAssert released[0] == 0 and not listEmpty(addr wifi_hw.stas[1].waitingList)
txCntrlStaTrigger = bitSta(1)
bl_tx_try_flush(0, nil)
doAssert publications.len == 1 and released[0] == 1
checkPartition(E(), P())
""",
    "pending_first": r"""
install()
let buffer = ipc_host_txbuf_get(E())
let storage = txbufHostBuf(buffer)
let header = txHdrView(bufferAt(storage, alignPads(storage).uint))
header.pbuf = buffer
header.len = 160
let ethernet = ethernetHeaderAt(bufferAt(storage, PbufLinkEncapsulationHlen.uint))
ethernet.dst[5] = 9
listPushBack(addr wifi_hw.stas[0].pendingList, header)
txCntrlStaTriggerPending = 1
enqueue(0)
bl_tx_try_flush(0, nil)
checkPublished(2)
doAssert publications[0].buffer == buffer and publications[0].marker == 9
doAssert publications[1].marker == 1
doAssert released == [1, 0, 0, 0]
doAssert listEmpty(addr wifi_hw.stas[0].pendingList)
checkPartition(E(), P())
""",
    "pending_first_after_resource_return": r"""
install()
let buffer = ipc_host_txbuf_get(E())
let storage = txbufHostBuf(buffer)
let header = txHdrView(bufferAt(storage, alignPads(storage).uint))
header.pbuf = buffer
header.len = 160
ethernetHeaderAt(bufferAt(storage, PbufLinkEncapsulationHlen.uint)).dst[5] = 9
listPushBack(addr wifi_hw.stas[0].pendingList, header)
for i in 0 .. 3: discard submit(E(), (i + 1).uint)
publications.setLen(0)
enqueue(0)
onPrint = proc() =
  markConfirmed(2)
  dispatch(E())
bl_tx_try_flush(0, nil)
bl_tx_try_flush(0, nil)
checkPublished(2)
doAssert publications[0].buffer == buffer and publications[0].marker == 9,
  "fresh packet passed an older pending retry when a descriptor returned"
doAssert publications[1].marker == 1 and released[0] == 1
checkPartition(E(), P())
""",
    "chained_packet": r"""
install()
enqueue(0)
packets[0].len = 100
packets[0].next = addr packets[1]
packets[1] = PbufView(payload: addr packetBytes[1][0], len: 60, totLen: 60)
for index in 0 ..< 60: packetBytes[1][index] = (index + 40).uint8
bl_tx_try_flush(0, nil)
checkPublished(1)
let data = cast[ptr UncheckedArray[uint8]](txbufHostBuf(publications[0].buffer))
for index in 0 ..< 60: doAssert data[100 + index] == (index + 40).uint8
doAssert released == [1, 0, 0, 0]
""",
    "interrupt_after_peek": r"""
install()
enqueue(0)
let free = queue(E(), EnvListFreeOff)
onAccess = proc(base: pointer; offset: uint; write: bool) =
  if base == free and offset == 0 and not write:
    onAccess = nil
    interrupt(proc() =
      enqueue(1)
      bl_tx_try_flush(0, nil))
bl_tx_try_flush(0, nil)
checkPublished(2)
doAssert publications[0].marker == 1 and publications[1].marker == 2
doAssert released == [1, 1, 0, 0]
checkPartition(E(), P())
""",
    "free_after_publish": r"""
for state in [false, true]:
  install()
  incoming = state
  enabled = state
  enqueue(0)
  onFree = proc() =
    checkPublished(1)
    doAssert length(queue(E(), EnvListOngoingOff)) == 1
    doAssert ipc_host_txdesc_left(E(), 0, 0) == 3
  bl_tx_try_flush(0, nil)
  doAssert released[0] == 1
""",
    "interrupted_allocator": r"""
install()
enqueue(0)
let free = queue(E(), EnvListFreeOff)
var borrowed: pointer
onAccess = proc(base: pointer; offset: uint; write: bool) =
  if base == free and offset == 0 and not write:
    onAccess = nil
    interrupt(proc() = borrowed = ipcListPopFront(free))
bl_tx_try_flush(0, nil)
checkPublished(1)
doAssert borrowed != nil and borrowed != publications[0].node
ipcListPushBack(free, borrowed)
checkPartition(E(), P())
""",
    "free_reset": r"""
for mode in 0 .. 3:
  install()
  enqueue(0)
  enqueue(1)
  onFree = proc() =
    case mode
    of 0: resetHost(E(), P())
    of 1: resetHost(E(), Q())
    of 2: resetHost(F(), P())
    else:
      resetHost(E(), Q())
      resetHost(E(), P())
    enqueue(2)
  bl_tx_try_flush(0, nil)
  doAssert publications.len == 1, "old flush continued after IPC reset"
  doAssert released == [1, 0, 0, 0]
  doAssert length(queue(wifi_hw.ipcEnv, EnvListFreeOff)) == 4
  doAssert ipcHostActiveDispatch == nil
""",
    "publish_reset": r"""
install()
enqueue(0)
enqueue(1)
onPublish = proc() =
  onPublish = nil
  interrupt(proc() = resetHost(E(), P()))
bl_tx_try_flush(0, nil)
doAssert publications.len == 1
doAssert released == [1, 0, 0, 0]
doAssert length(queue(E(), EnvListFreeOff)) == 4
doAssert ipcHostActiveDispatch == nil
""",
    "flow_control": r"""
install()
enqueue(0)
enqueue(1)
onFree = proc() = wifi_hw.stas[0].fcPs = 1
bl_tx_try_flush(0, nil)
checkPublished(1)
doAssert released == [1, 0, 0, 0]
doAssert not listEmpty(addr wifi_hw.stas[0].waitingList)
""",
    "resource_reset": r"""
install()
enqueue(0)
for i in 0 .. 3: doAssert ipc_host_txbuf_get(E()) != nil
onPrint = proc() = resetHost(E(), P())
bl_tx_try_flush(0, nil)
doAssert publications.len == 0 and released[0] == 0
doAssert ipcHostActiveDispatch == nil
checkPartition(E(), P())
""",
}


MUTANTS = {
    "flush_lock": "interrupted_allocator",
    "scope_guard": "free_reset",
    "early_release": "free_after_publish",
    "free_count_lock": "free_count_irq",
}


def source(case: str, mutation: str | None = None) -> str:
    prefix = prelude()
    push = (TX / "queue_parts/push.nim").read_text().replace("hostIpc.", "")
    flush = (TX / "flush.nim").read_text().replace("hostIpc.", "")
    functions = push + flush
    if mutation == "flush_lock":
        old = "  let saved = ipcHostIrqSave()\n"
        body = procedure(functions, "txFlushOne")
        assert old in body
        functions = functions.replace(body, body.replace(old, "  let saved = 8'u32\n", 1))
    elif mutation == "scope_guard":
        functions = functions.replace("if not ipcHostDispatchCurrent(scope, env):", "if false:")
    elif mutation == "early_release":
        old = "  txPush(station, descriptor, buffer, header)\n"
        assert old in functions
        functions = functions.replace(old, "  if packet != buffer: discard pbuf_free(cast[ptr Pbuf](packet))\n" + old)
    elif mutation == "free_count_lock":
        body = procedure(prefix, "ipc_host_txdesc_left")
        old = "  let saved = ipcHostIrqSave()\n"
        assert old in body
        prefix = prefix.replace(body, body.replace(old, "  let saved = 8'u32\n", 1))
    names = sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in names) if names else ""
    externs = sorted(set(re.findall(r"extern volatile unsigned int (\w+)", functions)))
    debug += '\n{.emit: "' + " ".join(f"volatile unsigned int {name};" for name in externs) + '".}\n'
    return prefix + debug + functions + CHECKS[case]


@pytest.mark.parametrize("case", CHECKS)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_submission(tmp_path: Path, case: str, mode: str) -> None:
    run(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTANTS)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_submission_guards(tmp_path: Path, mutation: str, mode: str) -> None:
    run(tmp_path, MUTANTS[mutation], mode, mutation)


def run(tmp_path: Path, case: str, mode: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "tx_submission.nim"
    path.write_text(source(case, mutation))
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
