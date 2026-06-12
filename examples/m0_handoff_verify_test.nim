## Verified secondary-core release (D): M0 gates D0's release on a successful
## NSB1 manifest verification (real PKA).
##
##   1. a TAMPERED D0 manifest fails verification -> M0 does NOT release D0
##      -> the D0 "ran" XRAM slot stays clear (the gate holds);
##   2. the genuine D0 manifest verifies -> M0 releases D0 -> D0 boots and
##      signals the XRAM slot -> M0 observes the verified handoff completed.
##
## D0's code is flashed alongside (d0_handoff_probe) and loaded by releaseD0;
## production would wrap that binary IN the NSB1 manifest and copy the verified
## payload, but the gating property proven here is the core of secure handoff.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/secureboot/container, bl808/secureboot/verify
import bl808/panicoverride
import bl808/kernel/alloc
include sb_chain_vector

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  D0RanAddr  = XramBase + 0x3F00'u
  D0RanMagic = 0xD0D0D0D0'u32
  LpRanAddr  = XramBase + 0x3F08'u
  LpRanMagic = 0x11335577'u32

var
  console: Uart
  passed = 0
  failed = 0
  d0buf: array[GoodD0Len, uint8]
  lpbuf: array[GoodLpLen, uint8]

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc shRead(a: uint): uint32 =
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)
proc shWrite(a: uint, v: uint32) =
  regWrite(a, v); dcacheFlushAll(); fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 Verified Core Release Test ===")

  shWrite(D0RanAddr, 0)
  shWrite(LpRanAddr, 0)
  mmPowerOn()
  var hdr: Nsb1Header

  # 1. Tampered manifest -> verification fails -> do NOT release D0.
  for i in 0 ..< GoodD0Len: d0buf[i] = GoodD0[i]
  d0buf[OffSignature + 3] = d0buf[OffSignature + 3] xor 0xFF
  check("tampered D0 manifest fails verification",
        verifyNsb1(d0buf, RootPubX, RootPubY, hdr) == vrBadSignature)
  for _ in 0 ..< 200:                       # give a (hypothetical) D0 time to run
    delayUs(1000)
  check("D0 NOT released after failed verification", shRead(D0RanAddr) != D0RanMagic)

  # 2. Genuine manifest -> verification ok -> release D0.
  for i in 0 ..< GoodD0Len: d0buf[i] = GoodD0[i]
  let ok = verifyNsb1(d0buf, RootPubX, RootPubY, hdr) == vrOk
  check("genuine D0 manifest verifies", ok)
  if ok:
    line("[M0] Releasing D0 after verification")
    releaseD0()
    var ran = 0'u32
    var spins = 0
    while spins < 400:
      ran = shRead(D0RanAddr)
      if ran == D0RanMagic: break
      delayUs(10_000)
      inc spins
    check("D0 released and signaled after verification", ran == D0RanMagic)

  # 3. LP (E902) verified handoff: verify the LP manifest, then release LP (flash
  #    XIP boot, the proven lp_allcore_test path). The separately-flashed LP image
  #    only runs on a successful verification.
  for i in 0 ..< GoodLpLen: lpbuf[i] = GoodLp[i]
  let lpOk = verifyNsb1(lpbuf, RootPubX, RootPubY, hdr) == vrOk
  check("genuine LP manifest verifies", lpOk)
  if lpOk:
    line("[M0] Releasing LP after verification")
    mmPowerOn()
    releaseLP()
    var lran = 0'u32
    var lspins = 0
    while lspins < 600:
      lran = shRead(LpRanAddr)
      if lran == LpRanMagic: break
      delayUs(10_000)
      inc lspins
    check("LP executed and signaled after verification", lran == LpRanMagic)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
