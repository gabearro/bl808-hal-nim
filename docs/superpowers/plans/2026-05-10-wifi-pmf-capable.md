# WiFi PMF-Capable Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small linker `--wrap` interceptor on `wpa_set_bss` that adds the Management Frame Protection Capable bit to the BL808 supplicant's RSN IE, so the WPA3-Transition-mode AP "Frog" stops rejecting our association with `status_code 19`.

**Architecture:** No vendor-file modifications. We define `__wrap_wpa_set_bss` in `src/bl808/wifi_vendor_support.c` (file we already own); the linker `--wrap=wpa_set_bss` redirects every caller through us. Our wrapper calls `__real_wpa_set_bss` with `pmf_required=false` (vendor's existing memset path), then sets `gWpaSm.pmf_cfg.capable=true` and `gWpaSm.mgmt_group_cipher = WPA_CIPHER_AES_128_CMAC`, regenerates the RSN IE via the non-static `wpa_gen_wpa_ie`, and re-publishes it via `wpa_config_assoc_ie`. ~30 LOC of new C code, one new `passL` line.

**Tech Stack:** C (vendor supplicant glue), Nim 1.6+ build pragmas, GNU `ld --wrap` for symbol redirection, riscv32-unknown-elf toolchain. No new tests.

**Spec:** `docs/superpowers/specs/2026-05-10-wifi-pmf-capable-design.md` (committed at `40419f5`).

**Starting point:** `master` at `40419f5` (smoke-test iteration fully landed; spec on top). Substrate at `44e6f9d` is the operational baseline; the `m0_wifi_lwip_smoke` binary currently fails 0/3 at `auth` because the AP rejects our WPA2-only RSN IE.

---

## Scope check

Single iteration, two commits, two file edits, then a hardware run. No decomposition needed.

## File structure

| File | Status | Responsibility |
|------|--------|---------------|
| `src/bl808/wifi_vendor_support.c` | modify (+~50 lines at end) | Add `__wrap_wpa_set_bss`, forward declarations of vendor symbols, optional UART diagnostic. File already exists (~3000 lines); we append at the bottom. |
| `src/bl808/wifi.nim` | modify (+1 line) | Add `{.passL: "-Wl,--wrap=wpa_set_bss".}` inside the existing `when defined(bl808m0) and defined(bl808WifiVendor):` block. |

**Files NOT touched (substrate is intact):**
- `build/bl_iot_sdk_b773b3f/.../wpa.c`, `wpa_ie.c` — vendor sources untouched
- `examples/m0_wifi_lwip_smoke.nim` — smoke binary unchanged
- `tools/hardware_validation.json`, `tools/hw_e2e.py`, `Makefile` — harness unchanged
- All other source files

**Key API references** (already exist; do not redefine):
- `wpa_set_bss(u8 vif_idx, u8 sta_idx, char *macddr, char *bssid, u8 pairwise_cipher, u8 group_cipher, bool pmf_required, u8 mgmt_group_cipher)` — vendor at `wpa.c:2208`, declared in `wpa_i.h:179`
- `struct wpa_sm gWpaSm` — module-global at `wpa.c:47`, type defined in `wpa_i.h:44`
- `wpa_gen_wpa_ie(struct wpa_sm *sm, u8 *wpa_ie, size_t wpa_ie_len)` — non-static, declared in `wpa_ie.h:18`
- `wpa_config_assoc_ie(uint8_t vif_idx, u8 proto, u8 *assoc_buf, u32 assoc_wpa_ie_len)` — non-static, declared in `wpa_i.h:185`
- `wifi_pmf_config_t { bool capable; bool required; }` — in `supplicant_api.h:16`
- `WPA_CIPHER_AES_128_CMAC = (1 << 5) = 0x20` — supplicant-internal value at `defs.h:25`
- `bl_os_printf(...)` — vendor logger function (already used throughout `wifi_vendor_support.c`)

**Build verification command (used after every Task 1 / Task 2 step):**
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272'
```
Expected last line: `Output: build/m0_firmware.bin`

**Critical safety rule:** If a build fails, discard with `git checkout HEAD -- <file>`. **Never** use `git reset --hard`. Investigate the build error and re-attempt; do not bypass with workarounds.

---

## Task 1: Add the wrapper to wifi_vendor_support.c

**Files:**
- Modify: `src/bl808/wifi_vendor_support.c` (append at end)

This task adds the wrapper function plus the recommended UART diagnostic line. The wrapper is dead code at this point because the linker `--wrap` flag is added in Task 2 — so this task only verifies that the new code compiles cleanly against vendor headers. Compilation is the only test we can run; runtime behavior is verified at Task 2's build (linker resolution) and at the hardware run.

- [ ] **Step 1: Append the wrapper to the bottom of wifi_vendor_support.c**

Open `src/bl808/wifi_vendor_support.c`. Find the very last line of the file (which currently ends with `int wifi_netif_dhcp_stop(struct netif *netif) { (void)netif; return 0; }`). Append the following block immediately after the existing last line:

```c

/* =========================================================================
 * Iter 2.A.1: PMF-Capable wrapper.
 *
 * The bl808 vendor supplicant defaults to advertising NO PMF in its RSN IE.
 * WPA3-Transition-mode APs reject WPA2 clients that omit the MFPC bit with
 * status_code 19 (CIPHER_REJECTED_PER_POLICY). This wrapper interposes on
 * wpa_set_bss via -Wl,--wrap=wpa_set_bss: when the caller does NOT request
 * full PMF (the typical path), we let the real function run, then reach into
 * gWpaSm to set pmf_cfg.capable=true and mgmt_group_cipher=BIP-CMAC-128, and
 * regenerate + republish the assoc RSN IE so the next association request
 * carries the MFPC bit + group mgmt cipher selector.
 *
 * If a caller ever requests pmf_required=true, we pass through unchanged.
 * Receive-side BIP MIC validation is delegated to libwifi_fw.a once
 * bl_wifi_set_igtk_internal() installs the IGTK from 4WHS M3.
 * ========================================================================= */

#include "rsn_supp/wpa_i.h"  /* struct wpa_sm, wifi_pmf_config_t */

#define BL808_WPA_CIPHER_AES_128_CMAC ((u16)(1u << 5))  /* matches defs.h:25 */

extern struct wpa_sm gWpaSm;
extern int wpa_gen_wpa_ie(struct wpa_sm *sm, u8 *wpa_ie, size_t wpa_ie_len);
extern void wpa_config_assoc_ie(uint8_t vif_idx, u8 proto, u8 *assoc_buf,
                                u32 assoc_wpa_ie_len);
extern int __real_wpa_set_bss(u8 vif_idx, u8 sta_idx, char *macddr, char *bssid,
                              u8 pairwise_cipher, u8 group_cipher,
                              bool pmf_required, u8 mgmt_group_cipher);

int __wrap_wpa_set_bss(u8 vif_idx, u8 sta_idx, char *macddr, char *bssid,
                       u8 pairwise_cipher, u8 group_cipher,
                       bool pmf_required, u8 mgmt_group_cipher)
{
    if (pmf_required) {
        /* Caller already wants PMF; nothing to override. */
        return __real_wpa_set_bss(vif_idx, sta_idx, macddr, bssid,
                                  pairwise_cipher, group_cipher,
                                  pmf_required, mgmt_group_cipher);
    }

    int rc = __real_wpa_set_bss(vif_idx, sta_idx, macddr, bssid,
                                pairwise_cipher, group_cipher,
                                false, 0);
    if (rc < 0) {
        return rc;
    }

    gWpaSm.pmf_cfg.capable = true;
    gWpaSm.pmf_cfg.required = false;
    gWpaSm.mgmt_group_cipher = BL808_WPA_CIPHER_AES_128_CMAC;
    gWpaSm.assoc_wpa_ie_len = sizeof(gWpaSm.assoc_wpa_ie);

    int new_len = wpa_gen_wpa_ie(&gWpaSm, gWpaSm.assoc_wpa_ie,
                                 gWpaSm.assoc_wpa_ie_len);
    if (new_len < 0) {
        bl_os_printf("[PMF] wrapper: wpa_gen_wpa_ie failed rc=%d\r\n", new_len);
        return -1;
    }
    gWpaSm.assoc_wpa_ie_len = (uint16_t)new_len;
    wpa_config_assoc_ie(gWpaSm.vif_idx, gWpaSm.proto,
                        gWpaSm.assoc_wpa_ie, gWpaSm.assoc_wpa_ie_len);

    bl_os_printf("[PMF] wrapper: assoc_wpa_ie_len=%u byte0=0x%02x\r\n",
                 (unsigned)gWpaSm.assoc_wpa_ie_len,
                 gWpaSm.assoc_wpa_ie_len > 0 ? gWpaSm.assoc_wpa_ie[0] : 0);
    return 0;
}
```

- [ ] **Step 2: Build to verify it compiles cleanly**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- C error `'rsn_supp/wpa_i.h' file not found`: the include path is wrong. Verify `-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src` is in the passC list of `wifi.nim` (it is, at the existing supplicant include block). If still fails, the vendor source layout may have moved; do not "fix" by adding alternate paths — discard and report.
- C error on `gWpaSm.pmf_cfg.capable`: the field name in the vendor `wifi_pmf_config_t` may differ. Verify against `build/bl_iot_sdk_b773b3f/components/network/wifi/include/supplicant_api.h:16-20`. The field IS named `capable` per the spec; if vendor changed it, discard and re-investigate.
- C error on `BL808_WPA_CIPHER_AES_128_CMAC` redefinition: a vendor header transitively included `defs.h` which defines `WPA_CIPHER_AES_128_CMAC`. We avoid that by using a `BL808_` prefix on our local define (already done above). If the error mentions our prefixed name, that's a different bug — discard and investigate.
- Linker error `multiple definition of __wrap_wpa_set_bss`: Task 2's `--wrap` flag isn't yet added; this error means linker is interpreting `__wrap_` prefix prematurely. Should NOT happen at this task. If it does, discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c`.
- Do **not** modify any vendor file under `build/bl_iot_sdk_b773b3f/...` to make the build pass. Discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c` and report the error tail.

- [ ] **Step 3: Verify only the intended file was modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: a single ` M src/bl808/wifi_vendor_support.c` line. No other files modified.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/wifi_vendor_support.c
git commit -m "$(cat <<'EOF'
wifi_vendor_support: add __wrap_wpa_set_bss for PMF-Capable RSN IE

Iter 2.A.1 step 1/2. Defines a small linker-wrap interceptor on
wpa_set_bss that lets vendor logic run, then reaches into gWpaSm to
set pmf_cfg.capable=true and mgmt_group_cipher=BIP-CMAC-128, regenerates
the assoc RSN IE via wpa_gen_wpa_ie, and re-publishes via
wpa_config_assoc_ie. Pass-through path preserved when caller requests
pmf_required=true. Wrapper is dead code at this commit; the link flag
arrives in step 2/2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire the linker --wrap flag

**Files:**
- Modify: `src/bl808/wifi.nim` (add one `passL` line)

This task adds the `-Wl,--wrap=wpa_set_bss` linker flag that activates the wrapper from Task 1. After this task, every call to `wpa_set_bss` from vendor code will land in our `__wrap_wpa_set_bss` instead, and our wrapper calls vendor's original via `__real_wpa_set_bss`.

- [ ] **Step 1: Add the passL pragma**

Open `src/bl808/wifi.nim`. Find the existing `when defined(bl808m0) and defined(bl808WifiVendor):` block (it begins around line 116). Inside that block, find any of the existing `{.passC: "-Ibuild/bl_iot_sdk_b773b3f/...".}` lines.

Add the following line immediately after the `{.passC: "-Isrc/bl808".}` line (around line 165):

```nim
    {.passL: "-Wl,--wrap=wpa_set_bss".}
```

Indentation must match the surrounding pragmas (4 spaces inside the `when defined(bl808WifiVendor):` block — the existing `passC` lines show the exact indent to match).

- [ ] **Step 2: Build to verify the linker resolves both __real and __wrap**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- Linker error `undefined reference to __real_wpa_set_bss`: the `--wrap` flag isn't being picked up. Verify the `passL` line is inside the `when defined(bl808WifiVendor):` block (so it's emitted only when that flag is set, which our build command sets via `-d:bl808WifiVendor`). Verify the spelling: `-Wl,--wrap=wpa_set_bss` (no spaces around `=`).
- Linker error `multiple definition of wpa_set_bss`: the `--wrap` flag is correctly redirecting calls but vendor's definition is somehow being seen twice. Discard `src/bl808/wifi.nim` and re-do the edit; check for a duplicate passL.
- Linker error `__wrap_wpa_set_bss has different signature than expected`: the wrapper signature in Task 1 doesn't match vendor's. Compare against `build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa_i.h:179` exactly. Fix the wrapper signature in `wifi_vendor_support.c` and re-build.
- Do **not** modify vendor files. Discard with `git checkout HEAD -- src/bl808/wifi.nim` and report.

- [ ] **Step 3: Verify only the intended file was modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: a single ` M src/bl808/wifi.nim` line.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/wifi.nim
git commit -m "$(cat <<'EOF'
wifi: link --wrap=wpa_set_bss to enable PMF-Capable wrapper

Iter 2.A.1 step 2/2. Adds the passL flag that activates the
__wrap_wpa_set_bss interceptor from step 1. After this commit, every
vendor call to wpa_set_bss lands in our wrapper, which advertises MFPC
in the assoc RSN IE so WPA3-Transition-mode APs accept us.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Hardware run (post-implementation, no commit unless fixes needed)

After Tasks 1-2 are committed, run on hardware:

```bash
make hw-e2e-lwip-smoke \
  UART_PORT=/dev/tty.usbserial-TGKWL2RS \
  WIFI_SSID=Frog \
  WIFI_PASSWORD=6509171272
```

Expected outcomes (these are the only acceptable end-states):

1. **Full pass** — all 3 attempts reach `icmp:ok rtt_ms=…`. PMF wrapper works, AP accepts us, DHCP+ICMP run end-to-end. Iteration done.
2. **Partial pass** — at least 1 of 3 attempts reaches `icmp:ok`. PMF wrapper validated; intermittent issue tracked separately. Iteration done from implementation perspective.
3. **All fail at the same downstream phase** — e.g., `dhcp:fail reason=…` × 3 or `icmp:fail reason=…` × 3. PMF accepted association but a substrate bug surfaces past auth. **Iteration is complete** (PMF goal achieved); a separate fix iteration handles the new bug.
4. **All fail at auth** with `status_code 19` still — wrapper not effective. Triage:
   - Look for `[PMF] wrapper: assoc_wpa_ie_len=...` log line in UART output. If absent, wrapper isn't being called → linker `--wrap` not active → re-verify Task 2's passL is in the right when-block.
   - If present but `byte0` is not `0x30` (RSN IE element ID = 48 = 0x30), the regenerated IE is malformed → escalate to JTAG `mdw` of `gWpaSm.assoc_wpa_ie` to inspect.
   - If present and looks valid but AP still rejects with status_code 19 → AP requires MFPR (more aggressive bit). Single-line follow-up: change `gWpaSm.pmf_cfg.required = false` → `true` in the wrapper. Commit + re-run.
5. **All fail at auth** with a different status_code than 19 (e.g., 12, 18, 23) — different rejection cause. Capture the new code and bucket as a separate fix iteration.

**Discard policy**: hardware-run failures don't trigger reverts. They trigger investigation. The substrate is intact regardless of whether smoke succeeds; the worst case is "we found a downstream bug that needs a separate iteration."

---

## Self-review

**Spec coverage:**
- Section 1 (goal, architecture, trust boundary): Task 1 implements the wrapper exactly as architected (call __real with pmf_required=false, fix up gWpaSm, regen IE, republish). Pass-through path preserved at top of wrapper. ✅
- Section 2 (the wrapper file): Task 1 step 1 contains the full wrapper including all forward declarations, the `BL808_WPA_CIPHER_AES_128_CMAC` define, and the recommended UART diagnostic. ✅
- Section 3 (build wiring): Task 2 adds the `passL` line in the right place. ✅
- Section 4 (validation, sequence, risks): Hardware-run section covers all 5 outcomes from spec § 4 step 3, including the MFPR escalation path. ✅

**Placeholder scan:** No TBD/TODO. Every step has concrete code or concrete commands. The "discard and report" guidance in failure paths is explicit, not "handle errors". ✅

**Type consistency:**
- `__wrap_wpa_set_bss` and `__real_wpa_set_bss` use identical signatures, matching vendor's `wpa_i.h:179`.
- `gWpaSm.pmf_cfg.capable` field name matches `wifi_pmf_config_t` in `supplicant_api.h:16-20`.
- `gWpaSm.mgmt_group_cipher` is `u16` per `wpa_i.h:66`; we cast our value to `(u16)` via the macro.
- `gWpaSm.assoc_wpa_ie_len` and `gWpaSm.assoc_wpa_ie` types are consistent with vendor (uint16_t length, u8 array).
- `wpa_gen_wpa_ie` and `wpa_config_assoc_ie` signatures match `wpa_ie.h:18` and `wpa_i.h:185`. ✅

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-10-wifi-pmf-capable.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review (spec compliance, then code quality) between tasks, fast iteration without manual checkpoints between commits.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

**Which approach?**
