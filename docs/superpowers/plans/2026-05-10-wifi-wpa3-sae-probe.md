# WiFi WPA3-SAE Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Empirically test whether the bl808 MAC firmware blob drives the WPA3-SAE auth handshake when `gWpaSm.key_mgmt = WPA_KEY_MGMT_SAE`. If yes, validate via `m0_wifi_lwip_smoke` reaching `icmp:ok`. If no, get a clean trip-wire signal so we can fall back to AP reconfig with confidence.

**Architecture:** Three small additions on top of Iter 2.A.1's `--wrap=wpa_set_bss` interceptor. (1) Extend the existing wrapper in `src/bl808/wifi_vendor_support.c` to flip `gWpaSm.key_mgmt = WPA_KEY_MGMT_SAE` (BIT(10)=0x400) before regenerating the IE. (2) Add two new wrappers `__wrap_wpa3_build_sae_msg` and `__wrap_wpa3_parse_sae_msg` that log entry/exit and forward to `__real_*`. (3) Add `--wrap` linker flags for both SAE callbacks in `wifi.nim`. ~30 LOC of new C, 2 lines of Nim.

**Tech Stack:** C (vendor supplicant glue), Nim 1.6+ build pragmas, GNU `ld --wrap` for symbol redirection, riscv32-unknown-elf toolchain.

**Spec:** `docs/superpowers/specs/2026-05-10-wifi-wpa3-sae-probe-design.md` (committed at `73233b3`).

**Starting point:** `master` at `73233b3` (PMF wrapper + IE-dump diagnostic landed at `b021e96`; spec on top). The `m0_wifi_lwip_smoke` binary currently builds with text=280424 bytes. AP "Frog" rejects with `status_code 19` regardless of MFPC/MFPR.

---

## Scope check

Single iteration, three commits, two file edits, then a hardware run with four well-defined outcome buckets. No decomposition needed.

## File structure

| File | Status | Responsibility |
|------|--------|---------------|
| `src/bl808/wifi_vendor_support.c` | modify (~+25 lines) | Insert `gWpaSm.key_mgmt = WPA_KEY_MGMT_SAE` line in existing wrapper. Append two new `__wrap_wpa3_*` callback interceptors that log entry/exit and forward. |
| `src/bl808/wifi.nim` | modify (+2 lines) | Add `{.passL: "-Wl,--wrap=wpa3_build_sae_msg".}` and `{.passL: "-Wl,--wrap=wpa3_parse_sae_msg".}` next to the existing `--wrap=wpa_set_bss` line. |

**Files NOT touched:**
- Any vendor source under `build/bl_iot_sdk_b773b3f/` — substrate stays intact
- `examples/m0_wifi_lwip_smoke.nim` — smoke binary unchanged
- `tools/hardware_validation.json`, `tools/hw_e2e.py`, `Makefile` — harness unchanged
- All other source files

**Key API references** (already exist; do not redefine):
- `gWpaSm.key_mgmt` — `u16` field per `wpa_i.h:65`. Set to one of the `WPA_KEY_MGMT_*` enum values from `defs.h`.
- `WPA_KEY_MGMT_SAE = BIT(10) = 0x400` per `defs.h:39`. We use the literal `(1u << 10)` to avoid pulling in a vendor header just for this constant (matching the existing `BL808_WPA_CIPHER_AES_128_CMAC` pattern).
- Vendor SAE function signatures (from `bl_wpa3.c:130, 209`):
  - `u8 *wpa3_build_sae_msg(u8 *bssid, u8 *mac, u8 *passphrase, u32 sae_msg_type, size_t *sae_msg_len)`
  - `int wpa3_parse_sae_msg(u8 *buf, size_t len, u32 sae_msg_type, u16 status)`
- `bl_os_printf(...)` — vendor logger already used in `wifi_vendor_support.c`

