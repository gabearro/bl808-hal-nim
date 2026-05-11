# BL808 WiFi NimFw Boot Probe — Design

**Date**: 2026-05-10
**Status**: Approved by user (whole-design sign-off), ready for implementation planning
**Builds on**:
- `src/bl808/wifi_fw.nim` reimpl at iter 254 (per memory `project_wifi_fw_reimpl.md`) — 637/637 symbols, 92.5% instruction coverage, never runtime-tested
- The existing `bl808WifiVendor` + `bl808WifiNimFw` build flag plumbing in `src/bl808/wifi.nim`

---

## 1. Goal and architecture

**Goal**: Empirically determine whether the Nim WiFi firmware reimplementation (`wifi_fw.nim` + companion `wifi_*.nim` modules, ~66K lines total) can boot on hardware. Specifically: does `bl_init()` (the Nim reimpl of the vendor MAC firmware init entry point, in `wifi_main.nim`) reach its `[WIFI-NIMFW] bl_init done` UART marker without crashing the M0 core?

**Pass**: marker emitted within 30 seconds of boot, followed by `[PASS] wifi nimfw init` from our wrapper and the `=== BL808 NimFw Boot Probe Complete ===` sentinel.

**Fail**: any of crash (JTAG snapshot will give us pc/sp/mepc/mcause/mtval), wifiInit non-zero return, banner-without-progress hang, or build failure (unresolved symbols).

This is iteration 1 of an open-ended bring-up project. It establishes either a working foothold (allowing iter 2 to add a scan probe) or a precise crash signal that tells us where in `wifi_main.nim` to start debugging.

**Architecture** — three small additions, no modifications to existing nimfw code:

1. **New file** `examples/m0_wifi_nimfw_boot_test.nim` (~40 lines). Mirrors `examples/m0_wifi_e2e_test.nim` console-setup shape (UART0 on pins 14/15, 230400 baud, XCLK from XTAL). Sequence:
   - `systemInit()`, `heapInit()`, `setupConsole()`
   - Send banner: `=== BL808 WiFi NimFw Boot Probe ===`
   - Call `wifiInit()` (which transitively calls into `bl_init` via the Nim reimpl)
   - On `wifiOk`: send `[PASS] wifi nimfw init`. On any other return: send `[FAIL] wifi nimfw init rc=<hex>`.
   - Send `=== BL808 NimFw Boot Probe Complete ===` sentinel
   - Loop forever (no scheduler)

2. **New catalog entry** `m0_wifi_nimfw_boot_test` in `tools/hardware_validation.json`. Build defines: `bl808WifiVendor=1`, `bl808WifiNimFw=1`. No SSID/password defines (we never call `wifiConnect`). `required` matches the three pass markers. `timeout: 30`. JTAG snapshot enabled (`jtag_snapshot` with the standard pc/sp/mepc/mcause/mtval/etc. set) so a crash gives us automatic forensics.

3. **No Makefile target**, no harness change. Invoke directly:

   ```bash
   .venv/bin/python tools/hw_validate.py --test m0_wifi_nimfw_boot_test \
     --uart-anchor-flash --uart-anchor-runtime-jtag \
     --openocd-sudo --ftdi-reset-sudo \
     --uart /dev/tty.usbserial-TGKWL2RS --uart-baud 230400
   ```

**Files NOT touched**: any `wifi_*.nim` module, any vendor C source, the smoke test binary, the smoke catalog entry, the PMF/SAE wrappers, `Makefile`, `tools/hw_e2e.py`.

---

## 2. Sequence, risks, outcomes

### Strict sequence

