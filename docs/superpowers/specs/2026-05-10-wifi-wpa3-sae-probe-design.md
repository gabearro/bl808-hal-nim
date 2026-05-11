# BL808 Supplicant WPA3-SAE Probe — Design

**Date**: 2026-05-10
**Status**: Approved by user (3-section sign-off), ready for implementation planning
**Builds on**:
- `docs/superpowers/specs/2026-05-10-wifi-pmf-capable-design.md` — Iter 2.A.1 PMF wrapper (committed at HEAD `b021e96`)
- `docs/superpowers/specs/2026-05-10-wifi-lwip-smoke-test-design.md` — the smoke harness this iteration validates against

---

## 1. Goal, architecture, success criterion

**Goal**: Empirically test whether the bl808 MAC firmware blob (`libwifi_fw.a`) drives the WPA3-SAE auth handshake when `gWpaSm.key_mgmt = WPA_KEY_MGMT_SAE`. If it does, validate via `m0_wifi_lwip_smoke` reaching `icmp:ok` on at least 1 of 3 attempts. If it does not, fall back to AP reconfig with a clear filed signal (no SAE callbacks fired) of where the blob's limitation lies.

**Architecture** — three small additions on top of the existing Iter-2.A.1 wrapper machinery:

1. **Extend `__wrap_wpa_set_bss`** (already in `src/bl808/wifi_vendor_support.c`) to also set `gWpaSm.key_mgmt = WPA_KEY_MGMT_SAE` (BIT(10) = 0x400) after the `__real` call but before the IE regeneration. Vendor's IE builder at `wpa_ie.c:218` then emits AKM=SAE (`00-0F-AC:08`) and `wpa_ie.c:234` auto-forces MFPR via the OR with `key_mgmt == WPA_KEY_MGMT_SAE`. Our `pmf_cfg.required` value is therefore irrelevant for the IE bit (left as `true` from Iter 2.A.1; harmless).

2. **Add `__wrap_wpa3_build_sae_msg` + `__wrap_wpa3_parse_sae_msg`** with the supplicant_api.h signatures (5-arg build, 4-arg parse — the supplicant_api.h declarations match the actual `bl_wpa3.c` definitions; the `bl_wifi_driver.h` 3-arg variant is a stale parallel declaration). Each wrapper logs entry args via `bl_os_printf("[SAE] build/parse type=… ...")`, then forwards to `__real_*`, then logs return value. Trip-wire: if these fire on hardware, the blob is driving SAE.

3. **Add `passL` flags** in `src/bl808/wifi.nim`: `-Wl,--wrap=wpa3_build_sae_msg` and `-Wl,--wrap=wpa3_parse_sae_msg`, placed in the same passL cluster as the existing `--wrap=wpa_set_bss` line.

**Success criterion**: `m0_wifi_lwip_smoke` reaches `icmp:ok` on ≥1 of 3 attempts. A clean failure (e.g., "no `[SAE]` lines fire" or "`buf=(nil)` consistently") is also a meaningful outcome — it tells us where the blob stops cooperating, which is the input the AP-reconfig fallback needs.

---

## 2. Code surface

### File 1: `src/bl808/wifi_vendor_support.c`

**(a) Edit `__wrap_wpa_set_bss`**: immediately before the existing `wpa_gen_wpa_ie` call, insert one line:

```c
gWpaSm.key_mgmt = (1u << 10);  /* WPA_KEY_MGMT_SAE per defs.h:39 */
```

The existing `pmf_cfg.{capable=true, required=true}`, `mgmt_group_cipher=BIP-CMAC-128` from Iter 2.A.1 stay. SAE forces MFPR via the existing `||` in `wpa_ie.c:234` regardless of `pmf_cfg.required`.

**(b) Append two new wrappers** (after the existing `__wrap_wpa_set_bss`):

```c
extern uint8_t *__real_wpa3_build_sae_msg(uint8_t *bssid, uint8_t *mac,
                                          uint8_t *passphrase,
                                          uint32_t sae_msg_type,
                                          size_t *sae_msg_len);
extern int __real_wpa3_parse_sae_msg(uint8_t *buf, size_t len,
                                     uint32_t sae_msg_type, uint16_t status);

uint8_t *__wrap_wpa3_build_sae_msg(uint8_t *bssid, uint8_t *mac,
                                   uint8_t *passphrase,
                                   uint32_t sae_msg_type, size_t *len_out) {
    bl_os_printf("[SAE] build type=%u\r\n", (unsigned)sae_msg_type);
    uint8_t *buf = __real_wpa3_build_sae_msg(bssid, mac, passphrase,
                                             sae_msg_type, len_out);
    bl_os_printf("[SAE] build out len=%u buf=%p\r\n",
                 (unsigned)(len_out ? *len_out : 0), (void*)buf);
    return buf;
}

int __wrap_wpa3_parse_sae_msg(uint8_t *buf, size_t len,
                              uint32_t sae_msg_type, uint16_t status) {
    bl_os_printf("[SAE] parse type=%u len=%u status=%u\r\n",
                 (unsigned)sae_msg_type, (unsigned)len, (unsigned)status);
    int rc = __real_wpa3_parse_sae_msg(buf, len, sae_msg_type, status);
    bl_os_printf("[SAE] parse rc=%d\r\n", rc);
    return rc;
}
```

