# BL808 Supplicant PMF-Capable Wrapper — Design

**Date**: 2026-05-10
**Status**: Approved by user (4-section sign-off), ready for implementation planning
**Builds on**:
- `docs/superpowers/specs/2026-05-10-wifi-lwip-smoke-test-design.md` — the smoke test that this iteration unblocks
- Substrate at HEAD `44e6f9d` (Iter 2.A.0 + smoke test fully landed)

---

## 1. Goal and architecture

**Goal**: Make `m0_wifi_lwip_smoke` reach `icmp:ok` (≥1/3 attempts) by adding **PMF Capable** (Management Frame Protection Capable, RSN capability bit 7) advertisement to the bl808 supplicant's RSN IE during association. The WPA3-Transition-mode AP "Frog" rejects our current connections with `status_code 19` (CIPHER_REJECTED_PER_POLICY) because the bl808 RSN IE omits the MFPC bit; this iteration fixes that.

**Architecture**: Linker `--wrap=wpa_set_bss` redirects all callers through a small wrapper we own in `src/bl808/wifi_vendor_support.c`. The wrapper:

1. Calls `__real_wpa_set_bss(... pmf_required=false ...)` — runs vendor logic verbatim, sets up state, generates a non-PMF RSN IE.
2. Reaches into `gWpaSm` (non-static, externally accessible — verified at `wpa.c:47`): sets `pmf_cfg.capable=true`, leaves `required=false`, sets `mgmt_group_cipher = WPA_CIPHER_AES_128_CMAC` (BIP-CMAC-128).
3. Calls `wpa_gen_wpa_ie` (non-static, declared in `wpa_ie.h:18`) to regenerate the assoc IE — now includes MFPC bit + group mgmt cipher selector.
4. Calls `wpa_config_assoc_ie` to publish the new IE to firmware. This happens before the connect msg propagates to the MAC, so the firmware uses the PMF-Capable IE for the association request.

**Pass-through path**: if a caller ever passes `pmf_required=true`, we call `__real` unchanged. Preserves any future use case wanting full PMF Required.

**Trust boundary**: Once 4WHS M3 delivers the IGTK, vendor `wpa.c:1054` already calls `bl_wifi_set_igtk_internal(...)` which hands the key to the MAC firmware blob (`libwifi_fw.a`). Incoming protected mgmt validation (BIP MIC verification) is the firmware's responsibility. We don't add validation code in this iteration; we trust the firmware blob to handle it transparently once the IGTK is installed. If hardware testing reveals the firmware doesn't validate, that's a separate iteration.

---

## 2. The wrapper file

**File modified**: `src/bl808/wifi_vendor_support.c` — append to the existing file (already part of `{.compile: "wifi_vendor_support.c".}` in `wifi.nim`).

**Forward declarations** (vendor symbols):
- `extern int __real_wpa_set_bss(...)` — provided by linker via `--wrap`. Same signature as vendor's `wpa.c:2208`.
- `extern struct wpa_sm gWpaSm` — module-global state at `wpa.c:47`.
- `extern int wpa_gen_wpa_ie(struct wpa_sm *sm, uint8_t *wpa_ie, size_t wpa_ie_len)` — declared in vendor `wpa_ie.h:18`.
- `extern void wpa_config_assoc_ie(uint8_t vif_idx, uint8_t proto, uint8_t *assoc_buf, uint32_t assoc_wpa_ie_len)` — declared in vendor `bl_wpa_main.c`.

**Constant**: `#define WPA_CIPHER_AES_128_CMAC_VAL (1 << 5)` — supplicant-internal value (0x20), matches vendor `defs.h:25`. We use a local define to avoid pulling in the vendor `defs.h` (which has a clashing macro name).

**Header inclusion**: To set `gWpaSm.pmf_cfg.capable` and `gWpaSm.mgmt_group_cipher`, we need `struct wpa_sm`'s layout. Two options:
- (a) `#include "rsn_supp/wpa_i.h"` — gets the full layout. Path is already on the C include search path because vendor C files compile against it.
- (b) Replicate just the `pmf_cfg` and `mgmt_group_cipher` field offsets via a stripped local struct.

**Decision**: Use (a). Vendor `wpa_i.h` is stable; if it ever changes, the build will fail loudly (struct field name mismatch), which is the right failure mode.

**Wrapper body** (~30 LOC). Pseudocode:

```c
int __wrap_wpa_set_bss(uint8_t vif_idx, uint8_t sta_idx, char *macddr, char *bssid,
                       uint8_t pairwise_cipher, uint8_t group_cipher,
                       bool pmf_required, uint8_t mgmt_group_cipher) {
    if (pmf_required) {
        return __real_wpa_set_bss(vif_idx, sta_idx, macddr, bssid,
                                  pairwise_cipher, group_cipher,
                                  pmf_required, mgmt_group_cipher);
    }
    int rc = __real_wpa_set_bss(vif_idx, sta_idx, macddr, bssid,
                                pairwise_cipher, group_cipher,
                                false, 0);
    if (rc < 0) return rc;
    gWpaSm.pmf_cfg.capable = true;
    gWpaSm.pmf_cfg.required = false;
    gWpaSm.mgmt_group_cipher = WPA_CIPHER_AES_128_CMAC_VAL;
    gWpaSm.assoc_wpa_ie_len = sizeof(gWpaSm.assoc_wpa_ie);
    int new_len = wpa_gen_wpa_ie(&gWpaSm, gWpaSm.assoc_wpa_ie, gWpaSm.assoc_wpa_ie_len);
    if (new_len < 0) return -1;
    gWpaSm.assoc_wpa_ie_len = new_len;
    wpa_config_assoc_ie(gWpaSm.vif_idx, gWpaSm.proto,
                        gWpaSm.assoc_wpa_ie, gWpaSm.assoc_wpa_ie_len);
    return 0;
}
```

