# ###########################################################################
#                  BAM: Block ACK Management
# ###########################################################################

proc bam_init*() {.exportc, cdecl.} =
  ## Initialize block ACK management.
  ## From disassembly: stores 0xFF to bamStaIdx (no active BA session),
  ## then tail-calls ke_state_set(TASK_BAM, 0).
  bamStaIdx = 0xFF'u8
  ke_state_set(TASK_BAM, BamIdleState)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void bam_send_air_action_frame(unsigned char,unsigned char,unsigned char,unsigned char,unsigned short,unsigned char,void*);".}
proc bam_send_air_action_frame*(staIdx: uint8, tid: uint8, isAddba: uint8,
    dialogToken: uint8, statusCode: uint16, extraFlags: uint8,
    txCallback: pointer) {.exportc, cdecl.} =
  ## Send ADDBA/DELBA action frame over the air (177 instructions).
  ##
  ## From disassembly register mapping:
  ##   a0 = staIdx (s4), a1 = tid (s1), a2 = isAddba (s9),
  ##   a3 = dialogToken (s7), a4 = statusCode (saved to sp+8),
  ##   a5 = extraFlags (s8), a6 = txCallback (s2)
  ##
  ## Allocates a 512-byte frame, fills in action frame header
  ## (ADDBA req/rsp or DELBA), builds frame body via me_build_add_ba_req/del_ba,
  ## then pushes to TX with AC=3.

  # Get VIF index from sta_info_tab[staIdx]+39
  let sta = staInfoForIdx(staIdx)
  let staEntry = cast[uint](sta)
  let vifIdx = sta.instNbr

  let vif = vifChannelForIdx(vifIdx)

  # Allocate TX frame from frame pool (blob: txl_frame_get at 0x46)
  let frame = txl_frame_get(512)
  if frame == nil:
    return

  let desc = hostTxDescAt(frame)

  # Update TX power (blob: tpc_update_frame_tx_power at 0x6E)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)

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
  let staType = cast[ptr uint8](staEntry + 86)[]
  if staType == 2:
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
  if mfpResult == 1:
    txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 24)
    let secHdrLen = desc.hdrLen
    hdrLen += secHdrLen.uint32

  # Call appropriate build function based on isAddba
  var bodyLen: uint32 = 0
  if isAddba == 1:
    # Build ADDBA response (blob: me_build_add_ba_rsp at 0x172)
    let bodyPtr = cast[pointer](addr link.macHeader[hdrLen])
    bodyLen = me_build_add_ba_rsp(bodyPtr, cast[pointer](tid.uint),
                                  statusCode, dialogToken, extraFlags.uint16)
  elif isAddba == 0:
    # Build ADDBA request
    let bodyPtr = cast[pointer](addr link.macHeader[hdrLen])
    bodyLen = me_build_add_ba_req(bodyPtr, nil)
  else:
    assert_err("bam.c", "bam.c", 589)

  # Compute total payload length
  hdrLen += bodyLen
  let extraPad = desc.secTailLen
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
    desc.callbackArg = cast[pointer](cast[uint](tid))

  # Push frame to TX with AC=3 (voice), tail call
  txl_frame_push(frame, 3)

