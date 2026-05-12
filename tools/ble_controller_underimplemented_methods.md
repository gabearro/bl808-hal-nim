# BLE Controller Under-Implemented Methods

- Reference: `build/vendor_bl808_fw/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Nim object/archive: `build/hw-validation-wireless-build-after-hci-pack/nimcache/m0_ble_nim_controller_hal_test/kernel/@pbl808@sblecontroller.nim.c.o`
- Source: `src/bl808/blecontroller.nim`
- Reference functions: **452**
- Nim functions: **980**
- Common functions: **452**
- Missing reference functions in Nim: **0**
- Method count where Nim is smaller than blob: **399**
- Placeholder stubs in source: **186**
- Placeholder stubs matching reference symbols: **186**
- Severity buckets: >=200: 0, 100-199: 1, 50-99: 10, 25-49: 64, 10-24: 187, 1-9: 137
- Note: instruction deltas are local to each symbol body; wrappers that delegate to helper functions can still appear short.

## Largest Shorter Methods

| # | Symbol | src line | ref | nim | missing | nim/ref % | stub |
|---:|---|---:|---:|---:|---:|---:|---|
| 1 | `GF_Jacobian_Point_Addition256` | 6750 | 132 | 2 | 130 | 1.52 | yes |
| 2 | `bigHexInversion256` | 5083 | 75 | 6 | 69 | 8.0 | no |
| 3 | `ll_length_req_handler` | 6790 | 66 | 2 | 64 | 3.03 | yes |
| 4 | `llc_con_move_cbk` | 6809 | 64 | 2 | 62 | 3.12 | yes |
| 5 | `sch_prog_push` | 6919 | 63 | 2 | 61 | 3.17 | yes |
| 6 | `rwip_reset` | 5522 | 84 | 29 | 55 | 34.52 | no |
| 7 | `lld_per_adv_list_add` | 6871 | 56 | 2 | 54 | 3.57 | yes |
| 8 | `lld_con_data_flow_set` | 6848 | 56 | 2 | 54 | 3.57 | yes |
| 9 | `ll_connection_update_ind_handler` | 6785 | 55 | 2 | 53 | 3.64 | yes |
| 10 | `ll_connection_param_req_handler` | 6783 | 55 | 2 | 53 | 3.64 | yes |
| 11 | `rwip_init` | 5509 | 94 | 43 | 51 | 45.74 | no |
| 12 | `btble_controller_init` | 5338 | 59 | 12 | 47 | 20.34 | no |
| 13 | `ble_util_buf_init` | 5381 | 49 | 2 | 47 | 4.08 | no |
| 14 | `lld_rx_timing_compute` | 6876 | 48 | 2 | 46 | 4.17 | yes |
| 15 | `llc_clk_acc_modify` | 6808 | 48 | 2 | 46 | 4.17 | yes |
| 16 | `hci_le_en_enc_cmd_handler` | 6417 | 73 | 29 | 44 | 39.73 | no |
| 17 | `aes_k2` | 6195 | 45 | 2 | 43 | 4.44 | no |
| 18 | `aes_cmac` | 6074 | 45 | 2 | 43 | 4.44 | no |
| 19 | `lld_calc_aux_rx` | 6844 | 43 | 2 | 41 | 4.65 | yes |
| 20 | `hci_disconnect_cmd_handler` | 6402 | 57 | 16 | 41 | 28.07 | no |
| 21 | `phy_upd_proc_start` | 5864 | 40 | 1 | 39 | 2.5 | no |
| 22 | `llm_ch_map_update_ind_handler` | 6886 | 41 | 2 | 39 | 4.88 | yes |
| 23 | `hci_le_rem_con_param_req_reply_cmd_handler` | 6453 | 69 | 31 | 38 | 44.93 | no |
| 24 | `llm_ch_map_update` | 6885 | 38 | 2 | 36 | 5.26 | yes |
| 25 | `hci_vs_set_max_rx_size_and_time_cmd_handler` | 6594 | 46 | 10 | 36 | 21.74 | no |
| 26 | `btble_rf_init` | 5479 | 38 | 2 | 36 | 5.26 | no |
| 27 | `llc_auth_payl_nearly_to_handler` | 6805 | 37 | 2 | 35 | 5.41 | yes |
| 28 | `ll_feature_rsp_handler` | 6789 | 37 | 2 | 35 | 5.41 | yes |
| 29 | `co_time_timer_periodic_set` | 6249 | 35 | 1 | 34 | 2.86 | no |
| 30 | `llc_init_term_proc` | 6812 | 35 | 2 | 33 | 5.71 | yes |
| 31 | `ble_util_buf_rx_free` | 5421 | 35 | 2 | 33 | 5.71 | no |
| 32 | `SubtractBigHexUint32_256` | 6757 | 35 | 2 | 33 | 5.71 | yes |
| 33 | `nvds_init` | 6646 | 34 | 2 | 32 | 5.88 | no |
| 34 | `llc_stopped_ind_handler` | 6834 | 34 | 2 | 32 | 5.88 | yes |
| 35 | `ll_min_used_channels_ind_handler` | 6792 | 34 | 2 | 32 | 5.88 | yes |
| 36 | `co_time_timer_long_set` | 6246 | 33 | 1 | 32 | 3.03 | no |
| 37 | `btble_ke_msg_send_basic` | 5246 | 34 | 2 | 32 | 5.88 | no |
| 38 | `bt_onchiphci_hanlde_rx_acl` | 5367 | 34 | 2 | 32 | 5.88 | no |
| 39 | `sch_slice_bg_remove` | 6924 | 33 | 2 | 31 | 6.06 | yes |
| 40 | `lld_adv_end_ind_handler` | 6839 | 33 | 2 | 31 | 6.06 | yes |
| 41 | `sch_slice_fg_remove` | 6927 | 32 | 2 | 30 | 6.25 | yes |
| 42 | `sch_slice_bg_add` | 6923 | 32 | 2 | 30 | 6.25 | yes |
| 43 | `llc_auth_payl_real_to_handler` | 6806 | 32 | 2 | 30 | 6.25 | yes |
| 44 | `co_time_init` | 6234 | 31 | 1 | 30 | 3.23 | no |
| 45 | `SubtractFromSelfBigHexSign256` | 6759 | 32 | 2 | 30 | 6.25 | yes |
| 46 | `SubtractBigHexMod256` | 6756 | 32 | 2 | 30 | 6.25 | yes |
| 47 | `sch_arb_insert` | 2710 | 31 | 2 | 29 | 6.45 | no |
| 48 | `nvds_put` | 6659 | 31 | 2 | 29 | 6.45 | no |
| 49 | `llc_proc_reg` | 6833 | 31 | 2 | 29 | 6.45 | yes |
| 50 | `ll_terminate_ind_handler` | 6803 | 31 | 2 | 29 | 6.45 | yes |
| 51 | `hci_tl_send` | 3531 | 31 | 2 | 29 | 6.45 | no |
| 52 | `co_time_timer_set` | 6243 | 30 | 1 | 29 | 3.33 | no |
| 53 | `aes_h9` | 6182 | 31 | 2 | 29 | 6.45 | no |
| 54 | `sch_arb_event_start_isr` | 6907 | 30 | 2 | 28 | 6.67 | yes |
| 55 | `ll_phy_req_handler` | 6795 | 30 | 2 | 28 | 6.67 | yes |
| 56 | `sch_slice_fg_add` | 6926 | 29 | 2 | 27 | 6.9 | yes |
| 57 | `rwip_wlcoex_set` | 5547 | 29 | 2 | 27 | 6.9 | no |
| 58 | `lld_rxdesc_buf_ready` | 6877 | 29 | 2 | 27 | 6.9 | yes |
| 59 | `flash_erase` | 6291 | 29 | 2 | 27 | 6.9 | no |
| 60 | `btble_aes_encrypt` | 5958 | 31 | 4 | 27 | 12.9 | no |
| 61 | `GF_Point_Jacobian_To_Affine256` | 5087 | 28 | 1 | 27 | 3.57 | no |
| 62 | `lld_con_data_tx` | 6850 | 28 | 2 | 26 | 7.14 | yes |
| 63 | `co_util_unpack` | 6262 | 28 | 2 | 26 | 7.14 | no |
| 64 | `btble_ke_msg_alloc` | 5238 | 28 | 2 | 26 | 7.14 | no |
| 65 | `btble_ke_init` | 5209 | 28 | 2 | 26 | 7.14 | no |
| 66 | `aes_cmac_start` | 6078 | 28 | 2 | 26 | 7.14 | no |
| 67 | `aes_cmac_continue` | 6082 | 29 | 3 | 26 | 10.34 | no |
| 68 | `sch_slice_compute` | 6925 | 27 | 2 | 25 | 7.41 | yes |
| 69 | `lld_per_adv_list_rem` | 6872 | 27 | 2 | 25 | 7.41 | yes |
| 70 | `lld_con_enc_key_load` | 6851 | 27 | 2 | 25 | 7.41 | yes |
| 71 | `lld_aa_gen` | 6710 | 61 | 36 | 25 | 59.02 | no |
| 72 | `llc_op_disconnect_ind_handler` | 6820 | 27 | 2 | 25 | 7.41 | yes |
| 73 | `ll_version_ind_handler` | 6804 | 27 | 2 | 25 | 7.41 | yes |
| 74 | `co_util_pack` | 6258 | 27 | 2 | 25 | 7.41 | no |
| 75 | `aes_start` | 5952 | 26 | 1 | 25 | 3.85 | no |
| 76 | `specialModP256` | 6929 | 26 | 2 | 24 | 7.69 | yes |
| 77 | `lld_con_tx_enc` | 6865 | 26 | 2 | 24 | 7.69 | yes |
| 78 | `lld_con_rx_enc` | 6863 | 26 | 2 | 24 | 7.69 | yes |
| 79 | `llc_proc_unreg` | 5908 | 25 | 1 | 24 | 4.0 | no |
| 80 | `btble_controller_deinit` | 5342 | 26 | 2 | 24 | 7.69 | no |

## Largest Placeholder Stubs

| # | Symbol | src line | ref instr | nim instr |
|---:|---|---:|---:|---:|
| 1 | `GF_Jacobian_Point_Addition256` | 6750 | 132 | 2 |
| 2 | `ll_length_req_handler` | 6790 | 66 | 2 |
| 3 | `llc_con_move_cbk` | 6809 | 64 | 2 |
| 4 | `sch_prog_push` | 6919 | 63 | 2 |
| 5 | `lld_per_adv_list_add` | 6871 | 56 | 2 |
| 6 | `lld_con_data_flow_set` | 6848 | 56 | 2 |
| 7 | `ll_connection_update_ind_handler` | 6785 | 55 | 2 |
| 8 | `ll_connection_param_req_handler` | 6783 | 55 | 2 |
| 9 | `lld_rx_timing_compute` | 6876 | 48 | 2 |
| 10 | `llc_clk_acc_modify` | 6808 | 48 | 2 |
| 11 | `lld_calc_aux_rx` | 6844 | 43 | 2 |
| 12 | `llm_ch_map_update_ind_handler` | 6886 | 41 | 2 |
| 13 | `llm_ch_map_update` | 6885 | 38 | 2 |
| 14 | `llc_auth_payl_nearly_to_handler` | 6805 | 37 | 2 |
| 15 | `ll_feature_rsp_handler` | 6789 | 37 | 2 |
| 16 | `llc_init_term_proc` | 6812 | 35 | 2 |
| 17 | `SubtractBigHexUint32_256` | 6757 | 35 | 2 |
| 18 | `llc_stopped_ind_handler` | 6834 | 34 | 2 |
| 19 | `ll_min_used_channels_ind_handler` | 6792 | 34 | 2 |
| 20 | `sch_slice_bg_remove` | 6924 | 33 | 2 |
| 21 | `lld_adv_end_ind_handler` | 6839 | 33 | 2 |
| 22 | `sch_slice_fg_remove` | 6927 | 32 | 2 |
| 23 | `sch_slice_bg_add` | 6923 | 32 | 2 |
| 24 | `llc_auth_payl_real_to_handler` | 6806 | 32 | 2 |
| 25 | `SubtractFromSelfBigHexSign256` | 6759 | 32 | 2 |
| 26 | `SubtractBigHexMod256` | 6756 | 32 | 2 |
| 27 | `llc_proc_reg` | 6833 | 31 | 2 |
| 28 | `ll_terminate_ind_handler` | 6803 | 31 | 2 |
| 29 | `sch_arb_event_start_isr` | 6907 | 30 | 2 |
| 30 | `ll_phy_req_handler` | 6795 | 30 | 2 |
| 31 | `sch_slice_fg_add` | 6926 | 29 | 2 |
| 32 | `lld_rxdesc_buf_ready` | 6877 | 29 | 2 |
| 33 | `lld_con_data_tx` | 6850 | 28 | 2 |
| 34 | `sch_slice_compute` | 6925 | 27 | 2 |
| 35 | `lld_per_adv_list_rem` | 6872 | 27 | 2 |
| 36 | `lld_con_enc_key_load` | 6851 | 27 | 2 |
| 37 | `llc_op_disconnect_ind_handler` | 6820 | 27 | 2 |
| 38 | `ll_version_ind_handler` | 6804 | 27 | 2 |
| 39 | `specialModP256` | 6929 | 26 | 2 |
| 40 | `lld_con_tx_enc` | 6865 | 26 | 2 |
| 41 | `lld_con_rx_enc` | 6863 | 26 | 2 |
| 42 | `lld_con_llcp_tx` | 6854 | 25 | 2 |
| 43 | `hci_acl_data_handler` | 6766 | 25 | 2 |
| 44 | `MultiplyBigHexModP256` | 6753 | 25 | 2 |
| 45 | `llm_link_disc` | 6896 | 24 | 2 |
| 46 | `lld_con_param_update` | 6858 | 24 | 2 |
| 47 | `lld_adv_rand_addr_update` | 6841 | 24 | 2 |
| 48 | `lld_con_data_len_update` | 6849 | 23 | 2 |
| 49 | `llc_encrypt_ind_handler` | 6811 | 23 | 2 |
| 50 | `GF_Jacobian_Point_Double256` | 6751 | 23 | 2 |
| 51 | `sch_plan_set` | 6914 | 22 | 2 |
| 52 | `lld_phy_upd_cfm_handler` | 6873 | 22 | 2 |
| 53 | `lld_ch_map_upd_cfm_handler` | 6846 | 22 | 2 |
| 54 | `lld_acl_tx_cfm_handler` | 6836 | 22 | 2 |
| 55 | `ll_connection_param_rsp_handler` | 6784 | 22 | 2 |
| 56 | `sch_prog_end_isr` | 6916 | 21 | 2 |
| 57 | `lld_white_list_rem` | 6880 | 21 | 2 |
| 58 | `lld_con_time_get` | 6864 | 21 | 2 |
| 59 | `lld_con_pref_slave_evt_dur_set` | 6861 | 21 | 2 |
| 60 | `lld_con_phys_update` | 6860 | 21 | 2 |
| 61 | `co_djob_unreg` | 6764 | 21 | 2 |
| 62 | `sch_alarm_set` | 6905 | 20 | 2 |
| 63 | `lld_llcp_tx_cfm_handler` | 6870 | 20 | 2 |
| 64 | `ll_length_rsp_handler` | 6791 | 20 | 2 |
| 65 | `lld_acl_rx_ind_handler` | 6835 | 19 | 2 |
| 66 | `llc_op_feats_exch_ind_handler` | 6823 | 19 | 2 |
| 67 | `llc_ll_reject_ind_pdu_send` | 6814 | 19 | 2 |
| 68 | `ll_phy_update_ind_handler` | 6797 | 19 | 2 |
| 69 | `ll_clk_acc_rsp_handler` | 6782 | 19 | 2 |
| 70 | `lld_scan_req_ind_handler` | 6878 | 18 | 2 |
| 71 | `lld_llcp_rx_ind_handler` | 6869 | 18 | 2 |
| 72 | `lld_con_init` | 6853 | 18 | 2 |
| 73 | `lld_adv_restart` | 6842 | 18 | 2 |
| 74 | `llc_op_phy_upd_ind_handler` | 6825 | 18 | 2 |
| 75 | `llc_op_con_upd_ind_handler` | 6819 | 18 | 2 |
| 76 | `ll_enc_req_handler` | 6786 | 18 | 2 |
| 77 | `llm_cmd_stat_send` | 6889 | 17 | 2 |
| 78 | `llm_cmd_cmp_send` | 6888 | 17 | 2 |
| 79 | `lld_con_tx_len_update_for_rate` | 6867 | 17 | 2 |
| 80 | `llc_op_ver_exch_ind_handler` | 6826 | 17 | 2 |
