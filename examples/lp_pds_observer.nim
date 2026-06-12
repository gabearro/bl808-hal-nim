## LP (E902) observer of the M0's PDS sleep.
##
## The LP lives in the always-on/low-power domain, so it stays running while the
## M0 powers down into PDS and its debug goes dark. This firmware reads the PDS
## controller registers directly and prints them over UART0 (which the M0 set up
## and handed off before sleeping), giving real-time visibility into the PDS
## state machine + wake timer that JTAG can't see.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/panicoverride

const
  Uart0         = 0x2000_A000'u
  UartFifoCfg1  = Uart0 + 0x84'u    # TX free slots in [5:0]
  UartFifoWdata = Uart0 + 0x88'u
  # PDS controller (always-on enough for the LP to read while M0 sleeps)
  PdsCtl   = 0x2000_E000'u
  PdsInt   = 0x2000_E00C'u
  PdsStat  = 0x2000_E01C'u
  # XRAM handshake with M0
  GoFlag   = XramBase + 0x3F20'u
  GoMagic  = 0x600D_600D'u32
  WokeFlag = XramBase + 0x3F24'u
  Samples  = 48

proc txByte(b: uint8) =
  while (regRead(UartFifoCfg1) and 0x3F'u32) == 0: discard
  regWrite(UartFifoWdata, b.uint32)

proc txStr(s: string) =
  for c in s: txByte(c.uint8)

proc txHex(v: uint32) =
  const hexd = "0123456789ABCDEF"
  var shift = 28
  while shift >= 0:
    txByte(hexd[((v shr shift.uint32) and 0xF'u32).int].uint8)
    shift -= 4

proc spin(n: uint32) =
  var d = 0'u32
  while d < n: inc d

proc main() {.exportc, cdecl.} =
  # Wait for M0 to finish its banner and hand off the UART.
  while regRead(GoFlag) != GoMagic: discard
  txStr("\r\n[LP] watching M0 PDS state:\r\n")
  var i = 0'u32
  while i < Samples.uint32:
    txStr("[LP] n=")
    txHex(i)
    txStr(" STAT=")
    txHex(regRead(PdsStat))
    txStr(" INT=")
    txHex(regRead(PdsInt))
    txStr(" CTL=")
    txHex(regRead(PdsCtl))
    if regRead(WokeFlag) != 0'u32:
      txStr(" <<M0-WOKE>>")
    txStr("\r\n")
    spin(120_000)        # ~spread the 48 samples across the M0's sleep window
    inc i
  txStr("[LP] observation complete\r\n")
  while true: discard
