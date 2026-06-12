var nimFwDbgFrameTraceCount {.wifiCtrl.}: uint32
var nimFwDbgIpcTxTraceCount {.wifiCtrl.}: uint32
var nimFwDbgCfmTraceCount {.wifiCtrl.}: uint32
var nimFwDbgEapolTraceCount {.wifiCtrl.}: uint32
# TX-path investigation counters (iter 261). Read after test via UART dump.
var nimFwDbgPayBackupEntry* {.wifiCtrl, exportc: "nimfw_dbg_pay_backup".}: uint32
var nimFwDbgPayDescFound*   {.wifiCtrl, exportc: "nimfw_dbg_pay_desc".}: uint32
var nimFwDbgPayHasPayload*  {.wifiCtrl, exportc: "nimfw_dbg_pay_payload".}: uint32
var nimFwDbgPayEmptyList*   {.wifiCtrl, exportc: "nimfw_dbg_pay_empty".}: uint32
var nimFwDbgPayNonEmpty*    {.wifiCtrl, exportc: "nimfw_dbg_pay_nonempty".}: uint32
var nimFwDbgPayTriggerLast* {.wifiCtrl, exportc: "nimfw_dbg_pay_trig".}: uint32
var nimFwDbgPayTxStatus* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_status".}: uint32
var nimFwDbgPayTxAgg* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_agg".}: uint32
var nimFwDbgPayTxDma* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_dma".}: uint32
var nimFwDbgPayTxCurrent* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_current".}: uint32
var nimFwDbgPayTxThd* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_thd".}: uint32
var nimFwDbgPayTxHead* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_head".}: uint32
var nimFwDbgProbePayMeta* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_meta".}: uint32
var nimFwDbgProbePayDesc* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_desc".}: uint32
var nimFwDbgProbePayLink* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link".}: uint32
var nimFwDbgProbePayHw* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw".}: uint32
var nimFwDbgProbePayThd* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_thd".}: uint32
var nimFwDbgProbePayLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_len".}: uint32
var nimFwDbgProbePayHwConfirmDescPtr* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw0".}: uint32
var nimFwDbgProbePayHwMagic* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw1".}: uint32
var nimFwDbgProbePayHwSecondaryDescPtr* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw2".}: uint32
var nimFwDbgProbePayHwSecondaryStatusPadding* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw3".}: uint32
var nimFwDbgProbePayLinkHeaderLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link0".}: uint32
var nimFwDbgProbePayLinkTxControlXor* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link1".}: uint32
var nimFwDbgProbePayHwStart* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_start".}: uint32
var nimFwDbgProbePayHwEnd* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_end".}: uint32
var nimFwDbgProbePayHwFrameLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_frame_len".}: uint32
var nimFwDbgProbePayHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_status".}: uint32
var nimFwDbgProbePayHwCtrl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_ctrl".}: uint32
var nimFwDbgProbePayHwChain* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_chain".}: uint32
var nimFwDbgProbePayHwRetryLimitControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_retry_limit_control".}: uint32
var nimFwDbgProbePayHwAckPolicyControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_ack_policy_control".}: uint32
var nimFwDbgProbePayHwCompatRetryLimitControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_word36".}: uint32
var nimFwDbgProbePayHwCompatAckPolicyControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_word56".}: uint32
var nimFwDbgProbePayRaw* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_raw".}: array[96, uint8]
var nimFwDbgProbeIeLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_ie_len".}: uint32
var nimFwDbgProbeIeRaw* {.wifiCtrl, exportc: "nimfw_dbg_probe_ie_raw".}: array[64, uint8]
var nimFwDbgTxTrigEntry*    {.wifiCtrl, exportc: "nimfw_dbg_txtrig_entry".}: uint32
var nimFwDbgFrameGet*       {.wifiCtrl, exportc: "nimfw_dbg_frame_get".}: uint32
var nimFwDbgFrameGetInvalid* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid".}: uint32
var nimFwDbgFrameGetInvalidPtr* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid_ptr".}: uint32
var nimFwDbgFrameGetInvalidNext* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid_next".}: uint32
var nimFwDbgFrameFreeRebuild* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_rebuild".}: uint32
var nimFwDbgFrameFreeReclaimed* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_reclaimed".}: uint32
var nimFwDbgFrameFreePushInvalid* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_push_invalid".}: uint32
var nimFwDbgTxPendingInvalid* {.wifiCtrl, exportc: "nimfw_dbg_tx_pending_invalid".}: uint32
var nimFwDbgTxPendingInvalidPtr* {.wifiCtrl, exportc: "nimfw_dbg_tx_pending_invalid_ptr".}: uint32
var nimFwDbgTxThdNoBuffer* {.wifiCtrl, exportc: "nimfw_dbg_tx_thd_nobuf".}: uint32
var nimFwDbgTxThdNoBufferDesc* {.wifiCtrl, exportc: "nimfw_dbg_tx_thd_nobuf_desc".}: uint32
var nimFwDbgApmStaAddNoSlot* {.wifiCtrl, exportc: "nimfw_dbg_apm_sta_add_noslot".}: uint32
var nimFwDbgApmStaAddNoSlotSta* {.wifiCtrl, exportc: "nimfw_dbg_apm_sta_add_noslot_sta".}: uint32
var nimFwDbgKeTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_ke_timer_yield".}: uint32
var nimFwDbgKeTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_ke_timer_yield_head".}: uint32
var nimFwDbgMmTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_mm_timer_yield".}: uint32
var nimFwDbgMmTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_mm_timer_yield_head".}: uint32
var nimFwDbgIpcMsgYield* {.wifiCtrl, exportc: "nimfw_dbg_ipc_msg_yield".}: uint32
var nimFwDbgIpcMsgYieldStatus* {.wifiCtrl, exportc: "nimfw_dbg_ipc_msg_yield_status".}: uint32
var nimFwDbgIpcTxYield* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield".}: uint32
var nimFwDbgIpcTxYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield_ac".}: uint32
var nimFwDbgIpcTxYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield_head".}: uint32
var nimFwDbgSavedMsgYield* {.wifiCtrl, exportc: "nimfw_dbg_saved_msg_yield".}: uint32
var nimFwDbgSavedMsgYieldTask* {.wifiCtrl, exportc: "nimfw_dbg_saved_msg_yield_task".}: uint32
var nimFwDbgCfmEvtYield* {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt_yield".}: uint32
var nimFwDbgCfmEvtYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt_yield_ac".}: uint32
var nimFwDbgTxTrigYield* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield".}: uint32
var nimFwDbgTxTrigYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield_ac".}: uint32
var nimFwDbgTxTrigYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield_head".}: uint32
var nimFwDbgTxTrigLastDesc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_desc".}: uint32
var nimFwDbgTxTrigLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_status".}: uint32
var nimFwDbgTxTrigNotReady* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_notready".}: uint32
var nimFwDbgTxTrigNoDesc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_nodesc".}: uint32
var nimFwDbgFrameEvtYield* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_yield".}: uint32
var nimFwDbgFrameEvtYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_yield_head".}: uint32
var nimFwDbgRxTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_rx_timer_yield".}: uint32
var nimFwDbgRxTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_rx_timer_yield_head".}: uint32
var nimFwDbgMacIrq* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq".}: uint32
var nimFwDbgMacIrqLast* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last".}: uint32
var nimFwDbgMacIrqSlot50* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot50".}: uint32
var nimFwDbgMacIrqSlot52* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot52".}: uint32
var nimFwDbgMacIrqSlot53* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot53".}: uint32
var nimFwDbgMacIrqSlot54* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot54".}: uint32
var nimFwDbgMacIrqSlotOther* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot_other".}: uint32
var nimFwDbgMacIrqLastHandler* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_handler".}: uint32
var nimFwDbgMacIrqLastIntRaw* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_int_raw".}: uint32
var nimFwDbgMacIrqLastGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_gen_raw".}: uint32
var nimFwDbgMacIrqLastRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_rxctrl".}: uint32
var nimFwDbgMacIrqLastHd* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_hd".}: uint32
var nimFwDbgMacIrqLastPd* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_pd".}: uint32
var nimFwDbgMachwGen* {.wifiCtrl, exportc: "nimfw_dbg_machw_gen".}: uint32
var nimFwDbgMachwStatus* {.wifiCtrl, exportc: "nimfw_dbg_machw_status".}: uint32
var nimFwDbgMachwGenStatus* {.wifiCtrl, exportc: "nimfw_dbg_machw_gen_status".}: uint32
var nimFwDbgRxlTimerEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_evt".}: uint32
var nimFwDbgRxlTimerReady* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_ready".}: uint32
var nimFwDbgRxlTimerHead* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_head".}: uint32
var nimFwDbgRxlCntrlEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_cntrl_evt".}: uint32
var nimFwDbgRxlCntrlHead* {.wifiCtrl, exportc: "nimfw_dbg_rxl_cntrl_head".}: uint32
var nimFwDbgRxlDmaEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_dma_evt".}: uint32
var nimFwDbgRxlSnapHd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hd".}: uint32
var nimFwDbgRxlSnapPd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_pd".}: uint32
var nimFwDbgRxlSnapHwHd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hw_hd".}: uint32
var nimFwDbgRxlSnapHwPd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hw_pd".}: uint32
var nimFwDbgRxlSnapMask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_mask".}: uint32
var nimFwDbgRxlSnapRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_rxctrl".}: uint32
var nimFwDbgRxlSnapIntUnmask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_int_unmask".}: uint32
var nimFwDbgRxlSnapGenUnmask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_gen_unmask".}: uint32
var nimFwDbgRxlSnapRxCtrlRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_rxctrl_raw".}: uint32
var nimFwDbgRxlSnapStatusRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_status_raw".}: uint32
var nimFwDbgRxlSnapIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_irq_raw".}: uint32
var nimFwDbgRxlSnapGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_gen_raw".}: uint32
var nimFwDbgRxlSnapHdStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hd_status".}: uint32
var nimFwDbgRxlSnapPdStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_pd_status".}: uint32
var nimFwDbgScanStartRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_rxctrl".}: uint32
var nimFwDbgScanStartIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_irq_raw".}: uint32
var nimFwDbgScanStartGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_gen_raw".}: uint32
var nimFwDbgScanEndRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_rxctrl".}: uint32
var nimFwDbgScanEndIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_irq_raw".}: uint32
var nimFwDbgScanEndGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_gen_raw".}: uint32
var nimFwDbgScanReqChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_scan_req_chan_meta".}: uint32
var nimFwDbgScanReqChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_scan_req_chan_freq".}: uint32
var nimFwDbgChanScanChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_chan_scan_chan_meta".}: uint32
var nimFwDbgChanScanChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_chan_scan_chan_freq".}: uint32
var nimFwDbgChanPreChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_chan_pre_chan_meta".}: uint32
var nimFwDbgChanPreChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_chan_pre_chan_freq".}: uint32
var nimFwDbgMacTimingE8* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_e8".}: uint32
var nimFwDbgMacTimingF0* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f0".}: uint32
var nimFwDbgMacTimingF4* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f4".}: uint32
var nimFwDbgMacTimingF8* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f8".}: uint32
var nimFwDbgMacTiming104* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_104".}: uint32
var nimFwDbgScanStartPhyRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_phy_raw".}: array[4, uint32]
var nimFwDbgScanEndPhyRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_phy_raw".}: array[4, uint32]
const NimFwDbgRfPhyTraceLen {.intdefine.} = 8
var nimFwDbgRfPhyTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_count".}: uint32
var nimFwDbgRfPhyTracePhase* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phase".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceDevice* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_device".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_chan_meta".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_chan_freq".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf70* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf70".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf74* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf74".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf2c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf04* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf04".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf34* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf34".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf40* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf40".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf4c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf4c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf88".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf90* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf90".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfa0* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfa0".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfa4* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfa4".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfbc* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfbc".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfd0* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfd0".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf80* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf80".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf84* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf84".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf8c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf8c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfb4* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfb4".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1600* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1600".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1614* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1614".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1618* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1618".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf162c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf162c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1680* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1680".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf113c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf113c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy820* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy820".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy824* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy824".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy830* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy830".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy874* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy874".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rxctrl".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_irqraw".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_genraw".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_pd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHwHd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hwhd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHwPd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hwpd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfCalSaveCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_count".}: uint32
var nimFwDbgRfCalRestoreCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_count".}: uint32
var nimFwDbgRfCalSaveRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_rf88".}: uint32
var nimFwDbgRfCalRestoreRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf88".}: uint32
var nimFwDbgRfCalRestoreReadbackRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_readback_rf88".}: uint32
var nimFwDbgRfCalRestoreRf8c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf8c".}: uint32
var nimFwDbgRfCalSaveRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_rf2c".}: uint32
var nimFwDbgRfCalRestoreRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf2c".}: uint32
var nimFwDbgRfCalRestoreReadbackRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_readback_rf2c".}: uint32
var nimFwDbgRfPhase* {.wifiCtrl, exportc: "nimfw_dbg_rf_phase".}: uint32
var nimFwDbgRfRestore* {.wifiCtrl, exportc: "nimfw_dbg_rf_restore".}: uint32
var nimFwDbgRfApiMode* {.wifiCtrl, exportc: "nimfw_dbg_rf_api_mode".}: uint32
var nimFwDbgPhyInitCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_init_count".}: uint32
var nimFwDbgPhyInitPhase* {.wifiCtrl, exportc: "nimfw_dbg_phy_init_phase".}: uint32
var nimFwDbgPhyModemVersion* {.wifiCtrl, exportc: "nimfw_dbg_phy_modem_version".}: uint32
var nimFwDbgPhyClockCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_clock_count".}: uint32
var nimFwDbgPhyAgcCopyCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_copy_count".}: uint32
var nimFwDbgPhyAgcSourceFirst* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_source_first".}: uint32
var nimFwDbgPhyAgcSourceLast* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_source_last".}: uint32
var nimFwDbgPhyAgcDestFirst* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_dest_first".}: uint32
var nimFwDbgPhyAgcDestLast* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_dest_last".}: uint32
var nimFwDbgPhyWifiLdpcAbsent* {.wifiCtrl, exportc: "nimfw_dbg_phy_wifi_ldpc_absent".}: uint32
var nimFwDbgRfAssertCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_count".}: uint32
var nimFwDbgRfAssertLine* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_line".}: uint32
var nimFwDbgRfAssertReg3c* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_reg3c".}: uint32
var nimFwDbgRfCalPtr* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_ptr".}: uint32
var nimFwDbgRfCalWords* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_words".}: array[8, uint32]
var nimFwDbgRxuDescPrepare* {.wifiCtrl, exportc: "nimfw_dbg_rxu_desc_prepare".}: uint32
var nimFwDbgRxuUploadEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_evt".}: uint32
var nimFwDbgRxuUploadEntry* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_entry".}: uint32
var nimFwDbgRxuUploadTcpipOk* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_tcpip_ok".}: uint32
var nimFwDbgRxuUploadTcpipFail* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_tcpip_fail".}: uint32
var nimFwDbgRxuUploadFrame* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_frame".}: uint32
var nimFwDbgRxuFrameValid* {.wifiCtrl, exportc: "nimfw_dbg_rxu_frame_valid".}: uint32
var nimFwDbgRxuAssocData* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_data".}: uint32
var nimFwDbgRxuAssocEapol* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_eapol".}: uint32
var nimFwDbgRxuAssocUploadReady* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_upload_ready".}: uint32
var nimFwDbgRxuAssocMgmt* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_mgmt".}: uint32
var nimFwDbgRxuNonassocData* {.wifiCtrl, exportc: "nimfw_dbg_rxu_nonassoc_data".}: uint32
var nimFwDbgRxuDropInvalid* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_invalid".}: uint32
var nimFwDbgRxuDropStaInactive* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_sta_inactive".}: uint32
var nimFwDbgRxuDropFtype* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_ftype".}: uint32
var nimFwDbgRxuDropNull* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null".}: uint32
var nimFwDbgRxuDropDup* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup".}: uint32
var nimFwDbgRxuDropPn* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_pn".}: uint32
var nimFwDbgRxuProtType* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_type".}: uint32
var nimFwDbgRxuProtKey* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_key".}: uint32
var nimFwDbgRxuProtPnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_pn_lo".}: uint32
var nimFwDbgRxuProtPnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_pn_hi".}: uint32
var nimFwDbgRxuPnMeta* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_meta".}: uint32
var nimFwDbgRxuPnStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_stored_lo".}: uint32
var nimFwDbgRxuPnStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_stored_hi".}: uint32
var nimFwDbgRxuPnNextLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_next_lo".}: uint32
var nimFwDbgRxuPnNextHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_next_hi".}: uint32
var nimFwDbgRxuDataFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_data_fc".}: uint32
var nimFwDbgRxuDataSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_data_seq".}: uint32
var nimFwDbgRxuLastHwFlags* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_hwflags".}: uint32
var nimFwDbgRxuLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_status".}: uint32
var nimFwDbgRxuLastLen* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_len".}: uint32
var nimFwDbgRxuSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_snap_lo".}: uint32
var nimFwDbgRxuSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_snap_hi".}: uint32
var nimFwDbgRxuAssocSnap* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_snap".}: uint32
var nimFwDbgRxuAssocIp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_ip".}: uint32
var nimFwDbgRxuAssocArp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_arp".}: uint32
var nimFwDbgRxuAssocOther* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_other".}: uint32
var nimFwDbgRxuAssocUdp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_udp".}: uint32
var nimFwDbgRxuAssocTcp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp".}: uint32
var nimFwDbgRxuAssocTcp80* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp80".}: uint32
var nimFwDbgRxuAssocLastIpProto* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_ip_proto".}: uint32
var nimFwDbgRxuAssocLastTcpPorts* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_tcp_ports".}: uint32
var nimFwDbgRxuAssocLastTcpFlags* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_tcp_flags".}: uint32
var nimFwDbgRxuAssocTcpMeta* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp_meta".}: uint32
var nimFwDbgRxuAssocTcpRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp_raw".}: array[64, uint8]
var nimFwDbgRxuDropNullFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null_fc".}: uint32
var nimFwDbgRxuDropNullSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null_seq".}: uint32
var nimFwDbgRxuDropDupFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup_fc".}: uint32
var nimFwDbgRxuDropDupSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup_seq".}: uint32
const RxuDupTraceEntries = 8
var nimFwDbgRxuDupTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_count".}: uint32
var nimFwDbgRxuDupTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_fc".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_seq".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceCache* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_cache".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_snap_lo".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_snap_hi".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceAddr0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_addr0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceAddr1* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_addr1".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceIp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_ip0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_udp0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootp1* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp1".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp_yiaddr".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_dhcp_msg".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_dhcp_server".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupBreakHits* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_break_hits".}: uint32
const RxuPnDropTraceEntries = 8
var nimFwDbgRxuPnDropTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_count".}: uint32
var nimFwDbgRxuPnDropTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_fc".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_seq".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTracePnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_pn_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTracePnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_pn_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_stored_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_stored_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_snap_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_snap_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_udp0".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_bootp_yiaddr".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_msg".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_server".}: array[RxuPnDropTraceEntries, uint32]
const RxuPnAcceptTraceEntries = 8
var nimFwDbgRxuPnAcceptTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_count".}: uint32
var nimFwDbgRxuPnAcceptTraceStage* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stage".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_fc".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_seq".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTracePnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_pn_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTracePnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_pn_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stored_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stored_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceNextLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_next_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceNextHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_next_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_snap_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_snap_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_udp0".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_bootp_yiaddr".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_msg".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_server".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgSetKey0* {.wifiCtrl, exportc: "nimfw_dbg_setkey0".}: uint32
var nimFwDbgSetKey1* {.wifiCtrl, exportc: "nimfw_dbg_setkey1".}: uint32
var nimFwDbgSetKey2* {.wifiCtrl, exportc: "nimfw_dbg_setkey2".}: uint32
var nimFwDbgSetKey3* {.wifiCtrl, exportc: "nimfw_dbg_setkey3".}: uint32
var nimFwDbgMachwKeyWrCalls* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_calls".}: uint32
var nimFwDbgMachwKeyWrGroup* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_group".}: uint32
var nimFwDbgMachwKeyWrPair* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair".}: uint32
var nimFwDbgMachwKeyWrLast0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_last0".}: uint32
var nimFwDbgMachwKeyWrLast1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_last1".}: uint32
var nimFwDbgMachwKeyWrPair0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair0".}: uint32
var nimFwDbgMachwKeyWrPair1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair1".}: uint32
var nimFwDbgMachwKeyWrPair2* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair2".}: uint32
var nimFwDbgMachwKeyWrPair3* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair3".}: uint32
var nimFwDbgMachwKeyWrPair4* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair4".}: uint32
var nimFwDbgMachwKeyWrPair5* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair5".}: uint32
var nimFwDbgMachwKeyWrPairCtrl* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair_ctrl".}: uint32
var nimFwDbgMachwKeyWrRead0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read0".}: uint32
var nimFwDbgMachwKeyWrRead1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read1".}: uint32
var nimFwDbgMachwKeyWrRead2* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read2".}: uint32
var nimFwDbgMachwKeyWrRead3* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read3".}: uint32
var nimFwDbgMachwKeyWrReadCtrl* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read_ctrl".}: uint32
var nimFwDbgStaAddKeyCalls* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_calls".}: uint32
var nimFwDbgStaAddKeyMeta* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_meta".}: uint32
var nimFwDbgStaAddKeyPtrs0* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs0".}: uint32
var nimFwDbgStaAddKeyPtrs1* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs1".}: uint32
var nimFwDbgStaAddKeyPtrs2* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs2".}: uint32
var nimFwDbgTxSecHdrStaKey0* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key0".}: uint32
var nimFwDbgTxSecHdrStaKey1* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key1".}: uint32
var nimFwDbgTxSecHdrStaKey2* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key2".}: uint32
var nimFwDbgRcUpdateCalls* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_calls".}: uint32
var nimFwDbgRcUpdateMeta* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_meta".}: uint32
var nimFwDbgRcUpdateArgs* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_args".}: uint32
var nimFwDbgRcUpdateSlot* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_slot".}: uint32
var nimFwDbgRcUpdateEntry* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_entry".}: uint32
var nimFwDbgRcUpdateCounts* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_counts".}: uint32
var nimFwDbgRcUpdateFail* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_fail".}: uint32
# Recycle / CFM path counters (iter 261 follow-up)
var nimFwDbgCfmPush*        {.wifiCtrl, exportc: "nimfw_dbg_cfm_push".}: uint32
var nimFwDbgCfmEvt*         {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt".}: uint32
var nimFwDbgFrameCfm*       {.wifiCtrl, exportc: "nimfw_dbg_frame_cfm".}: uint32
var nimFwDbgFrameRelease*   {.wifiCtrl, exportc: "nimfw_dbg_frame_release".}: uint32
var nimFwDbgTxTrigAcReady*  {.wifiCtrl, exportc: "nimfw_dbg_txtrig_acready".}: uint32  # last acReady seen
var nimFwDbgTxTrigZeroExit* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_zero".}: uint32     # entered & acReady==0
var nimFwDbgTxTrigLoops*    {.wifiCtrl, exportc: "nimfw_dbg_txtrig_loops".}: uint32    # inner loop iters
var nimFwDbgFrameEvtEnter*  {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_enter".}: uint32
var nimFwDbgFrameEvtPop*    {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_pop".}: uint32
var nimFwDbgFrameEvtFreeRet* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_free".}: uint32
var nimFwDbgFrameEvtUsedSkip* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_usedskip".}: uint32
var nimFwDbgFrameEvtCallback* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_cb".}: uint32
var nimFwDbgFrameGetFails*    {.wifiCtrl, exportc: "nimfw_dbg_frame_get_fails".}: uint32
var nimFwDbgNullFrameCalls*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_calls".}: uint32
var nimFwDbgNullFrameCallerRA* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_caller_ra".}: uint32
var nimFwDbgTxRouteInternal*  {.wifiCtrl, exportc: "nimfw_dbg_tx_route_internal".}: uint32
var nimFwDbgTxRouteHost*      {.wifiCtrl, exportc: "nimfw_dbg_tx_route_host".}: uint32
var nimFwDbgTxRouteUsedFlag*  {.wifiCtrl, exportc: "nimfw_dbg_tx_route_usedflag".}: uint32
var nimFwDbgFrameGetUsedBefore* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_used_before".}: uint32
var nimFwDbgNullFrameCfm*     {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cfm".}: uint32
var nimFwDbgNullFrameAckOk*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_ack_ok".}: uint32
var nimFwDbgNullFrameAckFail* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_ack_fail".}: uint32
var nimFwDbgNullFrameLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_status".}: uint32
var nimFwDbgNullFrameDescLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_desc".}: uint32
var nimFwDbgNullFrameBufLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_buf".}: uint32
var nimFwDbgNullFrameFcLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fc".}: uint32
var nimFwDbgNullFramePushRc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_push_rc".}: uint32
var nimFwDbgNullFrameReturn* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_return".}: uint32
var nimFwDbgNullFrameVifSta* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_vif_sta".}: uint32
var nimFwDbgNullFrameCbSet*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cb_set".}: uint32
var nimFwDbgNullFrameCbSetPtr* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cb_set_ptr".}: uint32
var nimFwDbgNullFrameEvtSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_seen".}: uint32
var nimFwDbgNullFrameEvtCbNil* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_cb_nil".}: uint32
var nimFwDbgNullFrameEvtCbPtr* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_cb_ptr".}: uint32
var nimFwDbgNullFrameEvtDesc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_desc".}: uint32
var nimFwDbgNullFrameTxTrigSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_seen".}: uint32
var nimFwDbgNullFrameTxTrigHost* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_host".}: uint32
var nimFwDbgNullFrameTxTrigInternal* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_internal".}: uint32
var nimFwDbgNullFrameTxTrigUsedFlag* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_usedflag".}: uint32
var nimFwDbgNullFrameBusyTxCheck* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_busy_txcheck".}: uint32
var nimFwDbgNullFrameBusyPsCheck* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_busy_pscheck".}: uint32
var nimFwDbgNullFramePaySeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_seen".}: uint32
var nimFwDbgNullFramePayHasPayload* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_payload".}: uint32
var nimFwDbgNullFramePayEmpty* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_empty".}: uint32
var nimFwDbgNullFramePayNonEmpty* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_nonempty".}: uint32
var nimFwDbgNullFramePayAc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_ac".}: uint32
var nimFwDbgNullFramePayTrigger* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_trig".}: uint32
var nimFwDbgNullFramePayCurrent* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_current".}: uint32
var nimFwDbgNullFramePayPending* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_pending".}: uint32
var nimFwDbgNullFramePayThdStatus* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_thd_status".}: uint32
var nimFwDbgNullFramePostponed* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_postponed".}: uint32
var nimFwDbgNullFrameQueued* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_queued".}: uint32
var nimFwDbgPostponedServiceCalls* {.wifiCtrl, exportc: "nimfw_dbg_postponed_service_calls".}: uint32
var nimFwDbgPostponedServiceSent* {.wifiCtrl, exportc: "nimfw_dbg_postponed_service_sent".}: uint32
var nimFwDbgNullFrameTxIntSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_seen".}: uint32
var nimFwDbgNullFrameTxIntFc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_fc".}: uint32
var nimFwDbgNullFrameTxIntBuf* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_buf".}: uint32
var nimFwDbgNullFrameFakeSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_seen".}: uint32
var nimFwDbgNullFrameFakeQidx* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_qidx".}: uint32
var nimFwDbgNullFrameFakeHeadBefore* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_head_before".}: uint32
var nimFwDbgNullFrameFakeTailBefore* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_tail_before".}: uint32
var nimFwDbgNullFrameFakeHeadAfter* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_head_after".}: uint32
var nimFwDbgNullFrameFakeTailAfter* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_tail_after".}: uint32
var nimFwDbgNullFrameFakeLink* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_link".}: uint32
var nimFwDbgPostponedRelease* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release".}: uint32
var nimFwDbgPostponedReleaseCb* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_cb".}: uint32
var nimFwDbgPostponedReleaseDesc* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_desc".}: uint32
var nimFwDbgPostponedReleaseFc* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_fc".}: uint32
var nimFwDbgPostponedReleaseFlags* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_flags".}: uint32
var nimFwDbgPostponedReconcile* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile".}: uint32
var nimFwDbgPostponedReconcileOld* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile_old".}: uint32
var nimFwDbgPostponedReconcileNew* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile_new".}: uint32
var nimFwDbgAutoNullSkipped* {.wifiCtrl, exportc: "nimfw_dbg_auto_null_skipped".}: uint32
var nimFwDbgTxStalledInternalRecover* {.wifiCtrl, exportc: "nimfw_dbg_tx_stalled_internal_recover".}: uint32
var nimFwDbgTxRecoverAc* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_ac".}: uint32
var nimFwDbgTxRecoverPending* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_pending".}: uint32
var nimFwDbgTxRecoverCurrentBefore* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_current_before".}: uint32
var nimFwDbgTxRecoverCurrentAfter* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_current_after".}: uint32
var nimFwDbgTxRecoverBackupBefore* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_before".}: uint32
var nimFwDbgTxRecoverBackupAfterFake* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_after_fake".}: uint32
var nimFwDbgTxRecoverBackupAfterPay* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_after_pay".}: uint32
var nimFwDbgTxRecoverDescBuf* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_desc_buf".}: uint32
var nimFwDbgTxRecoverDescCb* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_desc_cb".}: uint32
var nimFwStaTxChannelPrepareEnabled* {.wifiCtrl, exportc: "nimfw_sta_tx_channel_prepare_enabled".}: uint32
var nimFwBleWifiRoleWindowEnabled* {.wifiCtrl, exportc: "nimfw_ble_wifi_role_window_enabled".}: uint32
var nimFwBleWifiRoleWindowActive* {.wifiCtrl, exportc: "nimfw_ble_wifi_role_window_active".}: uint32
var nimFwDbgBleWifiRoleEnter* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_enter".}: uint32
var nimFwDbgBleWifiRoleLeave* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_leave".}: uint32
var nimFwDbgBleWifiRoleLastCtrl* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_ctrl".}: uint32
var nimFwDbgBleWifiRoleLastCtrl2* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_ctrl2".}: uint32
var nimFwDbgBleWifiRoleLastMirror* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_mirror".}: uint32
var nimFwDbgBleWifiTxPreBcn* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_bcn".}: uint32
var nimFwDbgBleWifiTxPrePti* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_pti".}: uint32
var nimFwDbgBleWifiTxPreStat* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_stat".}: uint32
var nimFwDbgBleWifiTxTrigStat* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_trig_stat".}: uint32
var nimFwDbgBleWifiTxTrigAgg* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_trig_agg".}: uint32
var nimFwDbgBleWifiTxCfmBcn* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_cfm_bcn".}: uint32
var nimFwDbgBleWifiTxCfmPti* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_cfm_pti".}: uint32
var nimFwDbgStaTxRfRestore* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_restore".}: uint32
var nimFwDbgStaTxRfFullRestore* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_full_restore".}: uint32
var nimFwDbgStaTxRfLatch* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_latch".}: uint32
var nimFwDbgStaTxChannelSource* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_channel_source".}: uint32
var nimFwDbgStaTxChannelReq0* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_channel_req0".}: uint32
var nimFwDbgStaTxChannelReq1* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_channel_req1".}: uint32
var nimFwDbgStaTxChannelVif* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_channel_vif".}: uint32
var nimFwDbgSmChanCtxReq0* {.wifiCtrl, exportc: "nimfw_dbg_sm_chan_ctx_req0".}: uint32
var nimFwDbgSmChanCtxReq1* {.wifiCtrl, exportc: "nimfw_dbg_sm_chan_ctx_req1".}: uint32
var nimFwDbgSmChanCtxPtrs* {.wifiCtrl, exportc: "nimfw_dbg_sm_chan_ctx_ptrs".}: uint32
var nimFwDbgSmChanCtxResult* {.wifiCtrl, exportc: "nimfw_dbg_sm_chan_ctx_result".}: uint32
var nimFwKeepaliveInFlight* {.wifiCtrl, exportc: "nimfw_keepalive_inflight".}: uint32
var nimFwKeepaliveTargetCfm* {.wifiCtrl, exportc: "nimfw_keepalive_target_cfm".}: uint32
var nimFwKeepaliveStartedAt* {.wifiCtrl, exportc: "nimfw_keepalive_started_at".}: uint32
var nimFwDbgKeepaliveRc* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_rc".}: uint32
var nimFwDbgKeepalivePostBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_post_before".}: uint32
var nimFwDbgKeepalivePostAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_post_after".}: uint32
var nimFwDbgKeepaliveTxintBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_txint_before".}: uint32
var nimFwDbgKeepaliveTxintAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_txint_after".}: uint32
var nimFwDbgKeepaliveFakeBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_fake_before".}: uint32
var nimFwDbgKeepaliveFakeAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_fake_after".}: uint32
var nimFwDbgKeepalivePayBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_pay_before".}: uint32
var nimFwDbgKeepalivePayAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_pay_after".}: uint32
var nimFwDbgKeepaliveCbBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_cb_before".}: uint32
var nimFwDbgKeepaliveCbAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_cb_after".}: uint32
var nimFwKeepaliveQosNullEnabled* {.wifiCtrl, exportc: "nimfw_keepalive_qosnull_enabled".}: uint32
var nimFwDbgTxIntEnter* {.wifiCtrl, exportc: "nimfw_dbg_txint_enter".}: uint32
var nimFwDbgTxIntLastCb* {.wifiCtrl, exportc: "nimfw_dbg_txint_last_cb".}: uint32
var nimFwDbgTxIntLastFc* {.wifiCtrl, exportc: "nimfw_dbg_txint_last_fc".}: uint32
var nimFwDbgTxIntReady* {.wifiCtrl, exportc: "nimfw_dbg_txint_ready".}: uint32
var nimFwDbgTxIntPsOk* {.wifiCtrl, exportc: "nimfw_dbg_txint_psok".}: uint32
var nimFwDbgTxIntPush* {.wifiCtrl, exportc: "nimfw_dbg_txint_push".}: uint32
var nimFwDbgTxIntRelease* {.wifiCtrl, exportc: "nimfw_dbg_txint_release".}: uint32
var nimFwDbgTxIntPostpone* {.wifiCtrl, exportc: "nimfw_dbg_txint_postpone".}: uint32
var nimFwDbgTxIntLastMeta* {.wifiCtrl, exportc: "nimfw_dbg_txint_meta".}: uint32
var nimFwDbgTxIntLastChan* {.wifiCtrl, exportc: "nimfw_dbg_txint_chan".}: uint32
var nimFwDbgTxIntLastQueue* {.wifiCtrl, exportc: "nimfw_dbg_txint_queue".}: uint32
var nimFwDbgTxIntLastHw* {.wifiCtrl, exportc: "nimfw_dbg_txint_hw".}: uint32
var nimFwDbgStaTbttEnter*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_enter".}: uint32
var nimFwDbgStaTbttAssoc*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_assoc".}: uint32
var nimFwDbgStaTbttOnChan*    {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_onchan".}: uint32
var nimFwDbgStaTbttPC100*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_pc100".}: uint32
var nimFwDbgStaTbttPCMax*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_pcmax".}: uint32
var nimFwDbgSetVifState*      {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state".}: uint32   # entries
var nimFwDbgSetVifStateNew*   {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state_new".}: uint32  # last newState
var nimFwDbgSetVifStateAct*   {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state_act".}: uint32  # activating=true count
var nimFwDbgAssocDone*        {.wifiCtrl, exportc: "nimfw_dbg_assoc_done".}: uint32
var nimFwDbgAuthOpenSuccess*  {.wifiCtrl, exportc: "nimfw_dbg_auth_open_success".}: uint32
var nimFwDbgAssocReqSend*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_req_send".}: uint32
var nimFwDbgAssocReqMeta*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_req_meta".}: uint32
var nimFwDbgAssocCfmPush*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_push".}: uint32
var nimFwDbgAssocCfmFrame*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_frame".}: uint32
var nimFwDbgAssocCfmEvt*      {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_evt".}: uint32
var nimFwDbgAssocCfmStatus*   {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_status".}: uint32
var nimFwDbgAssocCfmHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_hw_status".}: uint32
var nimFwDbgAssocCfmDesc*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_desc".}: uint32
var nimFwDbgAssocCfmMeta*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_meta".}: uint32
var nimFwDbgAssocCfmFc*       {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_fc".}: uint32
var nimFwDbgAssocRspStatus*   {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_status".}: uint32  # last assoc rsp statusCode
var nimFwDbgAssocRspCount*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_count".}: uint32
var nimFwDbgAssocRspLen*      {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_len".}: uint32
var nimFwDbgAssocRspBody0*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_b0".}: uint32  # first 4 bytes of body
var nimFwDbgAssocRspBody4*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_b4".}: uint32  # next 4 bytes
var nimFwDbgDeauthHandler*    {.wifiCtrl, exportc: "nimfw_dbg_deauth".}: uint32
var nimFwDbgConnLossInd*      {.wifiCtrl, exportc: "nimfw_dbg_connloss".}: uint32
var nimFwDbgWpaRsnIeSet*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_set".}: uint32
var nimFwDbgWpaRsnIeLen*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_len".}: uint32
var nimFwDbgWpaRsnIePtr*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_ptr".}: uint32
var nimFwDbgVifSecType*       {.wifiCtrl, exportc: "nimfw_dbg_vif_sectype".}: uint32  # vif+497 at vif_state_cfm
var nimFwDbgConnectIndPrePath* {.wifiCtrl, exportc: "nimfw_dbg_conn_ind_prepath".}: uint32  # path-1 (open) fired
var nimFwDbgVifIeLenAtAssoc*  {.wifiCtrl, exportc: "nimfw_dbg_vif_ielen_assoc".}: uint32  # vif+496 at AssocReq build
var nimFwDbgPtkInitDone*      {.wifiCtrl, exportc: "nimfw_dbg_ptk_init_done".}: uint32
var nimFwDbgKeyDataDecryptCalls* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_calls".}: uint32
var nimFwDbgKeyDataDecryptLen* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_len".}: uint32
var nimFwDbgKeyDataDecryptOutLen* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_out_len".}: uint32
var nimFwDbgKeyDataDecryptOk* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_ok".}: uint32
var nimFwDbgKeyDataDecryptFail* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_fail".}: uint32
# Per-VIF WPA-handshake-pending tracking. Set when sm_assoc_done runs on a
# WPA-protected VIF (sectype>=2); cleared on PTK-init-done or disconnect.
# mm_sta_tbtt uses this to suppress the null-frame keep-alive loop while
# waiting for WPA, and to time out the wait into a connection_loss_ind.
var nimFwWpaPendingMask* {.wifiCtrl, exportc: "nimfw_wpa_pending_mask".}: uint32
var nimFwDbgStaTbttSkip* {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_skip".}: uint32
var nimFwDbgStaTbttGiveup* {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_giveup".}: uint32
var nimFwDbgEapolIn*       {.wifiCtrl, exportc: "nimfw_dbg_eapol_in".}: uint32
var nimFwDbgEapolDropped*  {.wifiCtrl, exportc: "nimfw_dbg_eapol_dropped".}: uint32
var nimFwDbgEapolForwarded* {.wifiCtrl, exportc: "nimfw_dbg_eapol_fwd".}: uint32
var nimFwDbgVifWpaState*   {.wifiCtrl, exportc: "nimfw_dbg_vif_wpastate".}: uint32
var nimFwDbgEapolCbInv*    {.wifiCtrl, exportc: "nimfw_dbg_eapol_cb_inv".}: uint32
var nimFwDbgEapolCbNull*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cb_null".}: uint32
var nimFwDbgSmStateAtEapol* {.wifiCtrl, exportc: "nimfw_dbg_sm_state_eapol".}: uint32
# Supplicant-side counters (incremented from C files in wpa_supplicant/ and wifi driver)
var nimFwDbgSuppRxEapol*   {.wifiCtrl, exportc: "nimfw_dbg_supp_rx_eapol".}: uint32
var nimFwDbgSuppTxEapol*   {.wifiCtrl, exportc: "nimfw_dbg_supp_tx_eapol".}: uint32
var nimFwDbgEthTxEapol*    {.wifiCtrl, exportc: "nimfw_dbg_eth_tx_eapol".}: uint32
var nimFwDbgBlOutputEapol* {.wifiCtrl, exportc: "nimfw_dbg_bl_output_eapol".}: uint32
var nimFwDbgEapolTxCb*     {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_cb".}: uint32
var nimFwDbgWpaDeauth*     {.wifiCtrl, exportc: "nimfw_dbg_wpa_deauth".}: uint32
var nimFwDbgEthTxRet*      {.wifiCtrl, exportc: "nimfw_dbg_eth_tx_ret".}: uint32  # last return code
var nimFwDbgBlOutputDrop*  {.wifiCtrl, exportc: "nimfw_dbg_bl_output_drop".}: uint32  # bl_output dropped (sta_id<0)
var nimFwDbgPbufAllocFail* {.wifiCtrl, exportc: "nimfw_dbg_pbuf_alloc_fail".}: uint32
var nimFwDbgPbufTakeFail*  {.wifiCtrl, exportc: "nimfw_dbg_pbuf_take_fail".}: uint32
var nimFwDbgSuppTxLen*     {.wifiCtrl, exportc: "nimfw_dbg_supp_tx_len".}: uint32  # last EAPOL TX len
var nimFwDbgTxFlushEnter*  {.wifiCtrl, exportc: "nimfw_dbg_tx_flush_enter".}: uint32
var nimFwDbgTxPushCalls*   {.wifiCtrl, exportc: "nimfw_dbg_tx_push_calls".}: uint32
var nimFwDbgTxNoDesc*      {.wifiCtrl, exportc: "nimfw_dbg_tx_nodesc".}: uint32
var nimFwDbgTxNoBuf*       {.wifiCtrl, exportc: "nimfw_dbg_tx_nobuf".}: uint32
var nimFwDbgBlTxCfm*       {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm".}: uint32  # bl_tx_cfm calls
var nimFwDbgBlTxCfmCb*     {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm_cb".}: uint32  # bl_tx_cfm cb != nil
var nimFwDbgBlTxCfmEapol*  {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm_eapol".}: uint32  # cfm for EAPOL ethertype
var nimFwDbgTxSecHdrCalls* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_calls".}: uint32
var nimFwDbgTxSecHdrNoKeyMat* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_no_keymat".}: uint32
var nimFwDbgTxSecHdrNoKeySlot* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_no_keyslot".}: uint32
var nimFwDbgTxSecHdrCipher* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_cipher".}: uint32
var nimFwDbgTxSecHdrLen* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_len".}: uint32
var nimFwDbgTxSecHdrAppend* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_append".}: uint32
var nimFwDbgTxSecHdrMissMeta* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_meta".}: uint32
var nimFwDbgTxSecHdrMissLen* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_len".}: uint32
var nimFwDbgTxSecHdrMissKeyMat* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_keymat".}: uint32
var nimFwDbgDhcpTxDescBytes* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_desc_bytes".}: uint32
var nimFwDbgDhcpTxHdr0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr0".}: uint32
var nimFwDbgDhcpTxHdr1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr1".}: uint32
var nimFwDbgDhcpTxHdr2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr2".}: uint32
var nimFwDbgDhcpTxSec* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec".}: uint32
var nimFwDbgDhcpTxSecHdr0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_hdr0".}: uint32
var nimFwDbgDhcpTxSecHdr1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_hdr1".}: uint32
var nimFwDbgDhcpTxSecKey* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_key".}: uint32
var nimFwDbgDhcpTxSecCtl* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_ctl".}: uint32
var nimFwDbgDhcpTxPolicy* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_policy".}: uint32
var nimFwDbgDhcpTxBufDesc* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_buf_desc".}: uint32
var nimFwDbgDhcpTxHwDesc* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hw_desc".}: uint32
var nimFwDbgDhcpTxRate0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate0".}: uint32
var nimFwDbgDhcpTxRate1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate1".}: uint32
var nimFwDbgDhcpTxRate2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate2".}: uint32
var nimFwDbgDhcpTxRate3* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate3".}: uint32
var nimFwDbgDhcpTxRateRaw* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate_raw".}: array[13, uint32]
var nimFwDbgDhcpTxLink0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_link0".}: uint32
var nimFwDbgDhcpTxLink1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_link1".}: uint32
var nimFwDbgDhcpTxThd0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd0".}: uint32
var nimFwDbgDhcpTxThd1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd1".}: uint32
var nimFwDbgDhcpTxThd2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd2".}: uint32
var nimFwDbgDhcpTxLayout* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_layout".}: array[8, uint32]
var nimFwDbgDhcpTxFinalBreakHits* {.wifiCtrl,
  exportc: "nimfw_dbg_dhcp_tx_final_break_hits".}: uint32
var nimFwDbgDhcpTxFinalDesc0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_desc0".}: uint32
var nimFwDbgDhcpTxFinalDesc1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_desc1".}: uint32
var nimFwDbgDhcpTxFinalBuf0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_buf0".}: uint32
var nimFwDbgDhcpTxFinalLen0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_len0".}: uint32
var nimFwDbgDhcpTxFinalHwStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_start".}: uint32
var nimFwDbgDhcpTxFinalHwEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_end".}: uint32
var nimFwDbgDhcpTxFinalHwLen* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_len".}: uint32
var nimFwDbgDhcpTxFinalHwFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_flags".}: uint32
var nimFwDbgDhcpTxFinalHthdStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_start".}: uint32
var nimFwDbgDhcpTxFinalHthdEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_end".}: uint32
var nimFwDbgDhcpTxFinalHthdNext* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_next".}: uint32
var nimFwDbgDhcpTxFinalHthdFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_flags".}: uint32
var nimFwDbgDhcpTxFinalPthdStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_start".}: uint32
var nimFwDbgDhcpTxFinalPthdEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_end".}: uint32
var nimFwDbgDhcpTxFinalPthdNext* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_next".}: uint32
var nimFwDbgDhcpTxFinalPthdFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_flags".}: uint32
var nimFwDbgEapolTxDescBytes* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_desc_bytes".}: uint32
var nimFwDbgEapolTxHdr0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr0".}: uint32
var nimFwDbgEapolTxHdr1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr1".}: uint32
var nimFwDbgEapolTxHdr2* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr2".}: uint32
var nimFwDbgEapolTxHdr3* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr3".}: uint32
var nimFwDbgEapolTxAddrHi* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_addr_hi".}: uint32
var nimFwDbgEapolTxPolicy* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_policy".}: uint32
var nimFwDbgEapolTxBufDesc* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_buf_desc".}: uint32
var nimFwDbgEapolTxHwDesc* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hw_desc".}: uint32
var nimFwDbgEapolTxRate0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate0".}: uint32
var nimFwDbgEapolTxRate1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate1".}: uint32
var nimFwDbgEapolTxRate2* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate2".}: uint32
var nimFwDbgEapolTxRate3* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate3".}: uint32
var nimFwDbgEapolTxLink0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_link0".}: uint32
var nimFwDbgEapolTxLink1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_link1".}: uint32
var nimFwDbgDhcpMacRawLen* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_mac_raw_len".}: uint32
var nimFwDbgDhcpMacRaw* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_mac_raw".}: array[96, uint8]
var nimFwDbgWpaState*      {.wifiCtrl, exportc: "nimfw_dbg_wpa_state".}: uint32  # latest WPA_SM_STATE
var nimFwDbgWpaTxState*    {.wifiCtrl, exportc: "nimfw_dbg_wpa_tx_state".}: uint32  # WPA state at TX time
var nimFwDbgWpaRxState*    {.wifiCtrl, exportc: "nimfw_dbg_wpa_rx_state".}: uint32  # WPA state at RX time
var nimFwDbgWpaPtkInstalled* {.wifiCtrl, exportc: "nimfw_dbg_wpa_ptk_installed".}: uint32
# Crypto-derivation snapshot for offline verification.
# Filled by C side at wpa_derive_ptk entry/exit; dumped via UART at end of test.
var nimFwDbgCryptoCaptured*  {.wifiCtrl, exportc: "nimfw_dbg_crypto_captured".}: uint32
var nimFwDbgCryptoPmk*       {.wifiCtrl, exportc: "nimfw_dbg_crypto_pmk".}: array[32, uint8]
var nimFwDbgCryptoOwnAddr*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_own".}: array[6, uint8]
var nimFwDbgCryptoBssid*     {.wifiCtrl, exportc: "nimfw_dbg_crypto_bssid".}: array[6, uint8]
var nimFwDbgCryptoSNonce*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_snonce".}: array[32, uint8]
var nimFwDbgCryptoANonce*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_anonce".}: array[32, uint8]
var nimFwDbgCryptoKck*       {.wifiCtrl, exportc: "nimfw_dbg_crypto_kck".}: array[16, uint8]
var nimFwDbgCryptoPmkLen*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_pmk_len".}: uint32
var nimFwDbgCryptoPtkLen*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_ptk_len".}: uint32
var nimFwDbgCryptoUseSha256* {.wifiCtrl, exportc: "nimfw_dbg_crypto_sha256".}: uint32
var nimFwDbgCryptoKeyMgmt*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_keymgmt".}: uint32
var nimFwDbgCryptoPairwise*  {.wifiCtrl, exportc: "nimfw_dbg_crypto_pairwise".}: uint32
var nimFwDbgCryptoPrfData*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_prf_data".}: array[76, uint8]
# Self-test of SHA1/HMAC primitive: HMAC-SHA1(key="Jefe", data="what do ya want for nothing?")
# Expected output: effcdf6ae5eb2fa2d27416d5f184df9c259a7c79 (RFC 2202 test case 2)
var nimFwDbgSelftestHmac*    {.wifiCtrl, exportc: "nimfw_dbg_selftest_hmac".}: array[20, uint8]
var nimFwDbgSelftestRan*     {.wifiCtrl, exportc: "nimfw_dbg_selftest_ran".}: uint32
# Comparison: the source MAC actually placed in 802.11 frames (vif+80) vs sm->own_addr.
var nimFwDbgVifMac*          {.wifiCtrl, exportc: "nimfw_dbg_vif_mac".}: array[6, uint8]
var nimFwDbgMacHwLo*         {.wifiCtrl, exportc: "nimfw_dbg_mac_hw_lo".}: uint32
var nimFwDbgMacHwHi*         {.wifiCtrl, exportc: "nimfw_dbg_mac_hw_hi".}: uint32
# M2 EAPOL frame snapshot — Ethernet + EAPOL key bytes as sent by supplicant.
var nimFwDbgM2Len*           {.wifiCtrl, exportc: "nimfw_dbg_m2_len".}: uint32
var nimFwDbgM2Buf*           {.wifiCtrl, exportc: "nimfw_dbg_m2_buf".}: array[160, uint8]
# KCK as seen at MIC computation site (wpa_eapol_key_mic).
var nimFwDbgMicKck*          {.wifiCtrl, exportc: "nimfw_dbg_mic_kck".}: array[16, uint8]
var nimFwDbgMicComputed*     {.wifiCtrl, exportc: "nimfw_dbg_mic_computed".}: array[16, uint8]
var nimFwDbgMicFrameLen*     {.wifiCtrl, exportc: "nimfw_dbg_mic_frame_len".}: uint32
var nimFwDbgMicVer*          {.wifiCtrl, exportc: "nimfw_dbg_mic_ver".}: uint32
# SAE path tracking.
var nimFwDbgSaeBuildMsg*     {.wifiCtrl, exportc: "nimfw_dbg_sae_build".}: uint32
var nimFwDbgSaeParseMsg*     {.wifiCtrl, exportc: "nimfw_dbg_sae_parse".}: uint32
var nimFwDbgSaeAuthAlgo*     {.wifiCtrl, exportc: "nimfw_dbg_sae_auth_algo".}: uint32  # auth_algo read in sm_auth_send
var nimFwDbgAuthMgtSeen*     {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_seen".}: uint32
var nimFwDbgAuthMgtAccepted* {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_accept".}: uint32
var nimFwDbgAuthMgtRejected* {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_reject".}: uint32
var nimFwDbgAuthMgtMsgSent*  {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_msg".}: uint32
var nimFwDbgAuthMgtLast0*    {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_last0".}: uint32
var nimFwDbgAuthMgtLast1*    {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_last1".}: uint32
var nimFwDbgMgtSeen*         {.wifiCtrl, exportc: "nimfw_dbg_mgt_seen".}: uint32
var nimFwDbgMgtAccepted*     {.wifiCtrl, exportc: "nimfw_dbg_mgt_accept".}: uint32
var nimFwDbgMgtRejected*     {.wifiCtrl, exportc: "nimfw_dbg_mgt_reject".}: uint32
var nimFwDbgMgtMsgSent*      {.wifiCtrl, exportc: "nimfw_dbg_mgt_msg".}: uint32
var nimFwDbgMgtLastFc*       {.wifiCtrl, exportc: "nimfw_dbg_mgt_last_fc".}: uint32
var nimFwDbgMgtLast0*        {.wifiCtrl, exportc: "nimfw_dbg_mgt_last0".}: uint32
var nimFwDbgMgtLast1*        {.wifiCtrl, exportc: "nimfw_dbg_mgt_last1".}: uint32
var nimFwDbgMgtDropReason*   {.wifiCtrl, exportc: "nimfw_dbg_mgt_drop_reason".}: uint32
var nimFwDbgAuthSmDispatch*  {.wifiCtrl, exportc: "nimfw_dbg_auth_sm_dispatch".}: uint32
var nimFwDbgAuthSmState*     {.wifiCtrl, exportc: "nimfw_dbg_auth_sm_state".}: uint32
var nimFwDbgAuthHandler*     {.wifiCtrl, exportc: "nimfw_dbg_auth_handler".}: uint32
var nimFwDbgAuthHandlerLast* {.wifiCtrl, exportc: "nimfw_dbg_auth_handler_last".}: uint32
var nimFwDbgAuthTxLen*       {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_len".}: uint32
var nimFwDbgAuthTxMeta*      {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_meta".}: uint32
var nimFwDbgAuthTxDesc*      {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_desc".}: uint32
var nimFwDbgAuthTxRaw*       {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_raw".}: array[96, uint8]
var nimFwDbgAuthRfPrePush*   {.wifiCtrl, exportc: "nimfw_dbg_auth_rf_pre_push".}: array[8, uint32]
var nimFwDbgAuthHwPrePush*   {.wifiCtrl, exportc: "nimfw_dbg_auth_hw_pre_push".}: array[32, uint32]
var nimFwDbgAuthCfmPush*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_push".}: uint32
var nimFwDbgAuthCfmFrame*    {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_frame".}: uint32
var nimFwDbgAuthCfmEvt*      {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_evt".}: uint32
var nimFwDbgAuthCfmStatus*   {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_status".}: uint32
var nimFwDbgAuthCfmHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_hw_status".}: uint32
var nimFwDbgAuthCfmDesc*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_desc".}: uint32
var nimFwDbgAuthCfmMeta*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_meta".}: uint32
var nimFwDbgAuthCfmFc*       {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_fc".}: uint32
var nimFwDbgScanFrameSeen*   {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_seen".}: uint32
var nimFwDbgScanFrameAccepted* {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_accept".}: uint32
var nimFwDbgScanFrameLast*   {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_last".}: uint32
var nimFwDbgScanSsidLast*    {.wifiCtrl, exportc: "nimfw_dbg_scan_ssid_last".}: uint32
var nimFwDbgBssIn*           {.wifiCtrl, exportc: "nimfw_dbg_bss_in".}: uint32
var nimFwDbgBssSsidResult*   {.wifiCtrl, exportc: "nimfw_dbg_bss_ssid_result".}: uint32
var nimFwDbgBssDirected*     {.wifiCtrl, exportc: "nimfw_dbg_bss_directed".}: uint32
var nimFwDbgBssOut*          {.wifiCtrl, exportc: "nimfw_dbg_bss_out".}: uint32
var nimFwDbgBssChanFixMeta*  {.wifiCtrl, exportc: "nimfw_dbg_bss_chan_fix_meta".}: uint32
var nimFwDbgBssChanFixPtr*   {.wifiCtrl, exportc: "nimfw_dbg_bss_chan_fix_ptr".}: uint32
var nimFwDbgBssChanFixRaw*   {.wifiCtrl, exportc: "nimfw_dbg_bss_chan_fix_raw".}: uint32
var nimFwDbgBssRxFreq*       {.wifiCtrl, exportc: "nimfw_dbg_bss_rx_freq".}: uint32
var nimFwDbgBssDsFreq*       {.wifiCtrl, exportc: "nimfw_dbg_bss_ds_freq".}: uint32
var nimFwDbgBssSelectedFreq* {.wifiCtrl, exportc: "nimfw_dbg_bss_selected_freq".}: uint32
var nimFwDbgSsidSearch*      {.wifiCtrl, exportc: "nimfw_dbg_ssid_search".}: uint32
var nimFwDbgSsidEntries*     {.wifiCtrl, exportc: "nimfw_dbg_ssid_entries".}: uint32
var nimFwDbgSsidHits*        {.wifiCtrl, exportc: "nimfw_dbg_ssid_hits".}: uint32
var nimFwDbgScanKeyMgmt*     {.wifiCtrl, exportc: "nimfw_dbg_scan_key_mgmt".}: uint32  # lf (parsed key_mgmt LE 16-bit)
var nimFwDbgScanAT*          {.wifiCtrl, exportc: "nimfw_dbg_scan_at".}: uint32  # computed aT
var nimFwDbgScanSmF*         {.wifiCtrl, exportc: "nimfw_dbg_scan_smf".}: uint32  # smF flags
var nimFwDbgScanCaps*        {.wifiCtrl, exportc: "nimfw_dbg_scan_caps".}: uint32  # lS[16] (capabilities)
# M4 path tracking — debug why PTK never gets installed.
var nimFwDbgM4TxState*       {.wifiCtrl, exportc: "nimfw_dbg_m4_tx_state".}: uint32  # WPA state at M4 TX
var nimFwDbgM4CbPtr*         {.wifiCtrl, exportc: "nimfw_dbg_m4_cb_ptr".}: uint32    # custom_cfm.cb at M4 TX
var nimFwDbgCfmCbPtrLast*    {.wifiCtrl, exportc: "nimfw_dbg_cfm_cb_ptr_last".}: uint32  # what bl_tx_cfm read
var nimFwDbgSendCfmLastEthertype* {.wifiCtrl, exportc: "nimfw_dbg_cfm_last_ethertype".}: uint32
var nimFwDbgSend4of4Tx*      {.wifiCtrl, exportc: "nimfw_dbg_send_4of4_tx".}: uint32  # M4 send invocations
var nimFwDbgSend4of4Cb*      {.wifiCtrl, exportc: "nimfw_dbg_send_4of4_cb".}: uint32  # wpa_supplicant_send_4_of_4_txcallback invocations
var nimFwDbgInstallPtk*      {.wifiCtrl, exportc: "nimfw_dbg_install_ptk".}: uint32  # wpa_supplicant_install_ptk invocations
# Per-EAPOL bl_tx_cfm details — status (THD[16]) for last EAPOL frame.
var nimFwDbgEapolCfmStatus*  {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_status".}: uint32
var nimFwDbgEapolCfmCount*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_count".}: uint32
var nimFwDbgEapolCfmAckOk*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ack_ok".}: uint32
var nimFwDbgEapolCfmAckFail* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ack_fail".}: uint32
var nimFwDbgEapolCfmRingIdx* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ring_idx".}: uint32
var nimFwDbgEapolCfmStatusLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_status_log".}: array[4, uint32]
var nimFwDbgEapolCfmMetaLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_meta_log".}: array[4, uint32]
var nimFwDbgEapolCfmKeyLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_key_log".}: array[4, uint32]
var nimFwDbgEapolCfmReplayLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_replay_log".}: array[4, uint32]
var nimFwDbgEapolCfmCbLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_cb_log".}: array[4, uint32]
# Disconnect-path counters.
var nimFwDbgDisconnectReq*   {.wifiCtrl, exportc: "nimfw_dbg_disconnect_req".}: uint32
var nimFwDbgDisconnectReqState* {.wifiCtrl, exportc: "nimfw_dbg_disconnect_req_state".}: uint32
var nimFwDbgDisconnectProcess* {.wifiCtrl, exportc: "nimfw_dbg_disconnect_process".}: uint32
var nimFwDbgDisconnectInd*   {.wifiCtrl, exportc: "nimfw_dbg_disconnect_ind".}: uint32
var nimFwDbgSmStateFinal*    {.wifiCtrl, exportc: "nimfw_dbg_sm_state_final".}: uint32
