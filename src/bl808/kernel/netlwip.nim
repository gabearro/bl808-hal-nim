## lwIP network interface driver for the BL808 EMAC.
##
## Bridges lwIP's netif abstraction to the EMAC DMA driver:
##
##   let drv = emacDriverInit(macAddr)
##   netlwipInit(drv, macAddr)
##   # Now run netlwipPoll() periodically from a CPS task
##
## The network task processes received packets and runs lwIP timers.

import ./lwipcore, ./emacdrv, ./runtime, ./transform, ./sched, ./sleep

# Status callback — defined at C level to avoid Nim emit issues
{.emit: """
#include "lwip/netif.h"
static void bl808_netif_status_cb(struct netif *n) {
  volatile unsigned int *uart = (volatile unsigned int *)0x2000A088UL;
  uart[0] = 'I'; uart[0] = 'P'; uart[0] = ':';
  unsigned int ip = n->ip_addr.addr;
  for (int i = 0; i < 4; i++) {
    unsigned int oct = (ip >> (i * 8)) & 0xFF;
    if (oct >= 100) { uart[0] = '0' + oct / 100; oct %= 100; }
    if (oct >= 10) { uart[0] = '0' + oct / 10; oct %= 10; }
    uart[0] = '0' + oct;
    if (i < 3) uart[0] = '.';
  }
  uart[0] = '\r'; uart[0] = '\n';
}
""".}

# =============================================================================
# State
# =============================================================================

var
  lwipNetif: Netif
  emac: EmacDriver
  initialized: bool = false
  savedMac: array[6, uint8]

proc netlwipNetif*(): ptr Netif =
  ## Return the managed lwIP netif for low-level wrapper tests.
  addr lwipNetif

# =============================================================================
# Netif callbacks
# =============================================================================

proc bl808LinkOutput(netif: ptr Netif, p: ptr Pbuf): ErrT {.cdecl.} =
  ## Called by lwIP to send a raw Ethernet frame.
  ## Flattens the pbuf chain and submits to the EMAC TX ring.
  if emac == nil:
    return ErrConn

  # Calculate total length from pbuf chain
  let totalLen = pbufTotLen(p).int
  if totalLen > MaxFrameLen or totalLen == 0:
    return ErrBuf

  # Flatten pbuf chain into a contiguous buffer
  var buf: array[MaxFrameLen, uint8]
  var offset = 0
  var cur = p
  while cur != nil and offset < totalLen:
    let payload = pbufPayload(cur)
    let segLen = pbufLen(cur).int
    if payload != nil and segLen > 0:
      copyMem(addr buf[offset], payload, segLen)
      offset += segLen
    cur = pbufNext(cur)

  if emac.send(buf.toOpenArray(0, offset - 1)):
    ErrOk
  else:
    ErrBuf

proc bl808NetifInit(netif: ptr Netif): ErrT {.cdecl.} =
  ## lwIP netif initialization callback.
  netifSetName(netif, 'e', '0')
  netifSetMtu(netif, 1500)
  netifSetHwaddr(netif, savedMac)
  netifSetFlags(netif,
    NetifFlagBroadcast or NetifFlagEtharp or NetifFlagLinkUp)
  netifSetLinkOutput(netif, bl808LinkOutput)
  {.emit: "`netif`->output = etharp_output;".}
  ErrOk

# =============================================================================
# RX processing
# =============================================================================

var rxPacketsProcessed*: int = 0
var rxPollCalls*: int = 0