**Build verification command** (used after every Task 1 / 2 / 3 step):
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```
Expected last line: `Output: build/m0_firmware.bin`

**Critical safety rule:** If a build fails, discard with `git checkout HEAD -- <file>`. **Never** use `git reset --hard`. Investigate the error; do not bypass with workarounds.

---

## Task 1: Set key_mgmt = SAE in the existing PMF wrapper

**Files:**
- Modify: `src/bl808/wifi_vendor_support.c`

The existing `__wrap_wpa_set_bss` (lines roughly 3060-3092 of the file) sets up PMF state and regenerates the RSN IE. Add one line that flips `gWpaSm.key_mgmt` to SAE so the regenerated IE emits `AKM=SAE` (00-0F-AC:08) instead of PSK (00-0F-AC:02). The supplicant's IE builder at `wpa_ie.c:218` handles SAE, and `wpa_ie.c:234` automatically forces MFPR via `key_mgmt == WPA_KEY_MGMT_SAE` regardless of `pmf_cfg.required`.

After this commit, the wrapper sets `key_mgmt=SAE` at runtime — but no SAE callback wrappers are linked yet, so behavior change is limited to the IE bytes only. Build verifies the new line compiles and the IE regeneration still works.

- [ ] **Step 1: Insert the key_mgmt assignment**

Open `src/bl808/wifi_vendor_support.c`. Find the existing wrapper body. Locate the block that assigns to `gWpaSm`:

```c
    gWpaSm.pmf_cfg.capable = true;
    gWpaSm.pmf_cfg.required = true;
    gWpaSm.mgmt_group_cipher = BL808_WPA_CIPHER_AES_128_CMAC;
    gWpaSm.assoc_wpa_ie_len = sizeof(gWpaSm.assoc_wpa_ie);
```

Insert one line **immediately after** the `mgmt_group_cipher` assignment (so the `assoc_wpa_ie_len` assignment stays directly above the `wpa_gen_wpa_ie` call). The block becomes:

```c
    gWpaSm.pmf_cfg.capable = true;
    gWpaSm.pmf_cfg.required = true;
    gWpaSm.mgmt_group_cipher = BL808_WPA_CIPHER_AES_128_CMAC;
    gWpaSm.key_mgmt = (1u << 10);  /* WPA_KEY_MGMT_SAE per defs.h:39 */
    gWpaSm.assoc_wpa_ie_len = sizeof(gWpaSm.assoc_wpa_ie);
```

- [ ] **Step 2: Build to verify**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- C error on `gWpaSm.key_mgmt`: verify field name in `build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa_i.h` (it IS named `key_mgmt`, type `u16`, line 65). If the vendor changed it, discard and re-investigate.
- C error on the literal `(1u << 10)`: shouldn't happen; the cast is to `u16` via assignment. If the compiler complains about implicit narrowing, change to `(u16)(1u << 10)`.
- Do **not** modify any vendor file under `build/bl_iot_sdk_b773b3f/` to make the build pass. Discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c` and report the error tail.

- [ ] **Step 3: Verify only the intended file was modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: a single ` M src/bl808/wifi_vendor_support.c` line.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/wifi_vendor_support.c
git commit -m "$(cat <<'EOF'
wifi_vendor_support: set key_mgmt=SAE in PMF wrapper

Iter 2.A.2 step 1/3. After the PMF wrapper has run __real_wpa_set_bss
and set up pmf_cfg/mgmt_group_cipher, also flip gWpaSm.key_mgmt to
WPA_KEY_MGMT_SAE (BIT(10)=0x400). The supplicant's IE builder at
wpa_ie.c:218 then emits AKM=SAE (00-0F-AC:08) and wpa_ie.c:234
auto-forces MFPR regardless of pmf_cfg.required. SAE callback
wrappers + linker --wrap flags arrive in steps 2 and 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add SAE callback wrappers (`__wrap_wpa3_build_sae_msg`, `__wrap_wpa3_parse_sae_msg`)

**Files:**
- Modify: `src/bl808/wifi_vendor_support.c` (append after the existing `__wrap_wpa_set_bss`)

