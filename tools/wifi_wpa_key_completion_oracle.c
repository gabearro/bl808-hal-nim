/* Host substitutes for the driver, timers, and PBKDF2. The WPA state machine
 * and SDK callback are linked unchanged. */
#include <bl_supplicant/bl_wifi_driver.h>
#include "utils/includes.h"
#include "utils/common.h"
#include "rsn_supp/wpa.h"
#include "rsn_supp/wpa_i.h"
#include "common/wpa_common.h"
#include "crypto/sha1.h"
#include "supplicant_api.h"

extern struct wpa_sm gWpaSm;
/* The SDK declares the callback type in its table, not the symbol itself. */
extern __typeof__(*(((struct wpa_funcs *)0)->wpa_sta_connect)) wpa_sta_connect;
extern int bl808_wpa_sta_connect_result(void *callback, void *params);

volatile uint32_t nimfw_dbg_eapol_tx_cb, nimfw_dbg_send_4of4_cb;
volatile uint32_t nimfw_dbg_install_ptk, nimfw_dbg_wpa_ptk_installed, nimfw_dbg_wpa_deauth;

enum key_fault { NO_FAULT, REJECT_PTK, REJECT_GTK };
static enum key_fault fault;
static unsigned ptk_writes, gtk_writes, successes, failures, disarms;
static unsigned arms, pbkdf2_calls, custom_calls;
static bool reject_pbkdf2, published_during_pbkdf2;
static const uint8_t sta_index = 2;
static const uint8_t vif_index = 0;
static const uint8_t old_sta_index = 3;
static const uint8_t old_vif_index = 1;
static const char test_ssid[] = "host-test-ssid";
static const char test_phrase[] = "host-test-phrase";
static const uint8_t derived_byte = 0x3c;
static wifi_connect_parm_t connect_params;

bool bl_wifi_sta_is_running_internal(void)
{
    return true;
}

int bl_wifi_set_sta_key_internal(uint8_t vif, uint8_t sta, wpa_alg_t alg,
                                int index, int tx, uint8_t *seq, size_t seq_len,
                                uint8_t *key, size_t len, bool pairwise)
{
    if (vif != vif_index || sta != sta_index || len != 16)
        abort();
    if (pairwise)
        ptk_writes++;
    else
        gtk_writes++;
    return fault == (pairwise ? REJECT_PTK : REJECT_GTK) ? -1 : 0;
}

bool bl_wifi_auth_done_internal(uint8_t sta, uint16_t reason)
{
    if (sta != sta_index)
        abort();
    successes += reason == 0;
    failures += reason != 0;
    return true;
}

int bl_wifi_get_sta_gtk(uint8_t vif, uint8_t *buf, uint8_t *len)
{
    return -1;
}

void bl_wifi_timer_disarm(bl_wifi_timer_t *timer)
{
    if (timer != &gWpaSm.fourway_hs_timer)
        abort();
    disarms++;
}

void bl_wifi_timer_setfn(bl_wifi_timer_t *timer, bl_wifi_timer_func_t *fn, void *arg)
{
    if (timer != &gWpaSm.fourway_hs_timer || fn == NULL)
        abort();
}

void bl_wifi_timer_arm(bl_wifi_timer_t *timer, uint32_t time_ms, bool repeat)
{
    if (timer != &gWpaSm.fourway_hs_timer || time_ms == 0 || repeat)
        abort();
    arms++;
}

int pbkdf2_sha1(const char *passphrase, const char *ssid, size_t ssid_len,
                int iterations, u8 *buf, size_t buflen)
{
    if (strcmp(passphrase, test_phrase) != 0 || ssid_len != sizeof test_ssid - 1
        || memcmp(ssid, test_ssid, ssid_len) != 0 || iterations != 4096
        || buflen != PMK_LEN)
        abort();
    pbkdf2_calls++;
    published_during_pbkdf2 |= gWpaSm.vif_idx != old_vif_index
        || gWpaSm.sta_idx != old_sta_index || gWpaSm.wpa_state != WPA_DISCONNECTED;
    /* A failing implementation can still overwrite part of its output. */
    memset(buf, derived_byte, reject_pbkdf2 ? 7 : buflen);
    return reject_pbkdf2 ? -1 : 0;
}

static void custom_connect(wifi_connect_parm_t *params)
{
    if (params != &connect_params)
        abort();
    custom_calls++;
}

static bool pmk_is_filled(uint8_t byte)
{
    for (size_t i = 0; i < sizeof gWpaSm.pmk; i++) {
        if (gWpaSm.pmk[i] != byte)
            return false;
    }
    return true;
}

