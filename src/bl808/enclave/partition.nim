## Secure partition: declaratively split the SoC into a secure world (M0 +
## secure OCRAM + reserved SEC_ENG blocks) and an untrusted world (every other
## bus master, the U-mode application), then lock it.
##
## Two enforcement layers cooperate:
##   - TZC keeps untrusted *masters* (DMA/WiFi/USB/D0/LP) out of secure OCRAM
##     and the key-holding SEC_ENG blocks (PMP cannot constrain DMA).
##   - PMP keeps the U-mode *application* (same master as the enclave) out of
##     secure RAM and MMIO, granting only its own code/data/shared buffer.
##
## Region boundaries come from the enclave link map (bl808_m0_enclave.ld), so
## addresses are never duplicated between linker and firmware.

import ../mmio, ../memmap, ../tzc, ../pmp, ../flash_layout
import cruntime  # provides freestanding memcpy/memset/memmove

const EnclavePartitionStageAddr = 0x40002E90'u
const
  ## LP firmware uses the upper WRAM window. When LP is assigned to auth group 1
  ## as an untrusted peer, that RAM must be explicitly reachable or the E902
  ## faults before it can enter the enclave IPC client.
  LpRuntimeWramStart = WramBase + 0x20000'u
  LpRuntimeWramLen = 32'u32 * 1024'u32
  PeerIpcXramStart = XramBase
  PeerIpcXramLen = XramSize.uint32
  AllTzcSlaves = [
    tzcSlaveGlb, tzcSlaveMix, tzcSlaveGpip, tzcSlaveDbg, tzcSlaveRsvd,
    tzcSlaveTzc1, tzcSlaveTzc2, tzcSlaveRsvd2, tzcSlaveCci,
    tzcSlaveMcuMisc, tzcSlavePeripheral, tzcSlaveEmiMisc, tzcSlavePsramA,
    tzcSlavePsramB, tzcSlaveUsb, tzcSlaveRf2, tzcSlaveAudio, tzcSlaveEfCtrl,
    tzcSlaveMm, tzcSlaveDma0, tzcSlaveDma1, tzcSlavePwr,
  ]

proc partitionStage(code: uint32) {.inline.} =
  when defined(bl808EnclaveTrace):
    regWrite(EnclavePartitionStageAddr, code)
  else:
    discard code

# Link-map boundary accessors (cached OCRAM addresses).
{.emit: """/*TYPESECTION*/
extern char __secure_ram_start[], __secure_ram_end[];
extern char __umode_ram_start[], __umode_ram_end[];
extern char __shared_buf_start[], __shared_buf_end[];
extern char __enclave_flash_start[], __enclave_flash_len[];
extern char __wifi_bss_start[] __attribute__((weak));
extern char __wifi_bss_end[] __attribute__((weak));
extern char __wifi_rx_ram_start[] __attribute__((weak));
extern char __wifi_rx_ram_end[] __attribute__((weak));
static unsigned long __lnk_sec_start(void){return (unsigned long)__secure_ram_start;}
static unsigned long __lnk_sec_end(void){return (unsigned long)__secure_ram_end;}
static unsigned long __lnk_u_start(void){return (unsigned long)__umode_ram_start;}
static unsigned long __lnk_u_end(void){return (unsigned long)__umode_ram_end;}
static unsigned long __lnk_sh_start(void){return (unsigned long)__shared_buf_start;}
static unsigned long __lnk_sh_end(void){return (unsigned long)__shared_buf_end;}
static unsigned long __lnk_flash_start(void){return (unsigned long)__enclave_flash_start;}
static unsigned long __lnk_flash_len(void){return (unsigned long)__enclave_flash_len;}
static unsigned long __lnk_wifi_bss_start(void){return __wifi_bss_start ? (unsigned long)__wifi_bss_start : 0;}
static unsigned long __lnk_wifi_bss_end(void){return __wifi_bss_end ? (unsigned long)__wifi_bss_end : 0;}
static unsigned long __lnk_wifi_rx_ram_start(void){return __wifi_rx_ram_start ? (unsigned long)__wifi_rx_ram_start : 0;}
static unsigned long __lnk_wifi_rx_ram_end(void){return __wifi_rx_ram_end ? (unsigned long)__wifi_rx_ram_end : 0;}
""".}

