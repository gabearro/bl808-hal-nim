"""Keep RX initialization tied to its callback pair and reset generation."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_dma_ring import source as ring_source


def source() -> str:
    code = r'''
var onEnter, onExit, onProbe, onTrace, onLog: proc()
var alternateExit, missingEntry, missingExit: bool
var alternateExits, upperInitializations, listClears: int
var rxStationIdentities: array[41, bool]
var rxUploadEpochs: array[41, uint32]
proc runHook(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
''' + ring_source()
    replacements = {
        "enter": r'''
proc enter(): uint32 {.cdecl.} =
  inc enters
  result = irqSave()
  runHook(onEnter)
''',
        "leave": r'''
proc leave(saved: uint32) {.cdecl.} =
  inc exits
  irqRestore(saved)
  runHook(onExit)
proc otherLeave(saved: uint32) {.cdecl.} =
  inc alternateExits
  irqRestore(saved)
proc log(fmt: cstring) {.cdecl, varargs.} = runHook(onLog)
''',
        "blOpsFunc": r'''
proc blOpsFunc(slot: int): pointer =
  case slot
  of 4: result = cast[pointer](log)
  of 20:
    if not missingEntry: result = cast[pointer](enter)
  of 24:
    if not missingExit:
      result = if alternateExit: cast[pointer](otherLeave) else: cast[pointer](leave)
  else: discard
''',
        "nimFwRxDmaAfterInitProbe": r'''
proc nimFwRxDmaAfterInitProbe() = runHook(onProbe)
''',
        "rfPhyTraceCheckpoint": r'''
proc rfPhyTraceCheckpoint(stage: uint32) =
  doAssert stage == 0x10 and irqLevel == 0
  runHook(onTrace)
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    code += r'''
type UpperEnv = object
  uploadList: CoList
var upper: UpperEnv
proc rxuCntrlEnvView(): ptr UpperEnv = addr upper
proc co_list_init(list: ptr CoList) =
  inc listClears
  list[] = default(CoList)
proc rxu_cntrl_init() =
  inc upperInitializations
  upper = default(UpperEnv)
'''
    production = (FW / "rx_layer.nim").read_text()
    for name in ("rx_swdesc_init", "rxl_init", "rxl_reset"):
        code += procedure(production, name)
    return code + r'''
proc setup() =
  reset()
  onEnter = nil
  onExit = nil
  onProbe = nil
  onTrace = nil
  onLog = nil
  alternateExit = false
  missingEntry = false
  missingExit = false
  alternateExits = 0
  upperInitializations = 0
  listClears = 0
  upper = default(UpperEnv)
proc markReplacement() =
  headers[0].magic = 0x76543210
  lower.submittedHead = addr headers[6]
  lower.submittedTail = addr headers[7]
  hardware.pdTail = addr payloads[8]
  lower.queue.first = cast[pointer](0x31)
  upper.uploadList.first = cast[pointer](0x32)
  software[0].firstHeaderDesc = cast[pointer](0x33)
proc checkReplacement() =
  doAssert headers[0].magic == 0x76543210
  doAssert lower.submittedHead == addr headers[6]
  doAssert lower.submittedTail == addr headers[7]
  doAssert hardware.pdTail == addr payloads[8]
  doAssert lower.queue.first == cast[pointer](0x31)
  doAssert upper.uploadList.first == cast[pointer](0x32)
  doAssert software[0].firstHeaderDesc == cast[pointer](0x33)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_initialization_preserves_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for phase in 0 .. 3:
  for operation in 0 .. 2:
    for incoming in [0'u32, 8'u32]:
      setup()
      irqLevel = incoming
      let action = proc() =
        rxl_hwdesc_init(1)
        markReplacement()
      case phase
      of 0: onEnter = action
      of 1: onProbe = action
      of 2: onTrace = action
      else: onExit = action
      case operation
      of 0: rxl_hwdesc_init(1)
      of 1: rxl_init()
      else: rxl_reset()
      checkReplacement()
      doAssert enters == 2 and exits == 2 and alternateExits == 0
      doAssert upperInitializations == 0 and listClears == 0
      doAssert irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initialization_keeps_original_exit_callback(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8'u32]:
  setup()
  irqLevel = incoming
  onProbe = proc() = alternateExit = true
  rxl_hwdesc_init(1)
  doAssert enters == 1 and exits == 1 and alternateExits == 0
  doAssert irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_initialization_balances_exit_after_callback_exception(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8'u32]:
  setup()
  irqLevel = incoming
  onProbe = proc() = raise newException(ValueError, "probe failed")
  var raised = false
  try: rxl_hwdesc_init(1)
  except ValueError: raised = true
  doAssert raised and enters == 1 and exits == 1
  doAssert irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_software_reset_cancels_descriptor_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8'u32]:
  setup()
  irqLevel = incoming
  let before = headers
  onEnter = proc() = rx_swdesc_init()
  rxl_hwdesc_init(1)
  doAssert headers == before and triggers.len == 0
  doAssert enters == 1 and exits == 1 and irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_initialization_callback_has_no_partial_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for missing in [0, 1]:
  for operation in [0, 1, 2]:
    for incoming in [0'u32, 8'u32]:
      setup()
      irqLevel = incoming
      let before = headers
      missingEntry = missing == 0
      missingExit = missing == 1
      case operation
      of 0: rxl_hwdesc_init(1)
      of 1: rxl_init()
      else: rxl_reset()
      doAssert headers == before and triggers.len == 0
      doAssert enters == 0 and exits == 0 and errors == 1
      doAssert listClears == 0 and upperInitializations == 0 and irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_init_and_reset_keep_normal_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for full in [false, true]:
  for incoming in [0'u32, 8'u32]:
    setup()
    irqLevel = incoming
    rxInitializationEpoch = high(uint32)
    lower.queue.first = cast[pointer](0x31)
    upper.uploadList.first = cast[pointer](0x32)
    software[0].firstHeaderDesc = cast[pointer](0x33)
    if full: rxl_init()
    else: rxl_reset()
    doAssert enters == 1 and exits == 1 and irqLevel == incoming
    doAssert triggers == @[0x04000000'u32, 0x08000000'u32]
    doAssert lower.queue.first == nil and upper.uploadList.first == nil
    if full:
      doAssert software[0].firstHeaderDesc == addr headers[0]
      doAssert upperInitializations == 1 and listClears == 1
      doAssert rxInitializationEpoch == 1
    else:
      doAssert software[0].firstHeaderDesc == cast[pointer](0x33)
      doAssert upperInitializations == 0 and listClears == 2
      doAssert rxInitializationEpoch == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_diagnostic_reset_does_not_publish_old_chain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8'u32]:
  setup()
  irqLevel = incoming
  for i in 1 ..< 41:
    headers[i].usedFlag = 1
    payloads[i].usedFlag = 1
  var logged = false
  onLog = proc() =
    logged = true
    rxl_hwdesc_init(1)
    markReplacement()
  rxl_reset()
  doAssert logged
  checkReplacement()
  doAssert enters == 2 and exits == 2 and irqLevel == incoming
  doAssert listClears == 0 and upperInitializations == 0
''')
