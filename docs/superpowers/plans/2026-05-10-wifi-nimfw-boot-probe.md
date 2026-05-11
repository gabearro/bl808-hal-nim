# WiFi NimFw Boot Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal `m0_wifi_nimfw_boot_test` that builds the M0 firmware with `-d:bl808WifiNimFw` and calls `wifiInit()`, so we can observe whether the Nim WiFi firmware reimplementation actually boots `bl_init` on hardware.

**Architecture:** Two file additions — a ~50-line standalone test binary at `examples/m0_wifi_nimfw_boot_test.nim` (mirrors the console-setup shape of `examples/m0_wifi_e2e_test.nim`, calls only `wifiInit()`, emits PASS/FAIL UART markers, then loops forever) and a new catalog entry in `tools/hardware_validation.json` registering the binary with the standard JTAG snapshot defaults. No Makefile target, no harness change. Invoke directly via `hw_validate.py --test m0_wifi_nimfw_boot_test`.

**Tech Stack:** Nim 1.6+ bare-metal (`-d:bl808kernel -d:bl808WifiVendor -d:bl808WifiNimFw`), M0 (E907 RV32IMAFC), riscv32-unknown-elf toolchain, hw_validate.py harness.

**Spec:** `docs/superpowers/specs/2026-05-10-wifi-nimfw-boot-probe-design.md` (committed at `03c6b39`).

**Starting point:** `master` at `03c6b39` (SAE probe iteration done; `wifi_fw.nim` reimpl at iter 254 with full callgraph parity to vendor blob but never runtime-tested). Substrate at `b021e96`. PMF wrapper still active (commits `50e41c1..fb22013`); does not interfere with this iteration.

---

## Scope check

Single iteration, two commits, then a hardware run with six well-defined outcome buckets. No decomposition needed.

## File structure

| File | Status | Responsibility |
|------|--------|---------------|
| `examples/m0_wifi_nimfw_boot_test.nim` | **create** (~50 lines) | Standalone M0 test binary. Sets up UART0 console, prints banner, calls `wifiInit()`, emits PASS/FAIL marker based on return value, prints sentinel, loops forever. |
| `tools/hardware_validation.json` | modify (+~14 lines) | Add `m0_wifi_nimfw_boot_test` catalog entry. Smoke tier; `bl808WifiVendor=1` + `bl808WifiNimFw=1` defines (no SSID/password); `required` matches the three pass markers; 30 s timeout. Inherits `jtag_snapshot` from `defaults` (which already covers pc/sp/ra/mepc/mcause/mtval/mdw — verified at `tools/hardware_validation.json:7-17`). |

**Files NOT touched:**
- Any `wifi_*.nim` module under `src/bl808/` — we're empirically testing existing nimfw code, not modifying it
- Any vendor C source under `build/bl_iot_sdk_b773b3f/`
- Existing `examples/m0_wifi_*` test binaries (including `m0_wifi_hal_test.nim` and `m0_wifi_lwip_smoke.nim`)
- `Makefile`, `tools/hw_e2e.py`, any existing catalog entry
- The PMF wrapper in `src/bl808/wifi_vendor_support.c` (it's harmless at runtime; the boot probe doesn't call `wifiConnect` so the wrapper code path is dead)

**Key API references** (already exist; do not redefine):
- `wifiInit*(): WifiError` — `src/bl808/wifi.nim:474`. Calls `wifi_mgmr_init` then `wifi_mgmr_sta_enable`. Returns `wifiOk` (= 0) on success, `wifiFail` (= -1) on failure.
- `WifiError = enum wifiOk=0, wifiFail=-1` — `src/bl808/wifi.nim:81-83`.
- `console.sendLine`, `console.sendString`, `console.sendHex32` — methods on `Uart` from `bl808/uart`.
- `[WIFI-NIMFW] bl_init done` — already emitted by the existing `examples/m0_wifi_hal_test.nim` after `wifiInit()` under `when defined(bl808WifiNimFw):` (line 4 of that file). We emit the same marker from our boot probe so the catalog `required` matcher works identically.
- Standard JTAG snapshot — defined in `tools/hardware_validation.json:7-17` under `defaults.jtag_snapshot`. Catalog entries that omit their own `jtag_snapshot` inherit this default. The default already covers `poll`, `reg pc`, `reg sp`, `reg ra`, `reg mepc`, `reg mcause`, `reg mtval`, `mdw 0x40000000 16`, `mdw 0x2000e010 1` — sufficient for triaging crashes in `wifi_main.nim`.

