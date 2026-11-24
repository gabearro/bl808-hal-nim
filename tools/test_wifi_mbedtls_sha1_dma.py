"""Exercise the all-core SHA DMA admission checks with fake WRAM registers."""

from pathlib import Path

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


def test_allcore_sha_dma_window_requires_correct_range_owner_and_data_permission(tmp_path: Path) -> None:
    dma = (ROOT / "src/bl808/wifi/mbedtls_sha1_dma.nim").read_text()
    tzc = (ROOT / "src/bl808/tzc.nim").read_text()
    run_program(tmp_path, "checked", r'''
type
  TzcAuthGroup = range[0..1]
  TzcWindow = enum tzcWinWram
  TzcSeBlock = enum tzcSeSha
  SecBlock = enum secBlkSha
const
  WramBase = 0x22030000'u
  WramSize = 160 * 1024
  TzcSecWramR0 = 0x20005188'u
  TzcSecWramAddrMask = 0x20005184'u
  SecOwnerGroup0 = 1'u32
  SecOwnerGroup1 = 2'u32
  SecOwnerFree = 3'u32
var
  regs: array[3, uint32]
  enables: array[3, bool]
  groups: array[3, uint32]
  shaOwner = SecOwnerFree
  shaAccess = 1'u32
  addrMask: uint32
  dmaPage = 0x2204ec00'u
  installs, claims: int
proc dmaStart(): uint = dmaPage
proc dmaEnd(): uint = dmaPage + 1024
proc regRead(address: uint): uint32 =
  if address == TzcSecWramAddrMask: addrMask
  else: regs[((address - TzcSecWramR0) div 4).int]
proc tzcWindowRegionEnabled(window: TzcWindow; index: int): bool = enables[index]
proc tzcWindowRegionGroupField(window: TzcWindow; index: int): uint32 = groups[index]
proc tzcSeBlockGroupField(b: TzcSeBlock): uint32 = shaAccess
proc secBlockOwner(b: SecBlock): uint32 = shaOwner
proc secClaimGroup0(b: SecBlock; claimed: var bool): bool =
  if shaOwner == SecOwnerFree:
    inc claims
    claimed = true
    shaOwner = SecOwnerGroup0
  shaOwner == SecOwnerGroup0
''' + procedure(tzc, "tzcPackWindow") + r'''
proc tzcConfigureWindowRegion(window: TzcWindow; index: int; offset, size: uint32;
                              group: set[TzcAuthGroup]; lock: bool): bool =
  doAssert index == 0 and offset == 0x4ec00 and size == 1024
  doAssert group == {0.TzcAuthGroup}
  inc installs
  regs[index] = tzcPackWindow(offset, size, 10) and 0x03ff03ff'u32
  groups[index] = 3
  enables[index] = true
  true
''' + dma[dma.index("const\n"):] + r'''
doAssert not wifiShaDmaWindowReady()
doAssert installWifiShaDmaWindow(false)
doAssert claims == 1 and installs == 1 and regs[0] == 0x013b013b'u32
doAssert wifiShaDmaWindowReady()
doAssert wifiShaDmaContains(dmaPage, 136)
doAssert wifiShaDmaContains(dmaPage + 1024 - 72, 72)
doAssert not wifiShaDmaContains(dmaPage + 1024 - 71, 72)
doAssert not wifiShaDmaContains(dmaPage - 1, 1)
doAssert not wifiShaDmaContains(dmaPage, high(uint))

groups[0] = 1
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
groups[0] = 0xf
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
groups[0] = 3
addrMask = 1
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
addrMask = 0
shaAccess = 2
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
shaAccess = 1
shaOwner = SecOwnerGroup1
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
doAssert shaOwner == SecOwnerGroup1 and claims == 1
shaOwner = SecOwnerGroup0
regs[0] = 0x013a013a
doAssert not wifiShaDmaWindowReady() and not installWifiShaDmaWindow(false)
regs[0] = 0x813b813b'u32
doAssert wifiShaDmaWindowReady()
enables[1] = true
regs[1] = 0x8139813b'u32
doAssert not wifiShaDmaWindowReady()
regs[1] = 0x8139813a'u32
doAssert wifiShaDmaWindowReady()
dmaPage += 16
doAssert not wifiShaDmaWindowReady() and not wifiShaDmaContains(dmaPage, 16)
''')
