# WiFi FW Under-Implemented Methods (vs tools/ref/libwifi_bl808.a)

- Reference: `tools/ref/libwifi_bl808.a`
- Nim object: `build/hw-validation-wifi-nimfw-tpc-prod-build-c1/nimcache/m0_wifi_nimfw_hal_test/kernel/@pbl808@swifi_fw.nim.c.o`
- Reference functions: **473**
- Nim functions: **670**
- Missing reference functions in Nim: **0**
- Method count where Nim is smaller than blob: **20**
- Severity buckets: >=200: 0, 100-199: 0, 50-99: 0, 25-49: 0, 10-24: 0, 1-9: 20

## Full list

| # | Symbol | src line | ref | nim | missing | nim/ref % |
|---:|---|---:|---:|---:|---:|---:|
| 1 | `ipc_emb_notify` | 26235 | 14 | 6 | 8 | 42.86 |
| 2 | `co_list_push_front` | 5208 | 10 | 4 | 6 | 40.0 |
| 3 | `co_list_extract` | 5225 | 10 | 4 | 6 | 40.0 |
| 4 | `co_list_push_back` | 5195 | 10 | 5 | 5 | 50.0 |
| 5 | `chan_ctxt_get_remaining_time_ms` | 9501 | 11 | 6 | 5 | 54.55 |
| 6 | `co_pool_alloc` | 5456 | 10 | 6 | 4 | 60.0 |
| 7 | `rxl_hd_append` | 21785 | 10 | 8 | 2 | 80.0 |
| 8 | `coex_dump_wifi` | 4857 | 16 | 14 | 2 | 87.5 |
| 9 | `cfg_api_element_dump` | 28385 | 15 | 13 | 2 | 86.67 |
| 10 | `scanu_rm_exist_ssid` | 11709 | 17 | 16 | 1 | 94.12 |
| 11 | `rx_swdesc_init` | 21523 | 6 | 5 | 1 | 83.33 |
| 12 | `notifier_chain_unregsiter` | 26663 | 2 | 1 | 1 | 50.0 |
| 13 | `notifier_chain_regsiter` | 26661 | 2 | 1 | 1 | 50.0 |
| 14 | `me_legacy_ridx_max` | 4965 | 4 | 3 | 1 | 75.0 |
| 15 | `me_freq_to_chan_ptr` | 4961 | 8 | 7 | 1 | 87.5 |
| 16 | `coex_dump_pta` | 4858 | 15 | 14 | 1 | 93.33 |
| 17 | `co_pool_init` | 5430 | 15 | 14 | 1 | 93.33 |
| 18 | `bl_wifi_unset_appie_internal` | 26900 | 5 | 4 | 1 | 80.0 |
| 19 | `bl_wifi_unregister_wpa_cb_internal` | 26872 | 4 | 3 | 1 | 75.0 |
| 20 | `bl_wifi_sta_update_ap_info_internal` | 27187 | 2 | 1 | 1 | 50.0 |
