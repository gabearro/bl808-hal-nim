# ###########################################################################
#                  BAM: Block ACK Management
# ###########################################################################

proc bam_init*() {.exportc, cdecl.} =
  ## Initialize block ACK management.
  ## From disassembly: stores 0xFF at bam_env+12 (no active BA session),
  ## then tail-calls ke_state_set(TASK_BAM, 0).
  bamEnvView().staIdx = 0xFF'u8
  ke_state_set(TASK_BAM, BamIdleState)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bam_send_air_action_frame(unsigned char,void*,unsigned char,unsigned char,unsigned short,unsigned short,void*);".}
proc bam_send_air_action_frame*(staIdx: uint8, baEnv: pointer, action: uint8,
    dialogToken: uint8, baParams: uint16, statusCode: uint16,
    txCallback: pointer) {.exportc, cdecl.} =
  ## The pinned vendor supports only ADDBA responses here. Its second argument
  ## is the BA environment pointer, also passed intact to the TX callback.
  let saved = irqSave()
  defer: irqRestore(saved)
  if action != 1 or staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  if sta.valid == 0 or vifIdx >= MAX_VIFS.uint8:
    return
  let vif = vifChannelForIdx(vifIdx)
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: staIdx,
    vifEpoch: rxVifEpochs[vifIdx], stationEpoch: staDeleteEpoch(staIdx),
    resetEpoch: txResetEpoch)

  # Allocate TX frame from frame pool (blob: txl_frame_get at 0x46)
  let frame = txl_frame_get(512)
  if frame == nil:
    return

  let desc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(desc)
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx
  if not txlFramePreparationCurrent(desc, identity, generation):
    return

  # Update TX power (blob: tpc_update_frame_tx_power at 0x6E)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return

  # The MAC header lives in the link descriptor, not inline in the frame
  # descriptor. Writing at frame+348 corrupts the frame pool metadata.
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Set frame control: Action frame = 0xD0
  hdr.frameControl = 0x00D0'u16
  hdr.duration = 0

  # Copy addresses from sta and vif entries
  # Addr2 (SA) = VIF MAC at vifEntry+80
  # Addr3 (BSSID) = same as DA for infrastructure mode

  # MAC address fields start at offsets 4, 10, and 16. Offset 10 is not
  # 32-bit aligned on BL808, so use byte-safe copies instead of word stores.
  discard c_memcpy(addr hdr.addr1[0], addr sta.macAddr[0], 6.csize_t)
  discard c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)
  if vif.vifType == VIF_TYPE_AP:
    discard c_memcpy(addr hdr.addr3[0], addr vif.macAddr[0], 6.csize_t)
  else:
    discard c_memcpy(addr hdr.addr3[0], addr sta.macAddr[0], 6.csize_t)

  let seqField = nextTxSeqCtrl()
  hdr.seqCtrl = seqField

  # Store staIdx and vifIdx into frame descriptor
  desc.staInfoIdx = staIdx
  desc.vifIdx = vifIdx

  # Clear counters
  desc.hdrLen = 0       # extra IE length
  desc.secTailLen = 0   # padding

  # Read frame control back to compute total header size
  var hdrLen: uint32 = 24  # standard MAC header

  # Management frame protection. For BA action frames the category is 3.
  # The blob only inserts a security header when MFP returns CCMP (1); in that
  # case the BA body starts after the protected-management header extension.
  let mfpResult = mfp_protect_mgmt_frame(frame, hdr.frameControl.uint32, 3'u32)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return
  if mfpResult == 1:
    txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 24)
    if not txlFramePreparationCurrent(desc, identity, generation):
      return
    if desc.hdrLen != 8 or desc.secTailLen != 8:
      txl_frame_release(frame, false)
      return
    let secHdrLen = desc.hdrLen
    hdrLen += secHdrLen.uint32

  if hdrLen > TxlFramePayloadSize - 9'u32:
    txl_frame_release(frame, false)
    return
  let bodyPtr = cast[pointer](addr link.macHeader[hdrLen])
  let bodyLen = me_build_add_ba_rsp(bodyPtr, baEnv, baParams,
                                   dialogToken, statusCode)
  if not txlFramePreparationCurrent(desc, identity, generation):
    return

  # Compute total payload length
  let extraPad = desc.secTailLen.uint32
  if bodyLen > TxlFramePayloadSize - hdrLen or
      extraPad > TxlFramePayloadSize - hdrLen - bodyLen:
    txl_frame_release(frame, false)
    return
  hdrLen += bodyLen
  hdrLen += extraPad.uint32

  # Update TX descriptor lengths
  let txDesc = hostTxHwDescAt(desc.hwDesc)
  let oldPayLen = txDesc.payloadStart
  txDesc.payloadEnd = oldPayLen + hdrLen - 1
  let totalLen = hdrLen + 4  # +4 for FCS
  txDesc.frameLen = totalLen

  # Store TX callback if provided
  if txCallback != nil:
    desc.callback = txCallback
    desc.callbackArg = baEnv

  # Push frame to TX with AC=3 (voice), tail call
  txl_frame_push(frame, 3)