**Recommended diagnostic** (for Section 4 Medium-risk mitigation): emit a one-line UART log under `bl808WifiVendor` after the IE regeneration:

```c
bl_os_printf("[PMF] wrapper: assoc_wpa_ie_len=%u byte0=0x%02x\r\n",
             (unsigned)gWpaSm.assoc_wpa_ie_len,
             gWpaSm.assoc_wpa_ie_len > 0 ? gWpaSm.assoc_wpa_ie[0] : 0);
```

Cheap (a few bytes, one print call), gives us immediate visibility on the hardware run that the regenerated IE landed in `gWpaSm` correctly. Land with Commit 1.

---

## 3. Build wiring

**File modified**: `src/bl808/wifi.nim`. Add a `passL` pragma inside the existing `when defined(bl808m0) and defined(bl808WifiVendor):` block (where the `passC` pragmas live around line 117):

```nim
{.passL: "-Wl,--wrap=wpa_set_bss".}
```

That's the only build-wiring change. Notes:

- `wifi_vendor_support.c` is already in the existing `{.compile: ...}` directive in the same when-block, so the wrapper builds automatically.
- The `-Wl,--wrap=<symbol>` flag is gcc/binutils standard; our `riscv32-unknown-elf-ld` supports it.
- Header include path for `wpa_i.h` is already set (vendor C files build against it via existing `passC` flags).

**No changes**: examples, tools, Makefile, `tools/hardware_validation.json`. The smoke test binary picks up the wrapper automatically because it builds with `-d:bl808WifiVendor`.

---

## 4. Validation, risks, sequence

### Strict sequence

```
START at HEAD = 44e6f9d (smoke test landed; AP "Frog" rejecting with status_code 19)

1. Commit 1: add __wrap_wpa_set_bss to wifi_vendor_support.c
   → Verify build: make m0 FILE=examples/m0_wifi_lwip_smoke.nim NIM='...'
     succeeds. Wrapper is dead code at this point (no --wrap link flag yet).
   → If pass: commit. If fail: discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c`,
     surface error tail. NEVER `git reset --hard`.

2. Commit 2: add `passL --wrap=wpa_set_bss` to wifi.nim
   → Verify build: same make command succeeds. Linker must resolve __real_wpa_set_bss
     and __wrap_wpa_set_bss correctly. If unresolved symbol → wrapper signature mismatches
     vendor's; fix the wrapper.
   → If pass: commit. If fail: discard with `git checkout HEAD -- src/bl808/wifi.nim`.

3. Hardware run: make hw-e2e-lwip-smoke (no commit unless fixes needed)
   → Read marker stream + UART log
   → Bucket the 3 attempts. Outcomes:
     a) ≥1/3 reaches icmp:ok → success, iteration done
     b) All 3 fail at auth with status_code 19 still → wrapper not reaching firmware;
        verify IE was actually regenerated (raw assoc_wpa_ie bytes via JTAG memdump or
        UART log)
     c) All 3 fail at auth with different status_code (e.g., 0/successful then later
        deauth) → MFPC accepted; new failure downstream (likely BIP RX validation
        missing in firmware) — separate fix iteration
     d) All 3 fail at dhcp/icmp → MFPC + association worked; substrate bug — separate fix
```

After each commit: `git status --short | grep '^ M'` shows 0 unstaged-modified files.

### Risks

- **Medium**: `wpa_gen_wpa_ie` regeneration may produce a slightly different IE than what vendor's in-function path produces — e.g., if `sm->key_mgmt` isn't fully populated by the time `__real_wpa_set_bss` returns. **Mitigation**: read state via JTAG `mdw` of `gWpaSm` after the call, or add a one-line UART log emitting `gWpaSm.assoc_wpa_ie_len` and the first 8 bytes for visual inspection.
- **Low**: Linker `--wrap` semantics differ across toolchains. Our `riscv32-unknown-elf-ld` is stock binutils; supports `--wrap` as documented.
- **Low**: WPA3-Transition AP might require MFPR (the more aggressive bit), not just MFPC. **Mitigation**: if outcome (b) occurs in step 3, escalate by changing wrapper to also set `pmf_cfg.required=true`. Single-line change for follow-up commit.
- **Low**: Vendor `wpa_i.h` private header changes between SDK versions. **Mitigation**: build will fail loudly (field-name compile error), not silently corrupt state. Acceptable failure mode.

### Discard policy

Per-task: `git checkout HEAD -- <file>` on failure. **Never** `git reset --hard`.

### State at the end

```
HEAD = 44e6f9d + 2 new commits
44e6f9d  hw_validation: add WifiChannel define to lwip-smoke catalog entry
+ 1: wifi_vendor_support: add __wrap_wpa_set_bss for PMF-Capable advertisement
+ 2: wifi: link --wrap=wpa_set_bss to enable PMF-Capable wrapper
```

Plus a hardware-run report. If smoke test passes, we mark this iteration done. If it surfaces a downstream issue (e.g., firmware BIP RX missing), we file a separate fix iteration.

### Stop conditions

- Each commit succeeds with verification.
- Hardware run is deterministic-or-explicable: either ≥1/3 reaches icmp:ok (good), or all 3 fail at the same explainable phase (filable bug for follow-up).