proc lnkSecStart(): uint {.importc: "__lnk_sec_start", nodecl.}
proc lnkSecEnd(): uint {.importc: "__lnk_sec_end", nodecl.}
proc lnkUStart(): uint {.importc: "__lnk_u_start", nodecl.}
proc lnkUEnd(): uint {.importc: "__lnk_u_end", nodecl.}
proc lnkShStart(): uint {.importc: "__lnk_sh_start", nodecl.}
proc lnkShEnd(): uint {.importc: "__lnk_sh_end", nodecl.}
proc lnkFlashStart(): uint {.importc: "__lnk_flash_start", nodecl.}
proc lnkFlashLen(): uint {.importc: "__lnk_flash_len", nodecl.}
proc lnkWifiBssStart(): uint {.importc: "__lnk_wifi_bss_start", nodecl.}
proc lnkWifiBssEnd(): uint {.importc: "__lnk_wifi_bss_end", nodecl.}
proc lnkWifiRxRamStart(): uint {.importc: "__lnk_wifi_rx_ram_start", nodecl.}
proc lnkWifiRxRamEnd(): uint {.importc: "__lnk_wifi_rx_ram_end", nodecl.}

proc cachedToPhys(a: uint): uint {.inline.} =
  ## Cached aliases -> physical addresses for TZC, which filters on the
  ## physical bus address. The default enclave profile lives in OCRAM; larger
  ## WASM-capable enclave profiles can move secure RAM to WRAM.
  if a >= OcramCachedBase and a < OcramCachedBase + OcramSize:
    a - (OcramCachedBase - OcramBase)
  elif a >= WramCachedBase and a < WramCachedBase + WramSize:
    a - (WramCachedBase - WramBase)
  else:
    a

proc tzcWindowForCachedRam(a: uint): TzcWindow {.inline.} =
  if a >= OcramCachedBase and a < OcramCachedBase + OcramSize:
    tzcWinOcram
  elif a >= WramCachedBase and a < WramCachedBase + WramSize:
    tzcWinWram
  else:
    tzcWinOcram

type
  SecurePartition* = object
    ## Untrusted bus masters forced into TZC auth group 1.
    untrustedMasters*: set[TzcMaster]
    ## Peripheral slaves reserved to the secure world (group 0).
    secureSlaves*: set[TzcSlave]
    ## SEC_ENG blocks reserved to the secure world (group 0).
    secureSeBlocks*: set[TzcSeBlock]
    ## Freeze every assignment (master/window/SE) until reset and latch
    ## secure-boot-done. Set only on the final apply.
    lock*: bool

## A sensible default: every bus master except the enclave's own M0 is
## untrusted -> group 1. Listing all of them closes coverage gaps: the MCU-side
## masters tzcMasterCci and tzcMasterLz4, and the MM-side
## tzcMasterBlai/Codec, were previously omitted and would have defaulted to
## group 0.
when defined(bl808AllcoreWasmHttp):
  const
    ## The HTTP manager runs the WiFi stack as a trusted M0 OS service. Keep the
    ## WiFi and MCU DMA masters in group 0 for now; BL808 WiFi scan/association
    ## has not been validated after the MAC/DMA path is moved to group 1. Peer
    ## cores and MM-domain DMA-capable masters remain untrusted.
    defaultUntrustedMasters* = {tzcMasterLp .. tzcMasterDma2} -
      {tzcMasterM0, tzcMasterWifi, tzcMasterDma0, tzcMasterDma1}
else:
  const
    defaultUntrustedMasters* = {tzcMasterLp .. tzcMasterDma2} - {tzcMasterM0}

const
  defaultSecureSlaves*: set[TzcSlave] = {}
  defaultSecureSeBlocks* = {tzcSeAes, tzcSeSha, tzcSeTrng, tzcSePka, tzcSeGmac}

proc defaultPartition*(lock = false): SecurePartition =
  SecurePartition(
    untrustedMasters: defaultUntrustedMasters,
    secureSlaves: defaultSecureSlaves,
    secureSeBlocks: defaultSecureSeBlocks,
    lock: lock)

