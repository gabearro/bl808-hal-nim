## Phase 0 enclave hardware probe (M0 only, fully reversible).
##
## Resolves load-bearing unknowns for the secure enclave framework without
## burning or locking anything (a reset clears every write):
##   1. RISC-V PMP: per-entry cfg/lock state (entries 0..7) + NAPOT support.
##   2. SEC_DBG chip id + debug mode (via secdbg.nim).
##   3. This chip's eFuse security state (via efuse.nim typed accessors).
##   4. SEC_ENG per-block group ownership claim/release (via sec.nim).
##   5. Real-silicon readback of the TZC group/region encoding (tzc.nim).
##
## Output is plain `[PROBE]` lines for substring matching by the hw harness.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/efuse, bl808/sec, bl808/secdbg
import bl808/tzc
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString("[PROBE] ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(v)
  discard console.sendLine("")

# ---------------------------------------------------------------------------
# PMP CSR probing. CSR numbers must be immediates, so each entry is explicit.
# ---------------------------------------------------------------------------
{.emit: """/*TYPESECTION*/
static unsigned long __pmp_rw_addr(int i, unsigned long w) {
  unsigned long o = 0;
  #define A(n,csr) case n: asm volatile("csrw "#csr",%0"::"r"(w)); \
                            asm volatile("csrr %0,"#csr:"=r"(o)); break;
  switch (i) {
    A(0,0x3b0) A(1,0x3b1) A(2,0x3b2) A(3,0x3b3)
    A(4,0x3b4) A(5,0x3b5) A(6,0x3b6) A(7,0x3b7)
    A(8,0x3b8) A(9,0x3b9) A(10,0x3ba) A(11,0x3bb)
    A(12,0x3bc) A(13,0x3bd) A(14,0x3be) A(15,0x3bf)
  }
  #undef A
  return o;
}
static unsigned long __pmp_rd_cfg(int i) {
  unsigned long o = 0;
  #define C(n,csr) case n: asm volatile("csrr %0,"#csr:"=r"(o)); break;
  switch (i) { C(0,0x3a0) C(1,0x3a1) C(2,0x3a2) C(3,0x3a3) }
  #undef C
  return o;
}
""".}

proc pmpRwAddr(i: cint, w: uint): uint {.importc: "__pmp_rw_addr", nodecl.}
proc pmpRdCfg(i: cint): uint {.importc: "__pmp_rd_cfg", nodecl.}

proc probePmp() =
  line("[PROBE] --- PMP ---")
  var implemented = 0
  for i in 0 ..< 16:
    let v = pmpRwAddr(i.cint, high(uint))
    discard pmpRwAddr(i.cint, 0)
    if v != 0: inc implemented
  kv("pmp_addr_regs", implemented.uint32)
  # Per-entry config byte (read-only; shows which entries the BootROM locked).
  for e in 0 ..< 8:
    let cfg = (pmpRdCfg((e div 4).cint) shr ((e mod 4) * 8)) and 0xFF
    kv("pmp_cfg_entry" & $e, cfg.uint32)

proc probeSecDbg() =
  line("[PROBE] --- SEC_DBG ---")
  let id = secDbgChipId()
  kv("chipid_lo", (id and 0xFFFFFFFF'u64).uint32)
  kv("chipid_hi", (id shr 32).uint32)
  kv("dbg_mode_raw", secDbgModeRaw())
  kv("dbg_enable_lanes", secDbgEnableLanes())

proc probeEfuse() =
  line("[PROBE] --- EFUSE ---")
  let st = efuseReadSecState()
  kv("sboot_en", st.sbootEn)
  kv("sf_aes_mode", st.sfAesMode.uint32)
  kv("sign_mode", st.signMode.uint32)
  kv("jtag0_dis", st.jtag0Disable)
  kv("se_dbg_dis", (if st.seDbgDisabled: 1'u32 else: 0'u32))
  kv("keyslot0_rd_locked", (if st.keySlotReadLocked[0]: 1'u32 else: 0'u32))

proc probeSecOwnership() =
  line("[PROBE] --- SEC_ENG OWNERSHIP ---")
  for blk in [secBlkAes, secBlkSha, secBlkPka, secBlkGmac]:
    var rel = false
    let claimed = secClaimGroup0(blk, rel)
    let owner = secBlockOwner(blk)
    secReleaseGroup0(blk, rel)
    kv("claim_owner_blk" & $blk.ord, (if claimed: 0x100'u32 else: 0'u32) or owner)

proc probeTzc() =
  line("[PROBE] --- TZC ---")
  kv("rom_sboot_done", tzcRomSbootDone())
  discard tzcConfigureWindowRegion(tzcWinOcram, 0,
    OcramBase.uint32, 0x1000, {0.TzcAuthGroup}, lock = false)
  kv("ocram_ctrl_after", regRead(TzcSecOcramCtrl))
  tzcSetMasterGroup(tzcMasterDma0, 1, lock = false)
  kv("dma0_group", tzcMasterGroup(tzcMasterDma0).uint32)
  tzcSetSeBlockGroup(tzcSeAes, 0, lock = false)
  kv("se_ctrl0_after", regRead(TzcSecSeCtrl0))

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  line("")
  line("=== BL808 Enclave Phase-0 Probe ===")
  probePmp()
  probeSecDbg()
  probeEfuse()
  probeSecOwnership()
  probeTzc()
  line("=== Probe Complete ===")
  while true:
    wfi()