static bool run_connect_cases(void)
{
    struct wpa_sm *sm = &gWpaSm;
    memset(sm, 0, sizeof *sm);
    sm->vif_idx = old_vif_index;
    sm->sta_idx = old_sta_index;
    sm->wpa_state = WPA_DISCONNECTED;
    sm->key_mgmt = WPA_KEY_MGMT_PSK;
    sm->pmk_len = PMK_LEN;
    memset(sm->pmk, 0xa5, sizeof sm->pmk);

    connect_params.vif_idx = vif_index;
    connect_params.sta_idx = sta_index;
    connect_params.proto = SEC_PROTO_WPA2;
    connect_params.key_mgmt = WPA_KEY_MGMT_PSK;
    connect_params.ssid.len = sizeof test_ssid - 1;
    memcpy(connect_params.ssid.ssid, test_ssid, connect_params.ssid.len);
    memcpy(connect_params.passphrase, test_phrase, sizeof test_phrase);

    reject_pbkdf2 = true;
    int rc = bl808_wpa_sta_connect_result((void *)wpa_sta_connect, &connect_params);
    bool cleared = sm->pmk_len == 0 && pmk_is_filled(0);
    bool unpublished = !published_during_pbkdf2 && sm->vif_idx == old_vif_index
        && sm->sta_idx == old_sta_index && sm->wpa_state == WPA_DISCONNECTED;
    bool rejected = rc != 0 && pbkdf2_calls == 1 && cleared && unpublished && arms == 0;
    printf("%s partial PBKDF2 failure: rc=%d calls=%u PMK cleared=%u unpublished=%u timer-arms=%u\n",
           rejected ? "PASS" : "FAIL", rc, pbkdf2_calls, (unsigned)cleared,
           (unsigned)unpublished, arms);

    reject_pbkdf2 = false;
    rc = bl808_wpa_sta_connect_result((void *)wpa_sta_connect, &connect_params);
    bool derived = sm->pmk_len == PMK_LEN && pmk_is_filled(derived_byte);
    bool published = sm->vif_idx == vif_index && sm->sta_idx == sta_index
        && sm->wpa_state == WPA_AUTHENTICATING;
    bool retried = rc == 0 && pbkdf2_calls == 2 && derived && published && arms == 1;
    printf("%s PBKDF2 retry: rc=%d calls=%u PMK installed=%u authenticating=%u timer-arms=%u\n",
           retried ? "PASS" : "FAIL", rc, pbkdf2_calls, (unsigned)derived,
           (unsigned)published, arms);

    unsigned previous_calls = pbkdf2_calls, previous_arms = arms;
    rc = bl808_wpa_sta_connect_result((void *)custom_connect, &connect_params);
    bool forwarded = rc == 0 && custom_calls == 1 && pbkdf2_calls == previous_calls
        && arms == previous_arms;
    printf("%s custom void callback: rc=%d calls=%u\n",
           forwarded ? "PASS" : "FAIL", rc, custom_calls);

    const char raw_hex[] = "000102030405060708090a0b0c0d0e0f"
                           "101112131415161718191a1b1c1d1e1f";
    memcpy(connect_params.passphrase, raw_hex, sizeof raw_hex);
    rc = bl808_wpa_sta_connect_result((void *)wpa_sta_connect, &connect_params);
    bool raw_matches = sm->pmk_len == PMK_LEN;
    for (size_t i = 0; i < sizeof sm->pmk; i++)
        raw_matches &= sm->pmk[i] == i;
    bool raw = rc == 0 && raw_matches && pbkdf2_calls == previous_calls
        && arms == previous_arms + 1;
    printf("%s raw hex PMK: rc=%d PMK installed=%u PBKDF2 calls=%u timer-arms=%u\n",
           raw ? "PASS" : "FAIL", rc, (unsigned)raw_matches, pbkdf2_calls, arms);

    const int supplied_key_modes[] = { WPA_KEY_MGMT_SAE, WPA_KEY_MGMT_IEEE8021X };
    bool supplied = true;
    for (size_t i = 0; i < sizeof supplied_key_modes / sizeof supplied_key_modes[0]; i++) {
        sm->key_mgmt = supplied_key_modes[i];
        sm->wpa_state = WPA_DISCONNECTED;
        memset(sm->pmk, 0x5a, sizeof sm->pmk);
        sm->pmk_len = PMK_LEN;
        memset(connect_params.passphrase, 0, sizeof connect_params.passphrase);
        previous_arms = arms;
        rc = bl808_wpa_sta_connect_result((void *)wpa_sta_connect, &connect_params);
        supplied &= rc == 0 && sm->pmk_len == PMK_LEN && pmk_is_filled(0x5a)
            && pbkdf2_calls == previous_calls && arms == previous_arms + 1
            && sm->wpa_state == WPA_AUTHENTICATING;
    }
    printf("%s supplied key modes preserve the existing PMK\n", supplied ? "PASS" : "FAIL");

    return rejected && retried && forwarded && raw && supplied;
}

static bool run_case(const char *name, enum key_fault injected_fault)
{
    struct wpa_sm *sm = &gWpaSm;
    memset(sm, 0, sizeof *sm);
    fault = injected_fault;
    ptk_writes = gtk_writes = successes = failures = disarms = 0;
    sm->vif_idx = vif_index;
    sm->sta_idx = sta_index;
    sm->wpa_state = WPA_LAST_HALF_4WAY_HANDSHAKE;
    sm->pairwise_cipher = WPA_CIPHER_CCMP;
    sm->key_install = true;
    sm->key_info = WPA_KEY_INFO_INSTALL | WPA_KEY_INFO_SECURE;
    sm->gd.gtk_len = 16;
    sm->gd.alg = WIFI_WPA_ALG_CCMP;
    sm->gd.keyidx = 1;
    /* Private BL808 SDK flag set after submitting message 4. */
    sm->txcb_flags = 1u << 13;

    eapol_txcb(NULL);
    eapol_txcb(NULL); /* A duplicate completion must not emit a second result. */

    bool completed = sm->wpa_state == WPA_COMPLETED;
    bool success = fault == NO_FAULT;
    bool pass = ptk_writes == 1 && gtk_writes == (unsigned)(fault != REJECT_PTK)
        && completed == success && successes == (unsigned)success
        && failures == (unsigned)!success && disarms == 1;
    printf("%s %s: PTK=%u GTK=%u complete=%u success=%u failure=%u timer-disarms=%u\n",
           pass ? "PASS" : "FAIL", name, ptk_writes, gtk_writes, (unsigned)completed,
           successes, failures, disarms);
    return pass;
}

int main(void)
{
    bool success = run_case("key writes succeed", NO_FAULT);
    bool ptk = run_case("pairwise key rejected", REJECT_PTK);
    bool gtk = run_case("group key rejected", REJECT_GTK);
    bool connect = run_connect_cases();
    return success && ptk && gtk && connect ? 0 : 1;
}
