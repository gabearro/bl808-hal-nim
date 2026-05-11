# JTAG bisection for bare-metal boot loops

Methodology used to find the root cause of the WiFi NimFw boot loop
(iter 259 — see `~/.claude/projects/.../memory/project_wifi_fw_nimmain_recursion.md`).
Applies whenever an M0/D0 binary appears to reset over and over (banner reprints,
no FAULT line) and you need to find which exact call doesn't return.

## Setup

Two pieces:

1. **FTDI helpers** (already built under `build/`):
   - `build/ftdi_reset` — re-init the FTDI adapter so JTAG comes back after a hang.
   - `build/ftdi_srst_pulse` — pulse target nSRST so the M0 starts from POR.
2. **OpenOCD** with the BL808 configs already in the repo:
   - `pine64jtag.cfg` (adapter) + `tgt_e907_v2.cfg` (M0 target).
   - Patched OpenOCD at `../openocd-had/src/openocd` (also supports HAD for the LP).

A bisection session is just a single `openocd -c …` invocation per probe.

## Single-shot probe template

```sh
# 1. Make sure nothing is holding the adapter
sudo pkill -f openocd 2>/dev/null; sleep 1

# 2. Reset the board + the FTDI adapter
sudo -n build/ftdi_srst_pulse 0x0403 0x6014 >/dev/null 2>&1; sleep 1
sudo -n build/ftdi_reset      0x0403 0x6014 >/dev/null 2>&1; sleep 1

# 3. Run the actual probe — `reset halt` puts M0 at the reset vector,
#    set up to 3 HW breakpoints (E907 has 3 trigger slots), resume,
#    sleep long enough that a healthy boot would hit the BP, halt,
#    snapshot key registers, exit cleanly.
sudo -n ../openocd-had/src/openocd \
  -f pine64jtag.cfg -f tgt_e907_v2.cfg \
  -c "init" \
  -c "reset halt" \
  -c "bp 0xADDR_1 2 hw" \
  -c "bp 0xADDR_2 2 hw" \
  -c "bp 0xADDR_3 2 hw" \
  -c "resume" \
  -c "sleep 12000" \
  -c "halt" \
  -c "reg pc" \
  -c "reg sp" \
  -c "reg ra" \
  -c "shutdown" 2>&1 | tail -10
```

Output tells you:

- `pc == ADDR_N` → that breakpoint fired; M0 reached that code path. The other BPs
  may or may not have fired before — the snapshot is only the most recent halt.
- `pc != any ADDR_N` → none of the BPs fired in the sleep window. The M0 is
  somewhere unexpected. Check `sp`:
  - If `sp` is far below `_sstack` → stack overflow / boot-loop with corrupt frame.
  - If `pc` lands in `rawDelay` / `delayMtimeUs` repeatedly → a deeper call is stuck
    in a busy-wait while the larger flow is corrupt.

Single-BP runs are the cleanest: set one BP, run, see if it hits. Multi-BP runs
are useful for "did we get past A but not past B" questions, but remember that
once a BP fires, `sleep` does not auto-resume — M0 stays halted at that BP
until the next `resume` command.

## Bisection workflow

Pick addresses from `objdump -d` of the failing binary at call sites of interest:

```sh
riscv64-unknown-elf-objdump -d build/hw-validation/bin/<test>/kernel.elf \
  | awk '/<bl808WifiVendorFwStart/{p=1} p; p && /^[0-9a-f]+ </ && c++ > 0 {exit}'
```

For each `jal <subsystem_init>` instruction, both the call-site address (BP fires
before the jal) and call-site+4 (BP fires when the callee returns) are useful:

| BP fired | Conclusion |
|----------|-----------|
| At call site | Made it to here; sp at this point tells you stack health |
| At call site + 4 | Callee returned cleanly |
| Neither | Callee didn't return; bisect inside it next |

When the granularity drops to a single function:
1. Disassemble the function and pick a BP at its epilogue (typically the
   `lw ra, X(sp)` / `addi sp, sp, frame_size` / `ret` block).
2. If the epilogue BP fires, the body completed; the next bug is in the caller.
3. If the epilogue BP doesn't fire, set BPs at each internal jal in turn.

## What the NimFw boot-loop looked like

- 240+ banner reprints, mostly with no FAULT line (one in many iterations
  produced a fault with `mepc=tval=0xA5C33C5A`, the stack guard sentinel).
- `reg pc` post-test landed in `delayMtimeUs` / `rawDelay`.
- `reg sp` was always far below `_sstack` (e.g. `0x62026760` vs `_sstack = 0x62027000`).
- BPs along the wifi init chain: `setupBlOps`, `setupHosal`, `rf_init`,
  `ApplyHighPowerProfile`, `mpif_clk_init` all returned (each BP at call+4 fired
  with healthy `sp` ≈ `0x6202fef0`). `sysctrl_init`'s post-return BP didn't fire.
- Disassembling `sysctrl_init`: it calls `wifi_fw_runtime_init`. Disassembling
  that: it emits `NimMain()`. Disassembling `NimMain`:
  `addi sp,-16; sw ra; jal PreMain; jal main` — never returns.

Fix: remove the `NimMain()` emit. `_start` in this repo jumps straight to
`main()`, so calling NimMain (or NimMainModule, which is what NimMain wraps)
from inside main's call chain causes recursive re-entry into main.

## Gotchas

- **JTAG falls over while the board boot-loops.** The trick is to power-cycle via
  `ftdi_srst_pulse` + `ftdi_reset` immediately before `openocd init; reset halt`.
  Without `reset halt`, `init` often fails with `dtmcontrol is 0`.
- **`reg pc` from a halt mid-loop is not deterministic.** Use breakpoints, not bare
  halts, when you want to learn anything about the program flow.
- **`ra` after a BP hit at function entry** is the call-site+4 of whoever jal'd the
  function. If it doesn't match any expected call site, you may be looking at the
  wrong instance (e.g. the function being called from an unrelated callback) or
  at a tail-called function that inherited its caller's `ra`.
- **3-trigger limit on E907.** Past 3 HW BPs OpenOCD silently drops the rest.
- **Marker-byte tracing is unreliable when PHY is talking to UART.** PHY's printf
  doesn't poll for FIFO space, so trace bytes from your code interleave with PHY
  output. Use JTAG for ordering questions.
