"""Compare MM station/AP register programming with the vendor write sequence."""

from pathlib import Path

import pytest

from test_wifi_beacon_lifetime import VIF_PLATFORM
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


REGISTER_MODEL = r'''
type Access = tuple[write: bool, address: uint, value: uint32]
var
  registers = initTable[uint, uint32]()
  accesses: seq[Access]
  statusSamples: array[3, uint32]
  statusIndex: int
  sampleStatus: bool
proc regRead(address: uint): uint32 =
  if sampleStatus and address == MACHW_STATUS_REG and statusIndex < statusSamples.len:
    result = statusSamples[statusIndex]
    inc statusIndex
  else:
    result = registers.getOrDefault(address)
  accesses.add((false, address, result))
proc regWrite(address: uint; value: uint32) =
  accesses.add((true, address, value))
  registers[address] = value
proc setupRegisters() =
  registers.clear()
  accesses.setLen(0)
  statusSamples = [0xFFFFFFFF'u32, 0x12345678'u32, 0xABCDEF01'u32]
  statusIndex = 0
  sampleStatus = true
proc expectedStation(mac: array[6, uint8]; filter: uint32): seq[Access] =
  let low = mac[0].uint32 or (mac[1].uint32 shl 8) or
            (mac[2].uint32 shl 16) or (mac[3].uint32 shl 24)
  let high = mac[4].uint32 or (mac[5].uint32 shl 8)
  @[(false, 0x24B0004C'u, statusSamples[0]),
    (true, 0x24B0004C'u, statusSamples[0] and not 2'u32),
    (false, 0x24B0004C'u, statusSamples[1]),
    (true, 0x24B0004C'u, statusSamples[1] or 1'u32),
    (true, 0x24B0001C'u, 0x100'u32),
    (true, 0x24B080A4'u, 0'u32),
    (true, 0x24B080A8'u, 0'u32),
    (true, 0x24B00010'u, low),
    (true, 0x24B00014'u, high),
    (false, 0x24B0004C'u, statusSamples[2]),
    (true, 0x24B0004C'u, statusSamples[2] and not 0x700'u32),
    (true, 0x24B00060'u, filter)]
'''

SETUP = r'''
var mm: MmEnvView
proc mmEnvView(): ptr MmEnvView = addr mm
proc setup() =
  mm = default(MmEnvView)
  mm.rxFilterExtra = 0xC0800001'u32
  mm.keepAliveInterval = 12345
  mm.listenWindow = 99
  setupRegisters()
'''