```
START at HEAD = fb22013 (SAE probe done; nimfw never runtime-tested)

1. Commit 1: examples/m0_wifi_nimfw_boot_test.nim
   → Verify build: make m0 FILE=examples/m0_wifi_nimfw_boot_test.nim \
       NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:bl808WifiNimFw' succeeds.
   → If link fails (undefined symbols in nimfw, codegen errors): file follow-up
     iteration to fix. Discard with `git checkout HEAD -- examples/m0_wifi_nimfw_boot_test.nim`,
     surface error tail. NEVER `git reset --hard`.

2. Commit 2: tools/hardware_validation.json catalog entry
   → Verify JSON parses (python -c "import json; json.load(open('tools/hardware_validation.json'))").
   → Verify pytest still 10/10 (.venv/bin/pytest tools/test_hw_e2e.py -v).
   → If pass: commit. If fail: discard with `git checkout HEAD -- tools/hardware_validation.json`.

3. Hardware run: hw_validate.py --test m0_wifi_nimfw_boot_test ...
   → Read UART log + JTAG snapshot
   → Bucket per outcome table
```

After each commit: `git status --short | grep '^ M'` shows 0 unstaged-modified files.

### Risks

- **Very high**: nimfw has 30K lines of code that has never been runtime-validated. Any single one of the 33+ already-fixed bugs (or remaining unfixed ones) could trigger a crash on first hardware run. The probability that `bl_init` runs cleanly first-try is realistically <50%.
- **Medium**: Build may not even link — undefined symbols where nimfw exports don't match what other compiled C objects expect. Common in large reimpl projects after long static-only audit phases.
- **Medium**: `wifiInit()` may hang in a polling loop waiting for hardware that the nimfw doesn't kick correctly (e.g., RF cal that doesn't complete, IPC handshake that never fires).
- **Low**: Console UART setup may interfere with the M0's expected console mapping in nimfw — but `wifi_main.nim` doesn't typically own the console UART, so this is unlikely.

### Discard policy

Per-commit failures: `git checkout HEAD -- <file>` to discard, surface the error, file a follow-up if the failure is non-trivial. **Never** `git reset --hard`.

Hardware-run failures DO NOT trigger code reverts. They trigger investigation per the outcome table below. The boot probe binary + catalog entry stay regardless of result.

### Outcomes

| UART / JTAG signal | Verdict | Next iteration |
|---|---|---|
| `[WIFI-NIMFW] bl_init done` + `[PASS] wifi nimfw init` + sentinel within 30s | ✅ **Boot probe passes** — nimfw runs | Iter 2: add `m0_wifi_nimfw_scan_hal_test`-equivalent probe |
| Banner emitted, then `[WIFI-NIMFW]` partial output, then silence within 30s timeout | nimfw hung mid-`bl_init`. JTAG snapshot's `pc` + nearest symbol via `objdump` tells us which Nim function is stuck | Iter to fix the stuck function |
| `[FAIL] wifi nimfw init rc=<hex>` + sentinel | `wifiInit()` returned a non-OK status. `wifi_main.nim` init path returned an error code | Iter to triage which substep returned the error (look at the wifi-init helpers) |
| No banner emitted; UART silent for 30s | Crash before `main()` reaches our banner. JTAG snapshot's `mepc`/`mcause`/`mtval` localizes the trap | Iter to fix pre-main fault (likely startup or static init issue) |
| Build fails at link time | nimfw has unresolved symbols or codegen error visible in build log | Iter to fix the link-level issue; do not run hw |
| Build fails at compile time | Nim or C compile error in the new test binary itself, not nimfw | Likely a typo in the test binary; fix and re-build |

### State at the end

```
HEAD = fb22013 + 2 new commits
fb22013  wifi: link --wrap=wpa3_build/parse_sae_msg
+ 1: Add m0_wifi_nimfw_boot_test.nim — minimal nimfw boot probe
+ 2: hw_validation: add m0_wifi_nimfw_boot_test catalog entry
```

Plus a hardware-run report. The "iteration done" condition is reaching one of the six outcome buckets — each has a clear next step.

### Stop conditions

- Each commit succeeds with verification.
- Hardware run produces one of the six bucketed outcomes (i.e., NOT "ambiguous, retry").