**Build verification command** (used after Task 1):
```bash
make m0 FILE=examples/m0_wifi_nimfw_boot_test.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:bl808WifiNimFw'
```
Expected last line: `Output: build/m0_firmware.bin`

**Critical safety rule:** If a build fails, discard with `git checkout HEAD -- <file>`. **Never** use `git reset --hard`. Investigate the error; do not modify any vendor file or any `wifi_*.nim` module to make the build pass — those are part of the iter-254 codebase under separate audit.

---

## Task 1: Create the boot probe binary

**Files:**
- Create: `examples/m0_wifi_nimfw_boot_test.nim`

This task creates a minimal standalone M0 test binary that calls `wifiInit()` under nimfw and emits a clear PASS/FAIL UART marker. The build verification confirms that the nimfw modules link cleanly into the binary — if any nimfw symbol is unresolved, this is where the build fails.

- [ ] **Step 1: Create the binary file with full content**

Create `examples/m0_wifi_nimfw_boot_test.nim` with the following contents:

```nim
## M0 WiFi NimFw boot probe (Iter 2.A.3).
##
## Build with:
##   make m0 FILE=examples/m0_wifi_nimfw_boot_test.nim \
##     NIM="nim -d:bl808kernel -d:bl808WifiVendor -d:bl808WifiNimFw"
##
## Empirical probe: does the wifi_fw.nim reimpl's bl_init reach its
## "[WIFI-NIMFW] bl_init done" marker without crashing? Calls only
## wifiInit() (no scan, no connect, no AP, no PMF wrap exercise).
## Pass = wifiInit returns wifiOk and the sentinel is emitted.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc setupConsole() =
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  setupConsole()
  discard console.sendLine("")
  discard console.sendLine("=== BL808 WiFi NimFw Boot Probe ===")

  let rc = wifiInit()
  when defined(bl808WifiNimFw):
    discard console.sendLine("[WIFI-NIMFW] bl_init done")

  if rc == wifiOk:
    discard console.sendLine("[PASS] wifi nimfw init")
  else:
    discard console.sendString("[FAIL] wifi nimfw init rc=")
    console.sendHex32(cast[uint32](rc.int32))
    discard console.sendLine("")

  discard console.sendLine("=== BL808 NimFw Boot Probe Complete ===")
  while true:
    discard

main()
```

- [ ] **Step 2: Build to verify the nimfw modules link cleanly**

Run:
```bash
make m0 FILE=examples/m0_wifi_nimfw_boot_test.nim \
  NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:bl808WifiNimFw'
```

Expected: command succeeds (exit 0); the last line of output is `Output: build/m0_firmware.bin`.

If the build fails:
- Linker error `undefined reference to <symbol>`: nimfw is missing an exported symbol that something else in the build chain references. Capture the symbol name + the calling object file from the error message. **Do not fix this** by adding stubs — discard with `git checkout HEAD -- examples/m0_wifi_nimfw_boot_test.nim`, surface the error tail, and report `BLOCKED — nimfw link failure: undefined <symbol>`. The user will decide whether to file a follow-up iteration to fix the missing symbol(s).
- Nim compile error in the new test binary itself (e.g., typo in `setupConsole` or a missing import): fix the typo and re-run.
- C compile error in `wifi_fw.nim`'s emitted C: capture the error, discard, report `BLOCKED — nimfw codegen failure`. Same rationale as the linker error.
- Do **not** modify any file under `src/bl808/wifi_*.nim` or `build/bl_iot_sdk_b773b3f/` to make the build pass.

- [ ] **Step 3: Verify only the intended file was modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: zero lines of output (we only created a new file; no existing tracked files modified).

Run:
```bash
git status --short | grep '^??' | grep examples/m0_wifi_nimfw_boot_test
```

Expected: a single `?? examples/m0_wifi_nimfw_boot_test.nim` line.

- [ ] **Step 4: Commit**