proc processRxPackets() =
  ## Drain all received frames from the EMAC RX ring into lwIP.
  if emac == nil: return
  rxPollCalls += 1
  while true:
    let rx = emac.tryRecv()
    if rx.len == 0:
      break
    rxPacketsProcessed += 1
    # Debug: print Ethernet type field (bytes 12-13)
    if rx.buf != nil and rx.len >= 14:
      let b12 = rx.buf[12]
      let b13 = rx.buf[13]
      {.emit: """
      {
        volatile unsigned int *u = (volatile unsigned int *)0x2000A088UL;
        u[0]='['; u[0]='0'+(`b12`>>4); u[0]='0'+(`b12`&0xF);
        u[0]='0'+(`b13`>>4); u[0]='0'+(`b13`&0xF); u[0]=']';
      }
      """.}
    # Allocate a pbuf and copy the frame data
    let p = pbufAlloc(pbufRaw, rx.len.uint16, pbufPool)
    if p != nil:
      discard pbufTake(p, cast[pointer](rx.buf), rx.len.uint16)
      let err = ethernetInput(p, addr lwipNetif)
      if err != ErrOk:
        discard pbufFree(p)
    else:
      # pbuf allocation failed — drop the packet
      discard
    # Return the BD to hardware
    emac.recycleRxBd()

# =============================================================================
# Polling
# =============================================================================

proc netlwipPoll*() =
  ## Process received packets and run lwIP timers.
  ## Call this frequently from a CPS task (~10ms interval).
  if not initialized: return
  processRxPackets()
  sysCheckTimeouts()

# =============================================================================
# Initialization
# =============================================================================

proc netlwipInitWithAddrs(drv: EmacDriver, macAddr: array[6, uint8],
                          ip, mask, gw: IpAddr, startDhcp: bool) =
  ## Initialize lwIP and the network interface.
  emac = drv
  savedMac = macAddr
  lwipInit()

  var ipAddr = ip
  var netmask = mask
  var gateway = gw

  discard netifAdd(addr lwipNetif, addr ipAddr, addr netmask, addr gateway,
                   nil, bl808NetifInit, ethernetInput)

  netifSetDefault(addr lwipNetif)
  netifSetUp(addr lwipNetif)
  netifSetLinkUp(addr lwipNetif)

  # Register status callback
  {.emit: "netif_set_status_callback(&`lwipNetif`, bl808_netif_status_cb);".}

  if startDhcp:
    discard dhcpStart(addr lwipNetif)

  initialized = true

  # Register poll hook
  addSchedulerPollHook(proc() = netlwipPoll())

  # Also set up a periodic timer to ensure the scheduler wakes for polling,
  # since EMAC IRQ delivery may not re-trigger for back-to-back packets.
  proc netlwipTimerTick() =
    netlwipPoll()
    discard addTimerMs(50, netlwipTimerTick)  # Re-arm every 50ms
  discard addTimerMs(50, netlwipTimerTick)

proc netlwipInit*(drv: EmacDriver, macAddr: array[6, uint8]) =
  ## Initialize lwIP and use DHCP for address assignment.
  netlwipInitWithAddrs(drv, macAddr, ipAddrAny(), ipAddrAny(), ipAddrAny(), true)

proc netlwipInitStatic*(drv: EmacDriver, macAddr: array[6, uint8],
                        ip, mask, gw: IpAddr) =
  ## Initialize lwIP with a static IPv4 address.
  netlwipInitWithAddrs(drv, macAddr, ip, mask, gw, false)

# =============================================================================
# CPS network task
# =============================================================================

proc networkTask*(drv: EmacDriver,
                  macAddr: array[6, uint8]): CpsVoidFuture {.cps.} =
  ## Main network task — initializes lwIP and polls continuously.
  ## Spawn this from main():
  ##   discard networkTask(drv, macAddr)
  netlwipInit(drv, macAddr)
  while true:
    netlwipPoll()
    await sleepMs(10)

proc networkTaskStatic*(drv: EmacDriver, macAddr: array[6, uint8],
                        ip, mask, gw: IpAddr): CpsVoidFuture {.cps.} =
  ## Main network task with static IPv4 addressing.
  netlwipInitStatic(drv, macAddr, ip, mask, gw)
  while true:
    netlwipPoll()
    await sleepMs(10)