This task adds two trip-wire wrappers. They log entry args, forward to `__real_*`, log return values. No linker `--wrap` flag is added in this task, so the wrappers are dead code at this commit (the symbols `__wrap_wpa3_*` exist in the object file but aren't referenced by any caller). The build only verifies that the signatures match vendor's `bl_wpa3.c` exactly so the link will resolve cleanly when Task 3 adds the flags.

- [ ] **Step 1: Append the two wrappers to the bottom of `wifi_vendor_support.c`**

Open `src/bl808/wifi_vendor_support.c`. Find the very last line of the file (currently the closing `}` of `__wrap_wpa_set_bss`, after which there is no other content). Append the following block immediately after that closing brace:

```c

/* =========================================================================
 * Iter 2.A.2: SAE callback trip-wires.
 *
 * The vendor supplicant exposes wpa3_build_sae_msg and wpa3_parse_sae_msg
 * via the wpa_funcs callback table registered with the MAC firmware blob
 * (libwifi_fw.a). When key_mgmt=SAE is selected, the blob's auth state
 * machine is supposed to invoke these callbacks via the cb table to drive
 * the SAE Commit / SAE Confirm exchange. The unknown is whether the blob
 * actually does this, or whether it defaults to Open Auth + PSK 4WHS
 * regardless of key_mgmt.
 *
 * Linker --wrap=wpa3_build_sae_msg / --wrap=wpa3_parse_sae_msg redirects
 * the cb table entries through these trip-wires. If they fire, the blob
 * IS driving SAE. If they never fire, the blob isn't, and we fall back
 * to AP reconfig.
 *
 * Signatures match supplicant_api.h:197-198 / bl_wpa3.c:130,209 (NOT the
 * stale 3-arg variant in bl_wifi_driver.h:84).
 * ========================================================================= */

extern uint8_t *__real_wpa3_build_sae_msg(uint8_t *bssid, uint8_t *mac,
                                          uint8_t *passphrase,
                                          uint32_t sae_msg_type,
                                          size_t *sae_msg_len);
extern int __real_wpa3_parse_sae_msg(uint8_t *buf, size_t len,
                                     uint32_t sae_msg_type, uint16_t status);

uint8_t *__wrap_wpa3_build_sae_msg(uint8_t *bssid, uint8_t *mac,
                                   uint8_t *passphrase,
                                   uint32_t sae_msg_type, size_t *len_out)
{
    bl_os_printf("[SAE] build type=%u\r\n", (unsigned)sae_msg_type);
    uint8_t *buf = __real_wpa3_build_sae_msg(bssid, mac, passphrase,
                                             sae_msg_type, len_out);
    bl_os_printf("[SAE] build out len=%u buf=%p\r\n",
                 (unsigned)(len_out ? *len_out : 0), (void *)buf);
    return buf;
}

int __wrap_wpa3_parse_sae_msg(uint8_t *buf, size_t len,
                              uint32_t sae_msg_type, uint16_t status)
{
    bl_os_printf("[SAE] parse type=%u len=%u status=%u\r\n",
                 (unsigned)sae_msg_type, (unsigned)len, (unsigned)status);
    int rc = __real_wpa3_parse_sae_msg(buf, len, sae_msg_type, status);
    bl_os_printf("[SAE] parse rc=%d\r\n", rc);
    return rc;
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`. Binary text size should grow only marginally (the wrappers are present in the object file but not referenced; gcc may eliminate them if `-fdata-sections -ffunction-sections` + `--gc-sections` are in play, leaving size unchanged. Either is fine for this commit.)

If the build fails:
- C error `unknown type name 'uint8_t'`: should not happen, `<stdint.h>` is included at the top of the file.
- C error `unknown type name 'size_t'`: should not happen, `<stddef.h>` is included.
- Linker error `multiple definition of __wrap_wpa3_build_sae_msg`: should not happen at this commit (no `--wrap` flag yet). If it does, discard and investigate.
- Discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c` and report.

- [ ] **Step 3: Verify only the intended file was modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: a single ` M src/bl808/wifi_vendor_support.c` line.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/wifi_vendor_support.c
git commit -m "$(cat <<'EOF'
wifi_vendor_support: add SAE callback wrappers for blob trip-wire

Iter 2.A.2 step 2/3. Defines __wrap_wpa3_build_sae_msg and
__wrap_wpa3_parse_sae_msg with the supplicant_api.h signatures (5-arg
build, 4-arg parse — matching bl_wpa3.c definitions). Each wrapper
logs entry args, forwards to __real_*, then logs return value. With
the linker --wrap flags from step 3, these become trip-wires that
prove (or disprove) whether the MAC firmware blob actually drives
SAE when gWpaSm.key_mgmt is set to SAE.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the linker --wrap flags

**Files:**
- Modify: `src/bl808/wifi.nim` (add 2 `passL` lines)

This task adds the `-Wl,--wrap=wpa3_build_sae_msg` and `-Wl,--wrap=wpa3_parse_sae_msg` linker flags that activate the trip-wires from Task 2. After this task, the `wpa_funcs` callback table that vendor `bl_wpa_main.c:327-328` registers with the MAC firmware will resolve `wpa3_build_sae_msg` to our `__wrap_*` symbols at link time. Whenever the firmware invokes these callbacks via the registered pointer, our trip-wires fire.

- [ ] **Step 1: Add the two passL pragmas**

Open `src/bl808/wifi.nim`. Find the existing `--wrap=wpa_set_bss` line at line 284 (or wherever it currently is — `grep -n '--wrap=wpa_set_bss' src/bl808/wifi.nim` finds it). The surrounding context is:

```nim
    {.passL: "-Lsrc/bl808".}
    {.passL: "-Wl,--wrap=wpa_set_bss".}
    when defined(bl808WifiWrapWaitUs):
```

Insert two new `passL` lines immediately **after** the `--wrap=wpa_set_bss` line so the block becomes:

```nim
    {.passL: "-Lsrc/bl808".}
    {.passL: "-Wl,--wrap=wpa_set_bss".}
    {.passL: "-Wl,--wrap=wpa3_build_sae_msg".}
    {.passL: "-Wl,--wrap=wpa3_parse_sae_msg".}
    when defined(bl808WifiWrapWaitUs):
```

Indentation must match the existing `--wrap=wpa_set_bss` line exactly (4 spaces). Both new lines must be at the always-applied vendor block level — NOT inside `when defined(bl808WifiWrapWaitUs):` or any deeper guard.

- [ ] **Step 2: Build to verify the wraps link**

Run:
```bash
make m0 FILE=examples/m0_wifi_lwip_smoke.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`. Binary text size should grow ~200 bytes from the previous commit (the two wrappers + their printf calls are now referenced).

If the build fails:
- Linker error `undefined reference to __real_wpa3_build_sae_msg` or `__real_wpa3_parse_sae_msg`: the `--wrap` flag isn't being picked up. Verify both `passL` lines are inside the `when defined(bl808m0): when defined(bl808WifiVendor):` block (which our build command activates via `-d:bl808WifiVendor`). Verify spelling: `-Wl,--wrap=wpa3_build_sae_msg` (no spaces around `=`).
- Linker error `__wrap_wpa3_build_sae_msg has different signature than expected`: the wrapper signature in `wifi_vendor_support.c` doesn't match vendor's. Verify against `build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/bl_supplicant/bl_wpa3.c:130, 209`. Fix the wrapper in Task 2 (commit) and re-build.
- Discard with `git checkout HEAD -- src/bl808/wifi.nim` and report.

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
wifi: link --wrap=wpa3_build/parse_sae_msg

Iter 2.A.2 step 3/3. Activates the SAE callback trip-wires from
step 2. After this commit, every blob invocation of the registered
wpa_funcs.wpa3_build_sae_msg / wpa3_parse_sae_msg callback resolves
to our __wrap_* logging interceptors at link time. Hardware run will
reveal whether the blob drives SAE or not.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Hardware run (post-implementation, no commit unless fixes needed)

After Tasks 1-3 are committed, run on hardware:

```bash
make hw-e2e-lwip-smoke \
  UART_PORT=/dev/tty.usbserial-TGKWL2RS \
  WIFI_SSID=Frog \
  WIFI_PASSWORD=<wifi-password>
```

Read the marker stream + `[SAE]` and `[PMF]` log lines from:
```
build/hw-e2e/hw-validate-work/logs/m0_wifi_lwip_smoke.primary.uart.log
```

Bucket the outcome per the spec's outcome table:

| UART signal | Verdict | Next step |
|---|---|---|
| `[SAE] build type=…` AND `[SAE] parse type=…` AND smoke `icmp:ok` ≥1/3 | ✅ DONE | Move to BLE iteration |
| `[SAE] build type=…` fires + `[SAE] parse type=…` fires + association still fails downstream (no `dhcp:ok`) | Partial — SAE drives, post-SAE breaks | File follow-up to triage post-SAE failure (likely 4WHS PMK install path) |
| `[SAE] build type=…` fires + every `[SAE] build out buf=(nil)` | SAE PWE derivation broken on this hardware | File follow-up to investigate `bl_wpa3.c` PWE step on bare-metal RV32 |
| No `[SAE]` lines at all in any of the 3 attempts | Blob doesn't drive SAE on `key_mgmt=SAE` alone | **Iteration done** — fall back to AP reconfig (Option 1 from original brainstorming). Update `project_wifi_ap_deauth.md` memory with the verdict. |

**Discard policy**: hardware-run failures don't trigger reverts. They trigger investigation per the table. The PMF wrapper + SAE trip-wire stay in the codebase regardless of outcome — they're useful diagnostics for any future supplicant work.

---

## Self-review

**Spec coverage:**
- Section 1 (goal, architecture, success criterion): Tasks 1-3 implement the three architectural pieces (key_mgmt assignment, callback wrappers, linker flags) verbatim. Hardware-run section uses the spec's exact success criterion (≥1/3 icmp:ok). ✅
- Section 2 (code surface): Task 1 inserts the key_mgmt line in the right place (after mgmt_group_cipher, before assoc_wpa_ie_len so the IE-buffer-capacity assignment is immediately followed by the `wpa_gen_wpa_ie` call). Task 2 wrappers match the supplicant_api.h signatures. Task 3 places passL lines in the always-applied vendor block (NOT inside any deeper guard — explicit warning in Step 1). ✅
- Section 3 (sequence, risks, outcomes): Plan sequence is identical (3 commits). Hardware-run section uses the spec's exact outcome table. ✅

**Placeholder scan:** No TBD/TODO. Every step has concrete code or commands. Failure paths show exact discard commands and explicit "do not modify vendor files" warnings. ✅

**Type consistency:**
- `__wrap_wpa3_build_sae_msg` signature matches `__real_wpa3_build_sae_msg` extern, matches `bl_wpa3.c:130` definition (5 args: `uint8_t *bssid, uint8_t *mac, uint8_t *passphrase, uint32_t sae_msg_type, size_t *sae_msg_len`).
- `__wrap_wpa3_parse_sae_msg` signature matches `__real_wpa3_parse_sae_msg` extern, matches `bl_wpa3.c:209` definition (4 args: `uint8_t *buf, size_t len, uint32_t sae_msg_type, uint16_t status`).
- `gWpaSm.key_mgmt` field is `u16` per `wpa_i.h:65`. The literal `(1u << 10)` is `unsigned int` = 0x400, fits in `u16`, no warning expected. ✅

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-10-wifi-wpa3-sae-probe.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, fast iteration without manual checkpoints.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

**Which approach?**
