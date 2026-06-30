/*
 * BL808 vendor supplicant overlay.
 *
 * Keep the vendor wpa.c translation unit intact, but replace wpa_set_bss with
 * the PMF-capable behavior the WiFi manager requests for default connects.
 * The SDK implementation only sets pmf_cfg when PMF is required; WPA3
 * transition APs also need WPA2 clients to advertise MFPC.
 */
#define wpa_set_bss bl808_vendor_wpa_set_bss
#define aes_unwrap bl808_wpa_aes_unwrap_nonoverlap
#include "../../build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa.c"
#undef aes_unwrap
#undef wpa_set_bss

uint32_t bl808_wpa_current_state(void)
{
    return (uint32_t)gWpaSm.wpa_state;
}

extern volatile uint32_t nimfw_dbg_keydata_decrypt_calls;
extern volatile uint32_t nimfw_dbg_keydata_decrypt_len;
extern volatile uint32_t nimfw_dbg_keydata_decrypt_out_len;
extern volatile uint32_t nimfw_dbg_keydata_decrypt_ok;
extern volatile uint32_t nimfw_dbg_keydata_decrypt_fail;

int bl808_wpa_aes_unwrap_nonoverlap(const u8 *kek, int n,
                                    const u8 *cipher, u8 *plain)
{
    u8 unwrapped[256];
    size_t out_len;
    int rc;

    nimfw_dbg_keydata_decrypt_calls++;
    if (n <= 0 || (size_t)n > (sizeof(unwrapped) / 8)) {
        nimfw_dbg_keydata_decrypt_fail++;
        return -1;
    }
    out_len = (size_t)n * 8;
    nimfw_dbg_keydata_decrypt_len = (uint32_t)((n + 1) * 8);
    nimfw_dbg_keydata_decrypt_out_len = (uint32_t)out_len;
    rc = aes_unwrap(kek, n, cipher, unwrapped);
    if (rc != 0) {
        nimfw_dbg_keydata_decrypt_fail++;
        return rc;
    }
    memcpy(plain, unwrapped, out_len);
    nimfw_dbg_keydata_decrypt_ok++;
    return 0;
}

static u16 bl808_mgmt_group_cipher_to_supp(u8 mgmt_group_cipher)
{
    u16 mapped = cipher_type_map_public_to_supp(mgmt_group_cipher);

    return mapped;
}

int wpa_set_bss(u8 vif_idx, u8 sta_idx, char *macddr, char *bssid,
                u8 pairwise_cipher, u8 group_cipher, bool pmf_required,
                u8 mgmt_group_cipher)
{
    int res = 0;
    struct wpa_sm *sm = &gWpaSm;

    sm->vif_idx = vif_idx;
    sm->sta_idx = sta_idx;

    sm->pairwise_cipher = cipher_type_map_public_to_supp(pairwise_cipher);
    sm->group_cipher = cipher_type_map_public_to_supp(group_cipher);
    sm->rx_replay_counter_set = false;
    memset(sm->rx_replay_counter, 0, WPA_REPLAY_COUNTER_LEN);
#ifdef CONFIG_SUPPLICANT_REKEY_WHEN_TIMEDOUT
    sm->wpa_ptk_rekey = 0;
#endif
    sm->renew_snonce = true;
    memcpy(sm->own_addr, macddr, ETH_ALEN);
    memcpy(sm->bssid, bssid, ETH_ALEN);
    sm->ap_notify_completed_rsne = bl_wifi_sta_is_ap_notify_completed_rsne_internal();

    if (sm->key_mgmt == WPA_KEY_MGMT_SAE ||
        is_wpa2_enterprise_connection()) {
        if (!bl_wifi_skip_supp_pmkcaching()) {
#ifdef CONFIG_PMKSA_CACHE
            pmksa_cache_set_current(sm, NULL, (const u8 *)bssid, 0, 0);
#endif
            wpa_sm_set_pmk_from_pmksa(sm);
        } else {
#ifdef CONFIG_PMKSA_CACHE
            struct rsn_pmksa_cache_entry *entry = NULL;

            if (sm->pmksa) {
                entry = pmksa_cache_get(sm->pmksa, (const u8 *)bssid, NULL, NULL);
            }
            if (entry) {
                pmksa_cache_flush(sm->pmksa, NULL, entry->pmk, entry->pmk_len);
            }
#endif
        }
    }

#ifdef CONFIG_IEEE80211W
    u16 mapped_mgmt_group_cipher =
        bl808_mgmt_group_cipher_to_supp(mgmt_group_cipher);
    if (pmf_required && mapped_mgmt_group_cipher == WPA_CIPHER_NONE) {
        mapped_mgmt_group_cipher = WPA_CIPHER_AES_128_CMAC;
    }

    if (pmf_required ||
        mapped_mgmt_group_cipher == WPA_CIPHER_AES_128_CMAC) {
        sm->pmf_cfg.capable = true;
        sm->pmf_cfg.required = pmf_required;
        sm->mgmt_group_cipher = mapped_mgmt_group_cipher;
    } else {
        memset(&sm->pmf_cfg, 0, sizeof(sm->pmf_cfg));
        sm->mgmt_group_cipher = WPA_CIPHER_NONE;
    }
#ifdef BL808_WIFI_VERBOSE_CONNECT
    printf("[WPA] bss pmf required=%u mgmt=%u mapped=0x%X capable=%u\r\n",
           pmf_required ? 1 : 0, mgmt_group_cipher,
           (unsigned int)sm->mgmt_group_cipher,
           sm->pmf_cfg.capable ? 1 : 0);
#endif
#endif

    sm->assoc_wpa_ie_len = sizeof(sm->assoc_wpa_ie);
    res = wpa_gen_wpa_ie(sm, sm->assoc_wpa_ie, sm->assoc_wpa_ie_len);
    if (res < 0)
        return -1;
    sm->assoc_wpa_ie_len = res;
    wpa_config_assoc_ie(sm->vif_idx, sm->proto, sm->assoc_wpa_ie,
                        sm->assoc_wpa_ie_len);
    return 0;
}
