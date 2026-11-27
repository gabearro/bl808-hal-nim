# Host slots are submission credits. DMA records keep the
# full wrapper layout because the lower MAC builds headers and links in it.
# Both pools are on the same Wi-Fi SRAM bus as the original IPC storage.
when defined(bl808m0):
  {.pragma: wifiTxDma, codegenDecl: "$# $# __attribute__((section(\".wifibss.tx_dma\"), aligned(16)))".}
else:
  {.pragma: wifiTxDma, align: 16.}

const
  TxDmaAllFree = high(uint32) shr (32 - WifiTxDmaRecordCount)
  ExtraTxPacketBuffers = WifiTxPacketBufferCount - NxTxDescCnt.int
  ExtraTxHostSlots = max(0, WifiTxHostSlotCount - NxTxDescCnt.int)

static:
  doAssert SharedTxdescHostSize mod 4 == 0
  doAssert SharedTxbufSize mod 4 == 0

var
  txDmaRecords {.wifiTxDma.}: array[WifiTxDmaRecordCount,
    array[(SharedTxdescHostSize div 4).int, uint32]]
  extraTxPackets {.wifiTxDma.}: array[ExtraTxPacketBuffers,
    array[(SharedTxbufSize div 4).int, uint32]]
  txDmaFree: uint32
  # A nil credit means the host slot was already returned on primary DONE.
  txDmaCredit: array[WifiTxDmaRecordCount, pointer]
  txHostCredits: array[ExtraTxHostSlots, pointer]
  txDmaEnv: pointer
  txHostDoneReturns {.exportc: "nimfw_dbg_tx_host_done_returns".}: uint32
  txHostLinkedDoneReturns {.exportc: "nimfw_dbg_tx_host_linked_done_returns".}: uint32
  txDmaPoolStalls {.exportc: "nimfw_dbg_tx_dma_pool_stalls".}: uint32
  txPacketPoolStalls {.exportc: "nimfw_dbg_tx_packet_pool_stalls".}: uint32
  txDmaPeak {.exportc: "nimfw_dbg_tx_dma_peak".}: uint32

proc ipcHostTxDmaIndex*(record: pointer): int {.inline.} =
  let offset = cast[uint](record) - cast[uint](addr txDmaRecords[0])
  if offset < sizeof(txDmaRecords).uint and offset mod SharedTxdescHostSize == 0:
    (offset div SharedTxdescHostSize).int
  else:
    -1

proc ipcHostTxPacketInPool*(shared, packet: pointer): bool {.inline.} =
  let slot = cast[uint](packet)
  let sharedOffset = slot - (cast[uint](shared) + SharedTxbufOff)
  if sharedOffset < NxTxDescCnt.uint * SharedTxbufSize and sharedOffset mod SharedTxbufSize == 0:
    return true
  when ExtraTxPacketBuffers > 0:
    let extraOffset = slot - cast[uint](addr extraTxPackets[0])
    return extraOffset < sizeof(extraTxPackets).uint and extraOffset mod SharedTxbufSize == 0

proc ipcHostTxDmaInit(env: pointer) =
  txDmaEnv = env
  zeroMem(addr txDmaRecords, sizeof(txDmaRecords))
  zeroMem(addr extraTxPackets, sizeof(extraTxPackets))
  txDmaCredit = default(typeof(txDmaCredit))
  txDmaFree = TxDmaAllFree

proc returnTxHostSlot(index: int): bool {.inline.} =
  # Caller has the IRQ lock. Detach before publishing the reusable credit.
  let credit = txDmaCredit[index]
  if credit == nil:
    return false
  txDmaCredit[index] = nil
  listPushBack(loadPtr(txDmaEnv, EnvListFreeOff), credit)
  inc ipcHostTxResources.releases
  true

proc ipcHostTxPrimaryDone*(record: pointer; waitingForSuccessor: bool): bool =
  # Called with IRQs masked, before any confirmation can reenter the driver.
  # The DMA record and its packet stay allocated through the old reclaim path.
  let index = ipcHostTxDmaIndex(record)
  if index < 0 or not returnTxHostSlot(index):
    return false
  inc txHostDoneReturns
  if waitingForSuccessor:
    inc txHostLinkedDoneReturns
  true
