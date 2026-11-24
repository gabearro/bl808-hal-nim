"""Check EDCA field extraction and A-MPDU limits against the vendor routine."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  KeMsgConsumed = 0.cint
  MM_SET_EDCA_CFM = 23'u16
  MmSetEdcaReqPayloadSize = 8'u32
type
  Vif = object
    vifType, state: uint8
    edcaRegs: array[4, uint32]
  Header = object
    paramLen: uint32
var
  mm: MmEnvView
  regs: array[4, uint32]
  samples: array[4, array[3, uint32]]
  sampled, trackReads: bool
  readCounts: array[4, int]
  readOrder: seq[int]
  writes: seq[tuple[address: uint, value: uint32]]
  vifs: array[2, Vif]
  header: Header
  request: MmSetEdcaReqPayload
  uapsdCalls: int
  mmEdcaRefresh: tuple[vif: uint8]
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc mmEdcaRefreshCurrent(): bool = false
proc mmProgramEdca(vif: ptr Vif) = doAssert false
proc mmEdcaOwner(): ptr Vif =
  if vifs[1].state != 0: addr vifs[1] else: nil
proc mmEnvView(): ptr MmEnvView = addr mm
proc registerIndex(address: uint): int =
  doAssert address >= MACHW_EDCA_AC_BK_REG and address <= MACHW_EDCA_AC_VO_REG
  doAssert (address and 3) == 0
  ((address - MACHW_EDCA_AC_BK_REG) div 4).int
proc volatileLoad(p: ptr uint32): uint32 =
  let index = registerIndex(cast[uint](p))
  let count = readCounts[index]
  inc readCounts[index]
  if trackReads: readOrder.add(index)
  if sampled:
    doAssert count < 3, "too many register reads"
    samples[index][count]
  else:
    regs[index]
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  if address != MACHW_RX_CNTRL_REG:
    regs[registerIndex(address)] = value
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert p == (addr mm) and value == 0 and length == sizeof(MmEnvView).csize_t
  zeroMem(p, length.int)
  p
proc vifEntryAddr(index: uint8): uint = cast[uint](addr vifs[index])
proc vifChannelAt(p: uint): ptr Vif = cast[ptr Vif](p)
proc smActivationAdmitRequest(p: pointer): bool = true
proc ps_uapsd_set(p: pointer; ac: uint8; enabled: uint32) =
  doAssert p == (addr vifs[1]) and ac == request.acmFlag and enabled == request.uapsdAc.uint32
  inc uapsdCalls
proc fields(): array[5, uint16] =
  [mm.edcaBkDur, mm.edcaBeDur, mm.edcaViDur, mm.edcaVoDur, mm.edcaBcnDur]
proc encode(field: uint32): uint32 = (field shl 12) or 0xF0000FFF'u32
proc expectedLimit(field: uint32): uint16 =
  if field == 0 or field > 150: 150'u16 else: field.uint16
proc setup() =
  zeroMem(addr mm, sizeof(mm))
  mm.rxFilterBase = 0xA5A51234'u32
  mm.rxFilterExtra = 0x87654321'u32
  mm.keepAliveInterval = 99
  mm.listenWindow = 27
  regs = [0'u32, 0, 0, 0]
  sampled = false
  trackReads = false
  readCounts = [0, 0, 0, 0]
  readOrder.setLen(0)
  writes.setLen(0)
  vifs = default(typeof(vifs))
  header.paramLen = 8
  uapsdCalls = 0
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["MmEnvView", "MmSetEdcaReqPayload"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    registers = (FW / "register_constants.nim").read_text().split("  # MAC platform registers", 1)[0]
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    functions = "\n".join(procedure(kernel, name) for name in [
        "mm_rx_filter_set", "mm_env_max_ampdu_duration_set", "mm_env_init"
    ])
    handler = procedure((FW / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    edca = handler.split("  of 22:", 1)[1].split("  of 24:", 1)[0]
    edca = "\n".join(line[2:] for line in edca.splitlines()[1:])
    wrapper = '''
proc applyEdca(param: pointer): cint =
  let msgBody = param
  let hdr = addr header
  if hdr.paramLen < MmSetEdcaReqPayloadSize: return 0
  let edcaRefresh = false
  var cfmBasicId: uint16
'''
    return registers + types + PLATFORM + functions + wrapper + edca + "\n  cfmBasicId.cint\n"


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_all_stable_field_values(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
for field in 0'u32 .. 65535'u32:
  for ac in 0 .. 3: regs[ac] = encode((field + ac.uint32) and 0xFFFF)
  readCounts = [0, 0, 0, 0]
  let before = mm
  mm_env_max_ampdu_duration_set(0)
  var expected = before
  var limits: array[4, uint16]
  for ac in 0 .. 3:
    let value = (field + ac.uint32) and 0xFFFF
    limits[ac] = expectedLimit(value)
    doAssert readCounts[ac] == (if value == 0: 1 elif value > 150: 2 else: 3)
  expected.edcaBkDur = limits[0]
  expected.edcaBeDur = limits[1]
  expected.edcaViDur = limits[2]
  expected.edcaVoDur = limits[3]
  expected.edcaBcnDur = limits[3]
  doAssert mm == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_changing_register_reads_match_vendor_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for values in [[0'u32, 1, 2], [1'u32, 151, 3], [1'u32, 150, 149],
               [151'u32, 1, 65535], [1'u32, 0, 0]]:
  setup()
  sampled = true
  trackReads = true
  for ac in 0 .. 3:
    for sample in 0 .. 2: samples[ac][sample] = encode(values[sample])
  mm_env_max_ampdu_duration_set(123)
  let reads = if values[0] == 0: 1 elif values[1] > 150: 2 else: 3
  let limit = if reads == 3: values[2].uint16 else: 150'u16
  doAssert fields() == [limit, limit, limit, limit, limit]
  var expectedOrder: seq[int]
  for ac in 0 .. 3:
    doAssert readCounts[ac] == reads
    for sample in 0 ..< reads: expectedOrder.add(ac)
  doAssert readOrder == expectedOrder
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_initialization_uses_decoded_limits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
regs = [encode(0), encode(47), encode(94), encode(150)]
mm_env_init()
doAssert fields() == [150'u16, 47, 94, 150, 150]
doAssert writes == @[(MACHW_RX_CNTRL_REG, 0x7FFFFFDE'u32)]
doAssert mm.idleFlag == 1 and mm.flagsHigh == 1
doAssert mm.keepAliveInterval == 20000 and mm.keepAliveLimit == 10
doAssert mm.tbttPreDuration == 4000 and mm.rxFilterExtra == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_edca_request_recomputes_cached_limits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for active in [0'u8, 1]:
  for ac in 0'u8 .. 3'u8:
    setup()
    regs = [encode(10), encode(20), encode(30), encode(40)]
    let before = mm
    vifs[1].state = active
    request = MmSetEdcaReqPayload(edcaParam: encode(47 + ac.uint32),
                                 vifIdx: 1, acmFlag: ac, uapsdAc: 1)
    doAssert applyEdca(addr request) == 23
    doAssert vifs[1].edcaRegs[ac] == request.edcaParam and uapsdCalls == 1
    if active != 0:
      doAssert writes == @[(MACHW_EDCA_AC_BK_REG + ac.uint * 4, request.edcaParam)]
      var expected = [10'u16, 20, 30, 40, 40]
      expected[ac] = (47 + ac.uint16)
      if ac == 3: expected[4] = expected[3]
      doAssert fields() == expected and readCounts == [3, 3, 3, 3]
    else:
      doAssert writes.len == 0 and readCounts == [0, 0, 0, 0] and mm == before
''')