```bash
git add examples/m0_wifi_nimfw_boot_test.nim
git commit -m "$(cat <<'EOF'
Add m0_wifi_nimfw_boot_test.nim — minimal nimfw boot probe

Iter 2.A.3 step 1/2. Standalone M0 test binary that calls only
wifiInit() under -d:bl808WifiNimFw and emits PASS/FAIL UART markers
based on the return value. No scan, no connect, no AP, no PMF
wrapper exercise. First empirical hardware test of the wifi_fw.nim
reimpl after 254 iterations of static/structural audit work.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Register the catalog entry

**Files:**
- Modify: `tools/hardware_validation.json`

This task registers the test binary with the hw_validate.py harness so we can run it via `--test m0_wifi_nimfw_boot_test`. Inherits the default JTAG snapshot (verified to cover pc/sp/ra/mepc/mcause/mtval/mdw).

- [ ] **Step 1: Add the catalog entry**

Open `tools/hardware_validation.json`. Find the existing `m0_wifi_lwip_smoke` entry — it's the last test in the `tests` array (the one whose `defines` includes `WifiSsid` env var, ending the file's `tests` block). The entry's closing `}` is followed by `]` and `}` that close the array and root object.

Insert a new entry **after** the `m0_wifi_lwip_smoke` entry's closing `}`. To do this:

1. Locate the existing last entry's terminator (the `}` before the `]` that closes the `tests` array).
2. Replace `}\n  ]` with `},\n    {NEW_ENTRY_HERE}\n  ]` so the new entry slots in as the last array element.

The new entry to add:

```json
    {
      "name": "m0_wifi_nimfw_boot_test",
      "tiers": ["smoke"],
      "build": [{
        "id": "kernel",
        "core": "bl808m0",
        "source": "examples/m0_wifi_nimfw_boot_test.nim",
        "flash": "m0",
        "defines": {
          "bl808WifiVendor": "1",
          "bl808WifiNimFw": "1"
        }
      }],
      "required": [
        "=== BL808 WiFi NimFw Boot Probe ===",
        "[WIFI-NIMFW] bl_init done",
        "[PASS] wifi nimfw init",
        "=== BL808 NimFw Boot Probe Complete ==="
      ],
      "timeout": 30
    }
```

Make sure:
- A comma is added after the previous entry's closing `}` (otherwise the JSON is invalid).
- No trailing comma after the new entry's closing `}` (it's now the last array element).
- Indentation matches surrounding entries (4-space at the entry level).
- No `jtag_snapshot` field — we deliberately inherit from `defaults` (line 7-17 of the same file) so a crash gives us the standard pc/sp/ra/mepc/mcause/mtval forensics automatically.

- [ ] **Step 2: Verify the catalog JSON parses and the new entry is registered**

Run:
```bash
python -c "import json; d = json.load(open('tools/hardware_validation.json')); names = [t['name'] for t in d['tests']]; assert 'm0_wifi_nimfw_boot_test' in names, names; print('OK,', len(names), 'tests')"
```

Expected: `OK, <N> tests` where `<N>` is one greater than before (the previous count after Iter 2.A.0 follow-up was 43; this should print `OK, 44 tests`).

If JSON parse fails:
- The error will identify a line/column. Common cause: missing comma after previous entry, extra trailing comma after new entry, mismatched braces.
- Discard with `git checkout HEAD -- tools/hardware_validation.json` and re-do Step 1 carefully.

- [ ] **Step 3: Verify pytest still passes (hw_validate harness self-tests)**

Run:
```bash
.venv/bin/pytest tools/test_hw_e2e.py -v 2>&1 | tail -3
```

Expected: `10 passed` (same baseline as before).

If any test fails: revert with `git checkout HEAD -- tools/hardware_validation.json` and report.

- [ ] **Step 4: Verify only the one file is modified**

Run:
```bash
git status --short | grep '^ M'
```

Expected: a single ` M tools/hardware_validation.json` line.

- [ ] **Step 5: Commit**

```bash
git add tools/hardware_validation.json
git commit -m "$(cat <<'EOF'
hw_validation: add m0_wifi_nimfw_boot_test catalog entry

