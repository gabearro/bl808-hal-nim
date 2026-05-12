# WiFi FW Under-Implemented Methods (vs tools/ref/libwifi_bl808.a)

- Reference: `tools/ref/libwifi_bl808.a`
- Nim object: `build/hw-validation-wireless-build-final-sanity/nimcache/m0_wifi_nimfw_hal_test/kernel/@pbl808@swifi_fw.nim.c.o`
- Reference functions: **473**
- Nim functions: **669**
- Missing reference functions in Nim: **0**
- Method count where Nim is smaller than blob: **25**
- Severity buckets: >=200: 0, 100-199: 0, 50-99: 0, 25-49: 0, 10-24: 1, 1-9: 24

## Full list

| # | Symbol | src line | ref | nim | missing | nim/ref % |
|---:|---|---:|---:|---:|---:|---:|
| 1 | `bl_tpc_update_power_table_channel_offset` | 20785 | 14 | 3 | 11 | 21.43 |
| 2 | `ipc_emb_notify` | 22673 | 14 | 6 | 8 | 42.86 |
| 3 | `co_list_push_front` | 1634 | 10 | 4 | 6 | 40.0 |
| 4 | `co_list_extract` | 1651 | 10 | 4 | 6 | 40.0 |
| 5 | `chan_ctxt_get_remaining_time_ms` | 6012 | 11 | 6 | 5 | 54.55 |
| 6 | `co_list_push_back` | 1621 | 10 | 5 | 5 | 50.0 |
| 7 | `mfp_add_mgmt_mic` | 1395 | 15 | 11 | 4 | 73.33 |
| 8 | `co_pool_alloc` | 1882 | 10 | 6 | 4 | 60.0 |
| 9 | `rxl_pd_append` | 18110 | 10 | 7 | 3 | 70.0 |
| 10 | `rxl_hd_append` | 18081 | 10 | 7 | 3 | 70.0 |
| 11 | `scanu_rm_exist_ssid` | 8232 | 17 | 15 | 2 | 88.24 |
| 12 | `coex_dump_wifi` | 1276 | 16 | 14 | 2 | 87.5 |
| 13 | `cfg_api_element_dump` | 24815 | 15 | 13 | 2 | 86.67 |
| 14 | `me_freq_to_chan_ptr` | 1380 | 8 | 6 | 2 | 75.0 |
| 15 | `me_bw_check` | 1385 | 6 | 4 | 2 | 66.67 |
| 16 | `coex_dump_pta` | 1277 | 15 | 14 | 1 | 93.33 |
| 17 | `co_pool_init` | 1856 | 15 | 14 | 1 | 93.33 |
| 18 | `rx_swdesc_init` | 17817 | 6 | 5 | 1 | 83.33 |
| 19 | `scanu_find_result` | 1376 | 5 | 4 | 1 | 80.0 |
| 20 | `bl_wifi_unset_appie_internal` | 23339 | 5 | 4 | 1 | 80.0 |
| 21 | `me_legacy_ridx_max` | 1384 | 4 | 3 | 1 | 75.0 |
| 22 | `bl_wifi_unregister_wpa_cb_internal` | 23311 | 4 | 3 | 1 | 75.0 |
| 23 | `notifier_chain_unregsiter` | 23101 | 2 | 1 | 1 | 50.0 |
| 24 | `notifier_chain_regsiter` | 23099 | 2 | 1 | 1 | 50.0 |
| 25 | `bl_wifi_sta_update_ap_info_internal` | 23624 | 2 | 1 | 1 | 50.0 |
