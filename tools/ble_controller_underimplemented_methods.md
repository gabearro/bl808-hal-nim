# BLE Controller Under-Implemented Methods

- Reference: `build/vendor_bl808_fw/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Nim object/archive: `build/hw-validation/nimcache/m0_ble_nim_controller_hal_test/kernel/@pbl808@sblecontroller.nim.c.o`
- Source: `src/bl808/blecontroller.nim`
- Reference functions: **452**
- Nim functions: **1324**
- Common functions: **452**
- Missing reference functions in Nim: **0**
- Method count where Nim is smaller than blob: **338**
- Placeholder stubs in source: **73**
- Placeholder stubs matching reference symbols: **72**
- Likely active placeholder stubs in this build: **46**
- Severity buckets: >=200: 0, 100-199: 1, 50-99: 10, 25-49: 51, 10-24: 141, 1-9: 135
- Note: instruction deltas are local to each symbol body; wrappers that delegate to helper functions can still appear short.

## Largest Shorter Methods

| # | Symbol | src line | ref | nim | missing | nim/ref % | source stub | active stub |
|---:|---|---:|---:|---:|---:|---:|---|---|
| 1 | `GF_Jacobian_Point_Addition256` | 18112 | 132 | 7 | 125 | 5.3 | no | no |
| 2 | `rwip_reset` | 493 | 84 | 11 | 73 | 13.1 | no | no |
| 3 | `hci_le_rem_con_param_req_reply_cmd_handler` | 17470 | 69 | 2 | 67 | 2.9 | no | no |
| 4 | `llc_con_move_cbk` | 18305 | 64 | 2 | 62 | 3.12 | yes | yes |
| 5 | `bigHexInversion256` | 15703 | 75 | 13 | 62 | 17.33 | no | no |
| 6 | `hci_le_en_enc_cmd_handler` | 17439 | 73 | 12 | 61 | 16.44 | no | no |
| 7 | `aes_f6` | 17022 | 72 | 13 | 59 | 18.06 | no | no |
| 8 | `ll_length_req_handler` |  | 66 | 9 | 57 | 13.64 | no | no |
| 9 | `aes_f5` | 17012 | 69 | 13 | 56 | 18.84 | no | no |
| 10 | `lld_per_adv_list_add` | 18694 | 56 | 2 | 54 | 3.57 | yes | yes |
| 11 | `rwip_init` | 16247 | 94 | 42 | 52 | 44.68 | no | no |
| 12 | `btble_controller_init` | 16007 | 59 | 10 | 49 | 16.95 | no | no |
| 13 | `lld_con_data_flow_set` | 17822 | 56 | 8 | 48 | 14.29 | no | no |
| 14 | `ll_connection_update_ind_handler` |  | 55 | 9 | 46 | 16.36 | no | no |
| 15 | `ll_connection_param_req_handler` |  | 55 | 9 | 46 | 16.36 | no | no |
| 16 | `ble_util_buf_init` | 16050 | 49 | 7 | 42 | 14.29 | no | no |
| 17 | `lld_calc_aux_rx` | 18640 | 43 | 2 | 41 | 4.65 | yes | yes |
| 18 | `hci_disconnect_cmd_handler` | 17427 | 57 | 16 | 41 | 28.07 | no | no |
| 19 | `llc_clk_acc_modify` | 18300 | 48 | 8 | 40 | 16.67 | no | no |
| 20 | `phy_upd_proc_start` | 16678 | 40 | 1 | 39 | 2.5 | no | no |
| 21 | `hci_rd_rem_ver_info_cmd_handler` | 17607 | 51 | 12 | 39 | 23.53 | no | no |
| 22 | `aes_h8` | 17061 | 50 | 11 | 39 | 22.0 | no | no |
| 23 | `hci_vs_set_max_rx_size_and_time_cmd_handler` | 17613 | 46 | 10 | 36 | 21.74 | no | no |
| 24 | `aes_g2` | 17034 | 48 | 12 | 36 | 25.0 | no | no |
| 25 | `hci_le_set_data_len_cmd_handler` | 17585 | 46 | 12 | 34 | 26.09 | no | no |
| 26 | `co_time_timer_periodic_set` | 17142 | 35 | 1 | 34 | 2.86 | no | no |
| 27 | `aes_k2` | 17088 | 45 | 11 | 34 | 24.44 | no | no |
| 28 | `aes_cmac` | 16945 | 45 | 11 | 34 | 24.44 | no | no |
| 29 | `aes_c1` | 16974 | 46 | 12 | 34 | 26.09 | no | no |
| 30 | `llm_ch_map_update_ind_handler` | 14247 | 41 | 8 | 33 | 19.51 | no | no |
| 31 | `nvds_init` | 17668 | 34 | 2 | 32 | 5.88 | no | no |
| 32 | `co_time_timer_long_set` | 17139 | 33 | 1 | 32 | 3.03 | no | no |
| 33 | `bt_onchiphci_hanlde_rx_acl` | 16036 | 34 | 2 | 32 | 5.88 | no | no |
| 34 | `aes_f4` | 17003 | 43 | 11 | 32 | 25.58 | no | no |
| 35 | `sch_slice_bg_remove` | 18746 | 33 | 2 | 31 | 6.06 | yes | yes |
| 36 | `sch_slice_fg_remove` | 18749 | 32 | 2 | 30 | 6.25 | yes | yes |
| 37 | `sch_slice_bg_add` | 18745 | 32 | 2 | 30 | 6.25 | yes | yes |
| 38 | `lld_rx_timing_compute` | 4407 | 48 | 18 | 30 | 37.5 | yes | no |
| 39 | `co_time_init` | 17127 | 31 | 1 | 30 | 3.23 | no | no |
| 40 | `nvds_put` | 17681 | 31 | 2 | 29 | 6.45 | no | no |
| 41 | `hci_tl_send` | 12730 | 31 | 2 | 29 | 6.45 | no | no |
| 42 | `hci_le_set_phy_cmd_handler` | 17502 | 43 | 14 | 29 | 32.56 | no | no |
| 43 | `co_time_timer_set` | 17136 | 30 | 1 | 29 | 3.33 | no | no |
| 44 | `sch_arb_event_start_isr` | 18721 | 30 | 2 | 28 | 6.67 | yes | yes |
| 45 | `lld_adv_end_ind_handler` | 18593 | 33 | 5 | 28 | 15.15 | no | no |
| 46 | `ll_feature_rsp_handler` |  | 37 | 9 | 28 | 24.32 | no | no |
| 47 | `aes_h7` | 17052 | 38 | 10 | 28 | 26.32 | no | no |
| 48 | `aes_h6` | 17043 | 38 | 10 | 28 | 26.32 | no | no |
| 49 | `SubtractBigHexUint32_256` | 18134 | 35 | 7 | 28 | 20.0 | no | no |
| 50 | `sch_slice_fg_add` | 18748 | 29 | 2 | 27 | 6.9 | yes | yes |
| 51 | `llc_init_term_proc` | 18315 | 35 | 8 | 27 | 22.86 | no | no |
| 52 | `flash_erase` | 17184 | 29 | 2 | 27 | 6.9 | no | no |
| 53 | `btble_ke_msg_send_basic` | 15902 | 34 | 7 | 27 | 20.59 | no | no |
| 54 | `hci_wr_auth_payl_to_cmd_handler` | 17634 | 39 | 13 | 26 | 33.33 | no | no |
| 55 | `aes_ccm` | 16992 | 42 | 16 | 26 | 38.1 | no | no |
| 56 | `sch_slice_compute` | 18747 | 27 | 2 | 25 | 7.41 | yes | yes |
| 57 | `lld_per_adv_list_rem` | 18695 | 27 | 2 | 25 | 7.41 | yes | yes |
| 58 | `lld_con_enc_key_load` | 18644 | 27 | 2 | 25 | 7.41 | yes | yes |
| 59 | `lld_aa_gen` | 3457 | 61 | 36 | 25 | 59.02 | no | no |
| 60 | `ll_min_used_channels_ind_handler` |  | 34 | 9 | 25 | 26.47 | no | no |
| 61 | `SubtractFromSelfBigHexSign256` | 18141 | 32 | 7 | 25 | 21.88 | no | no |
| 62 | `SubtractBigHexMod256` | 18131 | 32 | 7 | 25 | 21.88 | no | no |
| 63 | `lld_con_tx_enc` | 18653 | 26 | 2 | 24 | 7.69 | yes | yes |
| 64 | `lld_con_rx_enc` | 18652 | 26 | 2 | 24 | 7.69 | yes | yes |
| 65 | `llc_stopped_ind_handler` | 18511 | 34 | 10 | 24 | 29.41 | yes | no |
| 66 | `nvds_get` | 17673 | 25 | 2 | 23 | 8.0 | no | no |
| 67 | `llc_llcp_tx_check` | 16774 | 24 | 1 | 23 | 4.17 | no | no |
| 68 | `ble_util_buf_rx_free` | 4021 | 35 | 12 | 23 | 34.29 | no | no |
| 69 | `aes_k1` | 17079 | 35 | 12 | 23 | 34.29 | no | no |
| 70 | `sch_arb_remove` | 11917 | 24 | 2 | 22 | 8.33 | no | no |
| 71 | `rwip_wlcoex_set` | 16296 | 29 | 7 | 22 | 24.14 | no | no |
| 72 | `lld_con_param_update` | 18650 | 24 | 2 | 22 | 8.33 | yes | yes |
| 73 | `ll_terminate_ind_handler` | 18226 | 31 | 9 | 22 | 29.03 | yes | no |
| 74 | `hci_rd_tx_pwr_lvl_cmd_handler` | 17417 | 34 | 12 | 22 | 35.29 | no | no |
| 75 | `hci_le_rd_adv_ch_tx_pw_cmd_handler` | 17516 | 34 | 12 | 22 | 35.29 | no | no |
| 76 | `dbg_platform_reset_complete` | 16033 | 23 | 1 | 22 | 4.35 | no | no |
| 77 | `sch_slice_per_remove` | 11951 | 23 | 2 | 21 | 8.7 | no | no |
| 78 | `sch_slice_per_add` | 11927 | 23 | 2 | 21 | 8.7 | no | no |
| 79 | `lld_rxdesc_buf_ready` | 11552 | 29 | 8 | 21 | 27.59 | yes | no |
| 80 | `lld_con_data_tx` | 437 | 28 | 7 | 21 | 25.0 | yes | no |

## Largest Placeholder Stubs

| # | Symbol | src line | ref instr | nim instr | active |
|---:|---|---:|---:|---:|---|
| 1 | `llc_con_move_cbk` | 18305 | 64 | 2 | yes |
| 2 | `sch_prog_push` | 4879 | 63 | 123 | no |
| 3 | `lld_per_adv_list_add` | 18694 | 56 | 2 | yes |
| 4 | `lld_rx_timing_compute` | 4407 | 48 | 18 | no |
| 5 | `lld_calc_aux_rx` | 18640 | 43 | 2 | yes |
| 6 | `llc_stopped_ind_handler` | 18511 | 34 | 10 | no |
| 7 | `sch_slice_bg_remove` | 18746 | 33 | 2 | yes |
| 8 | `sch_slice_fg_remove` | 18749 | 32 | 2 | yes |
| 9 | `sch_slice_bg_add` | 18745 | 32 | 2 | yes |
| 10 | `ll_terminate_ind_handler` | 18226 | 31 | 9 | no |
| 11 | `sch_arb_event_start_isr` | 18721 | 30 | 2 | yes |
| 12 | `sch_slice_fg_add` | 18748 | 29 | 2 | yes |
| 13 | `lld_rxdesc_buf_ready` | 11552 | 29 | 8 | no |
| 14 | `lld_con_data_tx` | 437 | 28 | 7 | no |
| 15 | `sch_slice_compute` | 18747 | 27 | 2 | yes |
| 16 | `lld_per_adv_list_rem` | 18695 | 27 | 2 | yes |
| 17 | `lld_con_enc_key_load` | 18644 | 27 | 2 | yes |
| 18 | `llc_op_disconnect_ind_handler` | 18410 | 27 | 10 | no |
| 19 | `ll_version_ind_handler` | 18238 | 27 | 9 | no |
| 20 | `lld_con_tx_enc` | 18653 | 26 | 2 | yes |
| 21 | `lld_con_rx_enc` | 18652 | 26 | 2 | yes |
| 22 | `lld_con_llcp_tx` | 440 | 25 | 7 | no |
| 23 | `hci_acl_data_handler` | 18174 | 25 | 50 | no |
| 24 | `lld_con_param_update` | 18650 | 24 | 2 | yes |
| 25 | `llc_encrypt_ind_handler` | 18314 | 23 | 2 | yes |
| 26 | `sch_plan_set` | 18728 | 22 | 2 | yes |
| 27 | `lld_phy_upd_cfm_handler` | 18696 | 22 | 2 | yes |
| 28 | `lld_acl_tx_cfm_handler` | 18539 | 22 | 5 | no |
| 29 | `sch_prog_end_isr` | 4800 | 21 | 19 | no |
| 30 | `lld_con_phys_update` | 18651 | 21 | 2 | yes |
| 31 | `sch_alarm_set` | 18718 | 20 | 2 | yes |
| 32 | `lld_llcp_tx_cfm_handler` | 18675 | 20 | 8 | no |
| 33 | `lld_acl_rx_ind_handler` | 18518 | 19 | 23 | no |
| 34 | `llc_ll_reject_ind_pdu_send` | 18327 | 19 | 43 | no |
| 35 | `ll_clk_acc_rsp_handler` | 18203 | 19 | 2 | yes |
| 36 | `lld_scan_req_ind_handler` | 18712 | 18 | 2 | yes |
| 37 | `lld_llcp_rx_ind_handler` | 18664 | 18 | 8 | no |
| 38 | `lld_con_tx_len_update_for_rate` | 18655 | 17 | 2 | yes |
| 39 | `lld_con_param_upd_cfm_handler` | 18649 | 16 | 2 | yes |
| 40 | `llc_llcp_send` | 18340 | 16 | 15 | no |
| 41 | `sch_plan_req` | 18727 | 15 | 2 | yes |
| 42 | `sch_alarm_timer_isr` | 18719 | 15 | 2 | yes |
| 43 | `sch_alarm_clear` | 18716 | 15 | 2 | yes |
| 44 | `llc_llcp_state_set` | 18351 | 15 | 16 | no |
| 45 | `sch_prog_skip_isr` | 4770 | 14 | 24 | no |
| 46 | `sch_plan_shift` | 18729 | 14 | 2 | yes |
| 47 | `lld_con_offset_upd_ind_handler` | 18648 | 14 | 2 | yes |
| 48 | `llc_proc_collision_check` | 18473 | 14 | 2 | yes |
| 49 | `llc_disconnect` | 18308 | 14 | 8 | no |
| 50 | `ll_clk_acc_req_handler` | 18202 | 14 | 2 | yes |
| 51 | `lld_con_tx_len_update_for_intv` | 18654 | 13 | 2 | yes |
| 52 | `hci_msg_evt_pkupk` | 18199 | 13 | 2 | yes |
| 53 | `hci_msg_cmd_pkupk` | 18197 | 13 | 2 | yes |
| 54 | `hci_msg_cmd_cmp_pkupk` | 18195 | 13 | 2 | yes |
| 55 | `sch_prog_fifo_isr` | 4814 | 12 | 10 | no |
| 56 | `lld_disc_ind_handler` | 18657 | 12 | 10 | no |
| 57 | `hci_msg_cmd_desc_get` | 18196 | 12 | 2 | yes |
| 58 | `sch_prog_tx_isr` | 4767 | 10 | 8 | no |
| 59 | `sch_prog_rx_isr` | 4764 | 10 | 8 | no |
| 60 | `hci_command_llm_handler` | 18194 | 9 | 2 | yes |
| 61 | `sch_arb_sw_isr` | 18723 | 8 | 2 | yes |
| 62 | `lld_rpa_renew` | 18705 | 8 | 2 | yes |
| 63 | `hci_command_llc_handler` | 18193 | 7 | 2 | yes |
| 64 | `sch_slice_init` | 18750 | 5 | 2 | yes |
| 65 | `sch_plan_init` | 18726 | 5 | 2 | yes |
| 66 | `sch_arb_init` | 18722 | 5 | 2 | yes |
| 67 | `hci_msg_le_evt_desc_get` | 18200 | 5 | 2 | yes |
| 68 | `hci_msg_evt_desc_get` | 18198 | 5 | 2 | yes |
| 69 | `sch_prog_init` | 4841 | 4 | 77 | no |
| 70 | `sch_alarm_init` | 18717 | 4 | 2 | yes |
| 71 | `sch_plan_chk` | 18725 | 3 | 2 | yes |
| 72 | `lld_ral_search` | 18698 | 2 | 2 | no |