def definitions() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["MmEnvView", "MacAddrView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    registers = (FW / "register_constants.nim").read_text().split("  # MAC platform registers", 1)[0]
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    interrupt_constants = kernel.split("const\n  # MAC HW timer registers", 1)[1].split("\nproc ", 1)[0]
    helpers = procedure(layout, "lowLe") + procedure(layout, "highLe")
    return (
        "import std/tables\n" + registers + "const\n  # MAC HW timer registers" +
        interrupt_constants + types + helpers +
        "\ntemplate macAddrAt(p: pointer): ptr MacAddrView = cast[ptr MacAddrView](p)\n"
    )


def functions() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return "\n".join(
        procedure(kernel, name).split("\ntype\n", 1)[0]
        for name in ["mm_rx_filter_set", "mm_hw_info_set",
                     "mm_hw_ap_info_set", "mm_hw_ap_info_reset"]
    )


def source() -> str:
    return definitions() + REGISTER_MODEL + SETUP + functions()


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_address_programmed_once(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for byteIndex in 0 .. 5:
  for value in 0 .. 255:
    setup()
    var mac = [0x02'u8, 0x13, 0x24, 0x85, 0x96, 0xF7]
    mac[byteIndex] = value.uint8
    let originalMac = mac
    let before = mm
    mm_hw_info_set(addr mac[0])
    var expected = before
    expected.rxFilterBase = 0x3503858C'u32
    doAssert mm == expected and mac == originalMac
    doAssert accesses == expectedStation(mac, expected.rxFilterBase or expected.rxFilterExtra)
    doAssert statusIndex == 3
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_status_reads_and_filter_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bit in 0 .. 31:
  for inverted in [false, true]:
    for promiscuous in [0'u32, 1, 0x80000000'u32]:
      setup()
      let value = 1'u32 shl bit
      statusSamples = if inverted: [not value, value, not value] else: [value, not value, value]
      mm.rxPromiscUploadFlag = promiscuous
      var storage = [0xA5'u8, 2, 3, 4, 0x85, 0x96, 0xF7, 0x5A]
      let mac = [storage[1], storage[2], storage[3], storage[4], storage[5], storage[6]]
      let original = storage
      let before = mm
      mm_hw_info_set(addr storage[1])
      var expected = before
      expected.rxFilterBase = if promiscuous == 0: 0x3503858C'u32 else: 0x3503A58C'u32
      doAssert mm == expected and storage == original
      doAssert accesses == expectedStation(mac, expected.rxFilterBase or expected.rxFilterExtra)
      doAssert statusIndex == 3
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_setup_and_reset_preserve_other_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bit in 0 .. 31:
  for promiscuous in [0'u32, 1, 0x80000000'u32]:
    for vif in [0'u8, 1, 255]:
      setup()
      sampleStatus = false
      let status = not (1'u32 shl bit)
      let unmask = 1'u32 shl bit
      registers[MACHW_STATUS_REG] = status
      registers[MACHW_INTC_UNMASK_REG] = unmask
      mm.apPromiscUploadFlag = promiscuous
      let before = mm
      mm_hw_ap_info_set(vif)
      var expected = before
      expected.rxFilterBase = if promiscuous == 0: 0x3507858C'u32 else: 0x3507A58C'u32
      doAssert mm == expected
      doAssert accesses == @[
        (false, 0x24B0004C'u, status),
        (true, 0x24B0004C'u, status or 2'u32),
        (true, 0x24B00060'u, expected.rxFilterBase or expected.rxFilterExtra),
        (true, 0x24B08070'u, 0x40001'u32),
        (false, 0x24B08074'u, unmask),
        (true, 0x24B08074'u, unmask or 0x40001'u32)]
      accesses.setLen(0)
      mm_hw_ap_info_reset(vif)
      expected.rxFilterBase = 0x3503858C'u32
      doAssert mm == expected
      doAssert accesses == @[
        (false, 0x24B0004C'u, status or 2'u32),
        (true, 0x24B0004C'u, status and not 2'u32),
        (true, 0x24B00060'u, expected.rxFilterBase or expected.rxFilterExtra),
        (true, 0x24B08070'u, 0x40001'u32),
        (false, 0x24B08074'u, unmask or 0x40001'u32),
        (true, 0x24B08074'u, unmask and not 0x40001'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vif_registration_programs_station_then_ap(tmp_path: Path, mode: str) -> None:
    platform = VIF_PLATFORM.replace("  MACHW_BASE = 0x24B00000'u\n", "").replace(
        "  MACHW_RX_CNTRL_REG = MACHW_BASE + 0x60\n", ""
    ).replace("  mm: tuple[rxFilterExtra, rxFilterBase: uint32]", "  mm: MmEnvView")
    for name in ["regRead", "regWrite", "mm_hw_info_set",
                 "mm_hw_ap_info_set", "mm_hw_ap_info_reset"]:
        platform = platform.replace(procedure(platform, name), "")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    vif = (FW / "vif_management.nim").read_text()
    code = definitions() + platform + REGISTER_MODEL + functions()
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    for name in ["co_list_init", "co_list_push_front", "co_list_push_back", "co_list_pop_front"]:
        code += procedure(kernel, name)
    for name in ["vif_mgmt_entry_init", "vif_mgmt_init", "vif_mgmt_register"]:
        code += procedure(vif, name)
    run_program(tmp_path, mode, code + r'''
for kind in [VIF_TYPE_STA, VIF_TYPE_AP]:
  reset()
  setupRegisters()
  mm = default(MmEnvView)
  mm.rxFilterExtra = 0xC0800001'u32
  doAssert vif_mgmt_init()
  var index = 0xFF'u8
  doAssert vif_mgmt_register(addr mac[0], kind, false, addr index) == 0
  doAssert index == 0 and vifs[0].macAddr == mac
  let station = expectedStation(mac, 0x3503858C'u32 or mm.rxFilterExtra)
  doAssert accesses[0 ..< station.len] == station and statusIndex == 3
  if kind == VIF_TYPE_STA:
    doAssert accesses == station and env.staCount == 1 and env.apCount == 0
  else:
    let status = statusSamples[2] and not 0x700'u32
    doAssert accesses[station.len .. ^1] == @[
      (false, 0x24B0004C'u, status),
      (true, 0x24B0004C'u, status or 2'u32),
      (true, 0x24B00060'u, 0x3507858C'u32 or mm.rxFilterExtra),
      (true, 0x24B08070'u, 0x40001'u32),
      (false, 0x24B08074'u, 0'u32),
      (true, 0x24B08074'u, 0x40001'u32)]
    doAssert env.apCount == 1 and env.staCount == 0
''')
