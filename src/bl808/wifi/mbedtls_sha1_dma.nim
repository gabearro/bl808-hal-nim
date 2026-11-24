## Private all-core SHA DMA scratch aperture. The linker reserves the span.

import ../[memmap, mmio, sec, tzc]

{.emit: """/*TYPESECTION*/
extern char __wifi_sha_dma_start[], __wifi_sha_dma_end[];
static unsigned long wifi_sha_dma_start(void){return (unsigned long)__wifi_sha_dma_start;}
static unsigned long wifi_sha_dma_end(void){return (unsigned long)__wifi_sha_dma_end;}
""".}
proc dmaStart(): uint {.importc: "wifi_sha_dma_start", nodecl.}
proc dmaEnd(): uint {.importc: "wifi_sha_dma_end", nodecl.}

const
  PrivateShaDmaRegion = 0
  WramPageMask = 0x3FF'u32
  WramRangeMask = (WramPageMask shl 16) or WramPageMask
  WramWindowAddrMask = 0x000F_FFFF'u32
  WramGroup0Access = 0x3'u32 # IBUS and DBUS

proc validDmaSpan(start, stop: uint): bool {.inline.} =
  start >= WramBase and stop <= WramBase + WramSize.uint and
    stop > start and stop - start == 1024 and (start and 1023) == 0

proc installWifiShaDmaWindow*(lock: bool): bool =
  let start = dmaStart()
  let stop = dmaEnd()
  if not validDmaSpan(start, stop) or tzcSeBlockGroupField(tzcSeSha) != 1 or
      (regRead(TzcSecWramAddrMask) and WramPageMask) != 0:
    return false
  let offset = start.uint32 and WramWindowAddrMask
  let packed = tzcPackWindow(offset, (stop - start).uint32, 10)
  if tzcWindowRegionEnabled(tzcWinWram, PrivateShaDmaRegion) and
      ((regRead(TzcSecWramR0) and WramRangeMask) != packed or
       tzcWindowRegionGroupField(tzcWinWram, PrivateShaDmaRegion) != WramGroup0Access):
    return false
  if not tzcConfigureWindowRegion(tzcWinWram, PrivateShaDmaRegion,
      offset, (stop - start).uint32, {0.TzcAuthGroup}, lock = lock):
    return false
  # Group ownership is separate from the TZC permissions and local Mbed TLS
  # lease. Keep this image's group-0 reservation for Wi-Fi's lifetime.
  var claimed: bool
  secClaimGroup0(secBlkSha, claimed)

proc wifiShaDmaWindowReady*(): bool =
  let start = dmaStart()
  let stop = dmaEnd()
  if not validDmaSpan(start, stop) or
      not tzcWindowRegionEnabled(tzcWinWram, PrivateShaDmaRegion) or
      tzcWindowRegionGroupField(tzcWinWram, PrivateShaDmaRegion) != WramGroup0Access or
      tzcSeBlockGroupField(tzcSeSha) != 1 or secBlockOwner(secBlkSha) != SecOwnerGroup0 or
      (regRead(TzcSecWramAddrMask) and WramPageMask) != 0:
    return false
  let packed = tzcPackWindow(start.uint32 and WramWindowAddrMask, (stop - start).uint32, 10)
  if (regRead(TzcSecWramR0) and WramRangeMask) != packed: return false
  let blockNumber = packed and WramPageMask
  for region in 1 .. 2:
    if tzcWindowRegionEnabled(tzcWinWram, region):
      let other = regRead(TzcSecWramR0 + 4'u * region.uint) and WramRangeMask
      if (other shr 16) <= blockNumber and blockNumber <= (other and WramPageMask):
        return false
  true

proc wifiShaDmaContains*(address, size: uint): bool =
  let start = dmaStart()
  let stop = dmaEnd()
  validDmaSpan(start, stop) and size <= stop - start and address >= start and
    address <= stop - size