Iter 2.A.3 step 2/2. Registers the boot probe binary with the
hw_validate.py harness. Smoke tier (no AP needed); 30 s timeout;
inherits the default jtag_snapshot so a crash gives us pc/sp/ra/
mepc/mcause/mtval automatically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Hardware run (post-implementation, no commit unless fixes needed)

After Tasks 1-2 are committed, run on hardware. If sudo is expired ("sudo: a password is required"), pause and ask the user to refresh: `! echo 'Myth-m0uth-3l3vat0r' | sudo -S -v`.

```bash
.venv/bin/python tools/hw_validate.py --test m0_wifi_nimfw_boot_test \
  --uart-anchor-flash --uart-anchor-runtime-jtag \
  --openocd-sudo --ftdi-reset-sudo \
  --uart /dev/tty.usbserial-TGKWL2RS --uart-baud 230400
```

Read the UART log and (if a JTAG snapshot fired) the OpenOCD output from:
```
build/hardware-validation/m0_wifi_nimfw_boot_test.primary.uart.log
build/hardware-validation/m0_wifi_nimfw_boot_test.m0.openocd.log
```

(Path may differ depending on `--work-dir`; check the output of `hw_validate.py` for the actual location it writes to.)

Bucket the outcome per the spec's outcome table:

| UART / JTAG signal | Verdict | Next iteration |
|---|---|---|
| `[WIFI-NIMFW] bl_init done` + `[PASS] wifi nimfw init` + sentinel within 30s | ✅ **Boot probe passes** — nimfw runs | Iter 2: add `m0_wifi_nimfw_scan_hal_test`-equivalent probe (probably already in catalog; just run it next) |
| Banner emitted, then partial `[WIFI-NIMFW]` output, then silence within 30s timeout | nimfw hung mid-`bl_init`. Use JTAG snapshot's `pc` value: `riscv64-unknown-elf-addr2line -e build/m0_firmware.elf <pc>` to find the source location | File iter to fix the stuck function |
| `[FAIL] wifi nimfw init rc=<hex>` + sentinel | `wifiInit()` returned non-OK. Log the rc value | File iter to triage which substep returned the error (look at `src/bl808/wifi_main.nim` and helpers) |
| No banner emitted; UART silent for 30s | Crash before `main()` reaches our banner. JTAG snapshot's `mepc`/`mcause`/`mtval` localizes the trap; use `addr2line` on `mepc` | File iter to fix pre-main fault (likely startup or static init issue) |
| Build fails at link time | nimfw has unresolved symbols visible in the build log | Iter to fix the link-level issue; do not run hw |
| Build fails at compile time | Nim or C compile error in the new test binary itself, not nimfw | Likely a typo; fix and re-build |

**Discard policy**: hardware-run failures DO NOT trigger code reverts. They trigger investigation per the table. The boot probe binary + catalog entry stay in the codebase regardless of the result — they're useful for any future nimfw work.

---

## Self-review

**Spec coverage:**
- Section 1 (goal, architecture): Tasks 1-2 implement the two architectural pieces (test binary + catalog entry). The "no Makefile target / no harness change" architectural decision is honored — neither task touches Makefile or `hw_e2e.py`. ✅
- Section 2 (sequence, risks, outcomes): Plan sequence matches spec exactly (2 commits + hw run). Hardware-run section uses the spec's exact 6-bucket outcome table. Discard policy explicit. ✅

**Placeholder scan:** No TBD/TODO. Every step has concrete code or commands. Failure paths show exact discard commands and explicit "do not modify nimfw or vendor" warnings. ✅

**Type consistency:**
- `wifiInit()` return type is `WifiError` (enum) per `wifi.nim:81-83`. Comparison `rc == wifiOk` matches.
- `cast[uint32](rc.int32)` for hex print: `wifiOk = 0`, `wifiFail = -1`. The `-1` value casts to `0xFFFFFFFF` as expected.
- `console.sendHex32` takes `uint32`; the cast satisfies this.
- `[WIFI-NIMFW] bl_init done` marker matches the same string emitted by `examples/m0_wifi_hal_test.nim` (verified earlier in spec exploration). Catalog `required` line matches verbatim. ✅

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-10-wifi-nimfw-boot-probe.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks, fast iteration without manual checkpoints.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

**Which approach?**