### File 2: `src/bl808/wifi.nim`

Append two `passL` lines next to the existing `--wrap=wpa_set_bss` (in the always-applied vendor block, NOT inside `bl808WifiWrapWaitUs`):

```nim
    {.passL: "-Wl,--wrap=wpa3_build_sae_msg".}
    {.passL: "-Wl,--wrap=wpa3_parse_sae_msg".}
```

### Files NOT touched

- Any vendor source under `build/bl_iot_sdk_b773b3f/` — the substrate stays intact
- `examples/m0_wifi_lwip_smoke.nim` — smoke binary unchanged
- `tools/hardware_validation.json`, `tools/hw_e2e.py`, `Makefile` — harness unchanged
- All other source files

---

## 3. Sequence, risks, outcomes

### Strict sequence

```
START at HEAD = b021e96 (Iter 2.A.1 PMF wrapper landed; AP "Frog" still rejecting status_code 19)

1. Commit 1: extend __wrap_wpa_set_bss with key_mgmt = SAE assignment
   → Verify build: make m0 FILE=examples/m0_wifi_lwip_smoke.nim NIM='...' succeeds.
     Wrapper still emits PSK AKM in the IE if no later linker flags are added — this
     is intentional dead-code intent at this commit. The actual key_mgmt change does
     take effect (it's runtime), but no SAE wrappers are linked yet.
   → If pass: commit. If fail: discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c`,
     surface error tail. NEVER `git reset --hard`.

2. Commit 2: append __wrap_wpa3_build_sae_msg + __wrap_wpa3_parse_sae_msg
   → Verify build: same make command succeeds. No linker effect yet (--wrap flags
     for these symbols not yet added).
   → If pass: commit. If fail: discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c`.

3. Commit 3: add `passL --wrap=wpa3_build_sae_msg` and `--wrap=wpa3_parse_sae_msg` to wifi.nim
   → Verify build. Watch binary text size: should grow ~200 bytes from the previous
     commit (the two wrappers + their printf calls).
   → If pass: commit. If fail: discard with `git checkout HEAD -- src/bl808/wifi.nim`.

4. Hardware run: make hw-e2e-lwip-smoke
   → Read marker stream + UART log
   → Look for [SAE] lines and bucket per outcome table below
```

After each commit: `git status --short | grep '^ M'` shows 0 unstaged-modified files.

### Risks

- **High**: Blob may not call `wpa_cbs->wpa3_build_sae_msg` at all when `key_mgmt=SAE` — it might still use Open Auth + PSK 4WHS. **Mitigation**: the `[SAE]` trip-wire tells us this immediately on the first hardware run.
- **Medium**: SAE H2E (hash-to-element) PWE derivation may fail on bare-metal RV32 — `bl_wpa3.c` uses `mbedtls` ECC primitives which we have compiled, but bare-metal stack constraints could trigger rare failures. **Detection**: `[SAE] build out buf=(nil)` consistently in UART log.
- **Medium**: 4WHS after SAE may need PMK derived from SAE rather than from passphrase. The supplicant should handle this internally (PMK is set by `wpa3_parse_sae_msg`'s success path), but vendor wiring is opaque.
- **Low**: PSK passphrase still passed through `wifi_mgmr_sta_connect` even though we want SAE — SAE uses passphrase as input to the PWE derivation, so this is fine. No API change needed.

### Outcomes

| UART signal | Verdict | Next step |
|---|---|---|
| `[SAE] build type=1 ... buf=0x…` AND smoke `icmp:ok` ≥1/3 | ✅ DONE | move to BLE iteration |
| `[SAE] build type=1` fires + `parse` fires + association still fails downstream | Partial — SAE drives, post-SAE breaks | file follow-up iteration to triage the post-SAE failure (likely 4WHS PMK install) |
| `[SAE] build type=1` fires + `buf=(nil)` consistently | SAE PWE derivation broken on this HW | file follow-up iteration to investigate bl_wpa3 PWE step |
| No `[SAE]` lines at all | Blob doesn't drive SAE on `key_mgmt=SAE` alone | iteration done; fall back to AP reconfig (Option 1 from original brainstorming); file memory note that the blob does not autonomously switch auth state machine on key_mgmt change |

### Discard policy

Per-task: `git checkout HEAD -- <file>` to discard working-tree edits. **Never** `git reset --hard`.

Hardware-run failures don't trigger reverts — they trigger investigation. Each outcome above has a clear next-step path.

### State at the end

```
HEAD = b021e96 + 3 new commits
b021e96  wifi_vendor_support: dump full RSN IE hex for PMF triage
+ 1: wifi_vendor_support: set key_mgmt=SAE in PMF wrapper
+ 2: wifi_vendor_support: add SAE callback wrappers for blob trip-wire
+ 3: wifi: link --wrap=wpa3_build/parse_sae_msg
```

Plus a hardware-run report. The iteration is "done" once the hardware run has produced one of the four outcomes above — three of them lead to follow-up iterations (with clear scope), one leads to BLE work.
