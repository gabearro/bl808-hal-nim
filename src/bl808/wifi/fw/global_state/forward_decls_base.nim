# Forward declarations for functions used before their definition
proc ipc_emb_msg_push*(msgDescPtr: pointer) {.exportc, cdecl.}
proc assert_rec*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.}
proc blmac_soft_reset_getf*(): uint8 {.exportc, cdecl, noinline.}
proc crm_get_mac_freq(): uint32 {.exportc, cdecl.}
proc phy_get_mac_freq*(): uint32 {.exportc, cdecl.} =
  crm_get_mac_freq()
proc rxl_timeout_int_handler*() {.exportc, cdecl.}
proc mm_sec_machwaddr_wr*(staIdx: uint8, keySlotRaw: pointer,
                          unusedCompatArg: uint8): uint8 {.exportc, cdecl, discardable.}
proc mm_sec_machwkey_wr*(param: pointer) {.exportc, cdecl.}
proc sta_mgmt_register*(param: pointer, staIdxOut: ptr uint8): uint8 {.exportc, cdecl.}
proc sta_mgmt_unregister*(staIdx: uint8) {.exportc, cdecl.}
proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.}
proc mm_ap_probe_cfm*(param: pointer) {.exportc, cdecl.}
proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.}
proc rxu_cntrl_frame_handle*(param: pointer): uint32 {.exportc, cdecl.}
proc rxu_cntrl_desc_prepare*(swdesc: pointer) {.exportc, cdecl, noinline.}
proc rxu_mpdu_upload_and_indicate*(param: pointer) {.exportc, cdecl.}

## rxu_cntrl_env: static context structure used by the RX upper control path.
## Declared before RX lower reset so typed overlays can reference uploadList.
var rxu_cntrl_env* {.exportc.}: array[96, uint8]

proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.}
proc txu_cntrl_frame_build*(desc: pointer, bufPtr: pointer) {.exportc, cdecl.}
proc txl_cfm_flush_desc*(desc: pointer) {.exportc, cdecl.}
proc ipc_emb_tx_evt*(ac: uint32) {.exportc, cdecl.}
proc rxl_mpdu_transfer*(desc: pointer) {.exportc, cdecl.}
proc rxu_mgt_frame_check*(param: pointer, vifIdxArg: uint8): uint32 {.exportc, cdecl.}
proc me_build_associate_req_impl(buf: pointer, assocInfo: pointer,
    reassocBssid: pointer, capParam: pointer, cursorOut: pointer,
    bodyLenOut: pointer, connInfo: pointer): uint32 {.exportc: "me_build_associate_req", cdecl.}
# Nim-side wrapper so existing Nim callers (single pointer) still compile:
template me_build_associate_req*(frame: pointer): uint32 =
  me_build_associate_req_impl(frame, nil, nil, nil, nil, nil, nil)
proc me_build_add_ba_req*(buf: pointer, param: pointer): uint32 {.exportc, cdecl.}
proc txl_frame_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl, noinline, discardable.}
proc txl_frame_get*(length: uint32): pointer {.exportc, cdecl.}
proc txl_tx_desc_pointer_plausible(txDescPointer: pointer): bool
proc txl_frame_rebuild_free_list(): uint32
proc txl_get_seq_ctrl*(): uint16 {.exportc, cdecl.}
proc wifi_nimfw_prepare_sta_tx_channel*() {.exportc, cdecl.}
proc tpc_update_frame_tx_power*(env: pointer, frameDesc: pointer) {.exportc, cdecl.}
proc txu_cntrl_protect_mgmt_frame*(param: pointer, hdrPtr: pointer, extraLen: uint32) {.exportc, cdecl.}
proc txu_cntrl_sechdr_len_compute*(txDesc: pointer, lenOut: ptr uint32): uint32 {.exportc, cdecl.}
proc txu_cntrl_sec_hdr_append*(txDesc: pointer, secHdr: pointer,
                               updateCurrentDesc: uint32): pointer {.exportc, cdecl.}
proc td_pck_ind*(vifIdx: uint8, direction: uint32) {.exportc, cdecl.}
proc sm_disconnect_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.}
proc sm_connect_abort_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.}
proc hsu_aes_cmac*(key: pointer, msg: pointer, msgLen: uint32, mac: pointer) {.exportc, cdecl.}
proc mm_sec_macrx_ind*(staIdx: uint8, payload: pointer, length: uint16) {.exportc, cdecl.}
proc chan_bcn_detect_start*(vifEntry: pointer) {.exportc, cdecl.}
proc chan_ctxt_trigger*(ctxt: pointer) {.exportc, cdecl.}
proc scanu_confirm*(status: uint8) {.exportc, cdecl.}
