# The stamp of a host SM_DISCONNECT_REQ.
#
# The request names a STA VIF by index. Pinned sm_task.o saves it while SM is
# busy and later reads only the index, which may by then name another link:
# a new attempt was admitted on that VIF, or the VIF was removed and added
# again. ke_msg_send stamps the request with the generation of the VIF it
# names (rxVifEpochs, advanced by every connect admission on the VIF and by
# its removal), kept in a private tail of the allocation so that the one-byte
# request ABI is unchanged. sm_disconnect_req_handler acts on the request
# only while that generation is current (smDisconnectCurrent).
#
# SM_CONNECT_ABORT_REQ needs no stamp: it is answered in place and never
# saved, so it acts on the attempt that is live when it is dispatched.
#
# The stamps are kept and read only in task context: no interrupt handler
# allocates, sends or frees a kernel message (they post events), so the list
# takes no IRQ lock.

type SmDisconnectStamp = object
  next: ptr SmDisconnectStamp
  header: ptr KeMsgHdr
  stamped: bool     ## ke_msg_send has recorded the fields below
  vif: uint8        ## the STA VIF the request named then, or 0xFF
  vifEpoch: uint32  ## that VIF's generation then

var smDisconnectStamps {.wifiCtrl.}: ptr SmDisconnectStamp

proc smIsDisconnectRequest(id: uint16; destination: uint8): bool {.inline.} =
  id == SM_DISCONNECT_REQ and destination == TASK_SM

proc smDisconnectStorageLength(id: uint16; destination: uint8; length: uint32): uint32 =
  ## ke_msg_try_alloc: the storage a request needs, with room for its stamp.
  if not smIsDisconnectRequest(id, destination) or length == 0:
    return length
  const alignment = alignof(SmDisconnectStamp).uint32
  const overhead = KeMsgTailSlack + alignment - 1 + sizeof(SmDisconnectStamp).uint32
  if length > high(uint32) - overhead: return high(uint32)
  ((length + KeMsgTailSlack + alignment - 1) and not (alignment - 1)) +
    sizeof(SmDisconnectStamp).uint32

proc smDisconnectRegister(header: ptr KeMsgHdr) =
  ## ke_msg_try_alloc: list the new request's stamp, not yet recorded.
  if not smIsDisconnectRequest(header.id, header.destId) or header.paramLen == 0:
    return
  const alignment = alignof(SmDisconnectStamp).uint32
  let offset = (header.paramLen + KeMsgTailSlack + alignment - 1) and not (alignment - 1)
  let stamp = cast[ptr SmDisconnectStamp](cast[uint](keMsgPayload(header)) + offset.uint)
  stamp[] = SmDisconnectStamp(next: smDisconnectStamps, header: header)
  smDisconnectStamps = stamp

proc smDisconnectForget(header: pointer) =
  ## ke_msg_free.
  var link = addr smDisconnectStamps
  while link[] != nil:
    if link[].header == header:
      link[] = link[].next
      return
    link = addr link[].next

proc smDisconnectFind(header: ptr KeMsgHdr): ptr SmDisconnectStamp =
  result = smDisconnectStamps
  while result != nil and result.header != header: result = result.next

proc smDisconnectStamp(header: ptr KeMsgHdr) =
  ## ke_msg_send: record, once, the STA VIF the request names and its
  ## generation.
  if not smIsDisconnectRequest(header.id, header.destId): return
  let stamp = smDisconnectFind(header)
  if stamp == nil or stamp.stamped: return
  stamp.stamped = true
  stamp.vif = 0xFF
  let vifIdx = cast[ptr uint8](keMsgPayload(header))[]
  if header.paramLen == 1 and vifIdx < MAX_VIFS.uint8 and
      vifChannelForIdx(vifIdx).vifIdx == vifIdx and
      vifChannelForIdx(vifIdx).vifType == VIF_TYPE_STA:
    stamp.vif = vifIdx
    stamp.vifEpoch = rxVifEpochs[vifIdx]

proc smDisconnectCurrent(request: pointer): bool =
  ## sm_disconnect_req_handler: the request still names the STA VIF, of the
  ## same generation, it named when it was sent. One that did not pass
  ## through ke_msg_send is stamped now.
  let header = keMsgHdrFromPayload(request)
  smDisconnectStamp(header)
  let stamp = smDisconnectFind(header)
  stamp != nil and stamp.vif < MAX_VIFS.uint8 and header.paramLen == 1 and
    cast[ptr uint8](request)[] == stamp.vif and
    rxVifEpochs[stamp.vif] == stamp.vifEpoch and
    vifChannelForIdx(stamp.vif).vifIdx == stamp.vif and
    vifChannelForIdx(stamp.vif).vifType == VIF_TYPE_STA