proc applyUmodePmp*() =
  ## Default-deny PMP table for the U-mode app: execute its flash text, read
  ## and write its own RAM and the shared buffer, nothing else. Secure OCRAM
  ## and all MMIO are denied by omission. Uses PMP entries 1..3 (entry 0 is
  ## BootROM-locked).
  let regions = [
    PmpRegion(base: lnkFlashStart(), size: lnkFlashLen(),
              mode: pmpNapot, perm: {pmpR, pmpX}, lock: false),
    PmpRegion(base: lnkUStart(), size: lnkUEnd() - lnkUStart(),
              mode: pmpNapot, perm: {pmpR, pmpW}, lock: false),
    PmpRegion(base: lnkShStart(), size: lnkShEnd() - lnkShStart(),
              mode: pmpNapot, perm: {pmpR, pmpW}, lock: false),
  ]
  discard pmpApplyTable(regions)

proc applyPartition*(p: SecurePartition) =
  ## Program the full partition. Order matters: configure every resource window
  ## before moving peer bus masters into group 1, so live peers do not fault on
  ## the first access after their group changes.
  # 1. Keep the secure core in group 0.
  partitionStage(0x45500100'u32)
  tzcSetMasterGroupAll(tzcMasterM0, 0, lock = p.lock)
  partitionStage(0x45500110'u32)

  # 2. Reserve secure peripherals and crypto blocks to group 0 while the bus
  # master map is still in its reset/default state.
  partitionStage(0x45500300'u32)
  partitionStage(0x45500304'u32)
  let secureSlaves = p.secureSlaves
  partitionStage(0x45500308'u32)
  if card(secureSlaves) != 0:
    for s in AllTzcSlaves:
      if s in secureSlaves:
        partitionStage(0x45500400'u32 or uint32(ord(s) and 0xFF))
        tzcSetSlaveGroup(s, 0, lock = p.lock)
  partitionStage(0x45500410'u32)
  tzcSetSlaveGroups(tzcSlavePeripheral, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  partitionStage(0x45500310'u32)
  let secureSeBlocks = p.secureSeBlocks
  partitionStage(0x45500314'u32)
  for b in secureSeBlocks:
    partitionStage(0x45500500'u32 or uint32(ord(b) and 0xFF))
    tzcSetSeBlockGroup(b, 0, lock = p.lock)

  # 3. Secure RAM window (region 0) reachable by group 0 only.
  partitionStage(0x45500600'u32)
  let secStart = cachedToPhys(lnkSecStart())
  let secLen = (lnkSecEnd() - lnkSecStart()).uint32
  discard tzcConfigureWindowRegion(tzcWindowForCachedRam(lnkSecStart()), 0,
    secStart.uint32, secLen, {0.TzcAuthGroup}, lock = p.lock)

  # 4a. LP's persistent flash image is stored at a boot2-shifted physical
  # offset but released at the logical LP boot offset. Authorise the full
  # logical LP boot span here; it also covers the stored bytes at 0x0A0000.
  partitionStage(0x45500608'u32)
  let lpRaw = lpRuntimeMappedFlashSpan()
  discard tzcConfigureWindowRegion(tzcWinSf, 0,
    lpRaw.base.uint32, lpRaw.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  discard tzcConfigureNsecSfRegion(0,
    lpRaw.base.uint32, lpRaw.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)

  # 4b. Keep the LP core boot/runtime WRAM reachable by untrusted group 1.
  # The expanded WRAM enclave linker ends secure RAM at 0x22050000, so this
  # aperture starts immediately above it and also covers JTAG LP RAM images.
  partitionStage(0x45500610'u32)
  discard tzcConfigureWindowRegion(tzcWinWram, 2,
    LpRuntimeWramStart.uint32, LpRuntimeWramLen,
    {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)

  # 4c. Keep the shared WASM repository reachable through the MCU XIP alias.
  # RAM-loaded D0 and LP both use this alias for flash-backed VM reads.
  partitionStage(0x45500620'u32)
  let wasmMcuXip = peerMcuXipFlashSpan()
  discard tzcConfigureWindowRegion(tzcWinSf, 1,
    wasmMcuXip.base.uint32, wasmMcuXip.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  discard tzcConfigureNsecSfRegion(1,
    wasmMcuXip.base.uint32, wasmMcuXip.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)

  # 4d. Also open the repository by raw serial-flash offset for SF paths that
  # authorise the physical flash address rather than the XIP alias.
  partitionStage(0x45500624'u32)
  let wasmRaw = wasmRepositoryRawFlashSpan()
  discard tzcConfigureWindowRegion(tzcWinSf, 2,
    wasmRaw.base.uint32, wasmRaw.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  discard tzcConfigureNsecSfRegion(2,
    wasmRaw.base.uint32, wasmRaw.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)

  # 4e. LP flash images execute in place. Once LP is moved to group 1, it needs
  # an explicit XIP window for the LP firmware range or it stalls on fetch.
  partitionStage(0x45500628'u32)
  let lpFlash = lpRuntimeXipSpan()
  discard tzcConfigureWindowRegion(tzcWinSf, 3,
    lpFlash.base.uint32, lpFlash.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  discard tzcConfigureNsecSfRegion(3,
    lpFlash.base.uint32, lpFlash.len, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)
  tzcSetSfCtrlGroups(tzcSfCr, {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)
  tzcSetSfCtrlGroups(tzcSfSec, {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)
  tzcSetSfCtrlModeArb(lock = p.lock)
  tzcSetSfRegionXGroups({0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)
  tzcSetNsecSfCtrlGroups(tzcSfCr, {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)
  tzcSetNsecSfCtrlGroups(tzcSfSec, {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)
  tzcSetNsecSfCtrlModeArb(lock = p.lock)
  tzcSetNsecSfRegionXGroups({0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)

  # 4f. Peer-core enclave service transport uses XRAM mailboxes and status
  # words. Keep that shared IPC surface reachable by group 1 after lock while
  # secure RAM and key-bearing peripherals stay group-0 only.
  partitionStage(0x45500630'u32)
  discard tzcConfigureWindowRegion(tzcWinXram, 2,
    PeerIpcXramStart.uint32, PeerIpcXramLen, {0.TzcAuthGroup, 1.TzcAuthGroup},
    lock = p.lock)

  # 4g. HTTP-manager WiFi builds export linker-owned descriptor/shared state and
  # RX payload DMA pool bounds. If WiFi/DMA masters are moved to group 1 in a
  # future partition, open the linker-selected windows before regrouping.
  partitionStage(0x45500640'u32)
  let wifiBssStart = cachedToPhys(lnkWifiBssStart())
  let wifiBssEnd = cachedToPhys(lnkWifiBssEnd())
  if wifiBssStart != 0 and wifiBssEnd > wifiBssStart:
    discard tzcConfigureWindowRegion(tzcWindowForCachedRam(lnkWifiBssStart()), 1,
      wifiBssStart.uint32, (wifiBssEnd - wifiBssStart).uint32,
      {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)

  let wifiRxRamStart = cachedToPhys(lnkWifiRxRamStart())
  let wifiRxRamEnd = cachedToPhys(lnkWifiRxRamEnd())
  if wifiRxRamStart != 0 and wifiRxRamEnd > wifiRxRamStart:
    discard tzcConfigureWindowRegion(tzcWinWram, 1,
      wifiRxRamStart.uint32, (wifiRxRamEnd - wifiRxRamStart).uint32,
      {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = p.lock)

  # 5. Now move untrusted masters into group 1. At this point live peers keep
  # access to their runtime apertures immediately after the group transition.
  for m in p.untrustedMasters:
    partitionStage(0x45500200'u32 or uint32(ord(m) and 0xFF))
    if m == tzcMasterLp:
      tzcSetMasterGroup(m, 1, lock = p.lock)
      tzcSetNsecMasterGroup(m, 0, lock = p.lock)
    else:
      tzcSetMasterGroupAll(m, 1, lock = p.lock)

  # 6. U-mode default-deny PMP grants.
  partitionStage(0x45500700'u32)
  applyUmodePmp()

  # 7. Freeze everything if this is the final apply.
  partitionStage(0x45500800'u32)
  if p.lock:
    tzcLockMasterGroups()
    tzcSetSbootDone()
  partitionStage(0x45500900'u32)

proc secureRamStart*(): uint = lnkSecStart()
proc secureRamEnd*(): uint = lnkSecEnd()
proc umodeStackTop*(): uint = lnkUEnd()
proc umodeRamStart*(): uint = lnkUStart()
proc umodeRamLen*(): uint = lnkUEnd() - lnkUStart()
proc enclaveHandlerStack*(): uint = lnkSecEnd() - 256   # M-mode ecall stack top
proc sharedBufStart*(): uint = lnkShStart()
proc sharedBufLen*(): uint = lnkShEnd() - lnkShStart()
