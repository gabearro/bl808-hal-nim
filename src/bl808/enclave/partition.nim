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

import ../mmio, ../memmap, ../tzc, ../pmp
import cruntime  # provides freestanding memcpy/memset/memmove

# Link-map boundary accessors (cached OCRAM addresses).
{.emit: """/*TYPESECTION*/
extern char __secure_ram_start[], __secure_ram_end[];
extern char __umode_ram_start[], __umode_ram_end[];
extern char __shared_buf_start[], __shared_buf_end[];
extern char __enclave_flash_start[], __enclave_flash_len[];
static unsigned long __lnk_sec_start(void){return (unsigned long)__secure_ram_start;}
static unsigned long __lnk_sec_end(void){return (unsigned long)__secure_ram_end;}
static unsigned long __lnk_u_start(void){return (unsigned long)__umode_ram_start;}
static unsigned long __lnk_u_end(void){return (unsigned long)__umode_ram_end;}
static unsigned long __lnk_sh_start(void){return (unsigned long)__shared_buf_start;}
static unsigned long __lnk_sh_end(void){return (unsigned long)__shared_buf_end;}
static unsigned long __lnk_flash_start(void){return (unsigned long)__enclave_flash_start;}
static unsigned long __lnk_flash_len(void){return (unsigned long)__enclave_flash_len;}
""".}

proc lnkSecStart(): uint {.importc: "__lnk_sec_start", nodecl.}
proc lnkSecEnd(): uint {.importc: "__lnk_sec_end", nodecl.}
proc lnkUStart(): uint {.importc: "__lnk_u_start", nodecl.}
proc lnkUEnd(): uint {.importc: "__lnk_u_end", nodecl.}
proc lnkShStart(): uint {.importc: "__lnk_sh_start", nodecl.}
proc lnkShEnd(): uint {.importc: "__lnk_sh_end", nodecl.}
proc lnkFlashStart(): uint {.importc: "__lnk_flash_start", nodecl.}
proc lnkFlashLen(): uint {.importc: "__lnk_flash_len", nodecl.}

proc cachedToPhys(a: uint): uint {.inline.} =
  ## OCRAM cached alias (0x6202_0000) -> physical (0x2202_0000) for TZC, which
  ## filters on the physical bus address.
  a - (OcramCachedBase - OcramBase)

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

const
  ## A sensible default: everything that can DMA or is a separate core is
  ## untrusted; EF_CTRL / TZC / DBG and the key-bearing crypto blocks are
  ## reserved to the enclave. (Revisit WiFi/DMA per Phase-0 coexistence probe.)
  # Every bus master EXCEPT the enclave's own M0 is untrusted -> group 1. Listing
  # all of them (not a hand-picked subset) closes coverage gaps: the MCU-side
  # masters tzcMasterCci and tzcMasterLz4 — and the MM-side tzcMasterBlai/Codec —
  # were previously omitted and would have defaulted to group 0, i.e. able to
  # reach the secure window. (D0/Blai/Codec/2dDma/Dma2 accesses INTO the MCU
  # domain are also tagged as tzcMasterMmBus, which is in the set — confirmed by
  # m0_tzc_enforce_test on hardware — but assigning each master explicitly is
  # belt-and-suspenders and leaves no master ungrouped.)
  defaultUntrustedMasters* = {tzcMasterLp .. tzcMasterDma2} - {tzcMasterM0}
  defaultSecureSlaves* = {tzcSlaveEfCtrl, tzcSlaveDbg, tzcSlaveTzc1, tzcSlaveTzc2}
  defaultSecureSeBlocks* = {tzcSeAes, tzcSeSha, tzcSePka, tzcSeGmac}

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
  ## Program the full partition. Order matters: place every master and the
  ## secure window before locking, so a lock never strands a half-configured
  ## policy.
  # 1. Secure core in group 0; untrusted masters in group 1.
  tzcSetMasterGroup(tzcMasterM0, 0, lock = p.lock)
  for m in p.untrustedMasters:
    tzcSetMasterGroup(m, 1, lock = p.lock)

  # 2. Reserve secure peripherals and crypto blocks to group 0.
  for s in p.secureSlaves:
    tzcSetSlaveGroup(s, 0, lock = p.lock)
  for b in p.secureSeBlocks:
    tzcSetSeBlockGroup(b, 0, lock = p.lock)

  # 3. Secure OCRAM window (region 0) reachable by group 0 only.
  let secStart = cachedToPhys(lnkSecStart())
  let secLen = (lnkSecEnd() - lnkSecStart()).uint32
  discard tzcConfigureWindowRegion(tzcWinOcram, 0,
    secStart.uint32, secLen, {0.TzcAuthGroup}, lock = p.lock)

  # 4. U-mode default-deny PMP grants.
  applyUmodePmp()

  # 5. Freeze everything if this is the final apply.
  if p.lock:
    tzcLockMasterGroups()
    tzcSetSbootDone()

proc secureRamStart*(): uint = lnkSecStart()
proc secureRamEnd*(): uint = lnkSecEnd()
proc umodeStackTop*(): uint = lnkUEnd()
proc umodeRamStart*(): uint = lnkUStart()
proc umodeRamLen*(): uint = lnkUEnd() - lnkUStart()
proc enclaveHandlerStack*(): uint = lnkSecEnd() - 256   # M-mode ecall stack top
proc sharedBufStart*(): uint = lnkShStart()
proc sharedBufLen*(): uint = lnkShEnd() - lnkShStart()
