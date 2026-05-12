# Vendor CKLink DebugServer Notes

Status: extracted from the local vendor binaries and configs on April 9, 2026.

This note documents what the Bouffalo/T-Head CKLink stack is doing for RISC-V targets, with emphasis on BL808 LP / E902.

It is based on static inspection of:

- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/cklink/libTarget.so`
- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/cklink/links/CK-Link/libCklink.so`
- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/cklink/libScripts.so`
- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/cklink/tdescriptions/riscv/riscv-e902-tdesc.xml`

Methods used:

- `nm -D`
- `strings -a`
- `llvm-objdump -d`

This is not a runtime trace. Anything marked "inference" is inferred from symbols, strings, and disassembly.

## Short answer

The vendor stack is not "just a target cfg".

For RISC-V targets, the normal attach path uses RVDM, not raw HAD. The missing behavior appears to live in compiled code across two layers:

- probe-side CKLink transport and probe configuration in `libCklink.so`
- target-side DTM/DM detection, recovery, and CPU selection in `libTarget.so`

That means BL808 LP support is probably possible, but not by Tcl alone.

## Bundle layout

### `libCklink.so`

Role: probe transport and CKLink-specific control.

Relevant exported symbols:

- `ice_jtag_operator`
- `link_jtag_execute`
- `link_write_tms`
- `link_config`
- `link_register_read`
- `link_register_write`
- `ice_set_hadver`
- `ice_set_hadcditype`
- `ice_target_reset_asyn_debug`

Relevant strings:

- `ICE_REG_CPU_SEL`
- `Write TMS, nbit: %d, value: 0x:%x`
- `cJtag 2-wire`

### `libTarget.so`

Role: target architecture and debug attach logic.

Relevant exported symbols:

- `riscv_jtag_port_detect`
- `riscv_dm_detect`
- `riscv_core_debug_connect`
- `get_riscv_low_target_rvdm`
- `get_riscv_low_target_ckhad`
- `riscv013_cpu_select`
- `riscv013_check_debug`
- `dm_op_dtm_abits_check`
- `dm011_op_dtm_abits_check`
- `dtm_op_dtm_reg_read`
- `dtm_op_dtm_reg_write`

Relevant strings:

- `RVDM`
- `CKHAD`
- `Read DTMCS get 0x%x.`
- `Get unsupported abits %d from dtmcs 0x%x.`
- `As DTMCS.dmistat is not 0(No error), write DTMCS.dmihardreset with 1.`
- `Read DMSTATUS get 0x%x, dm version is %d.`
- `Write hasel, hartselhi, hartsello, dmactive all fileds in DMCONTROL with 1.`

### `libScripts.so`

Role: script parser for GPIO/JTAG operations.

Relevant exported symbols:

- `JtagScr`
- `GpioScr`

Relevant strings:

- `jtag5`
- `cjtag2`
- `Execute THEAD_JTAG Script.`
- `Set CDI JTAG(5-wires)`

No BL808 LP-specific public script file is shipped in the local bundle.

### Target descriptions

The vendor bundle includes E902 register descriptions:

- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/cklink/tdescriptions/riscv/riscv-e902-tdesc.xml`

That XML models:

- 16 integer GPRs (`x0..x15`)
- `pc` at regnum `32`
- debug CSRs including `dcsr` and `dpc`

So the vendor stack definitely has first-class E902 support.

## Public configs shipped by Bouffalo

The bundled OpenOCD configs only cover BL602 and BL702:

- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/openocd/tgt_602.cfg`
- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/tools/bflb_tools/bouffalo_flash_cube/utils/openocd/tgt_702.cfg`

There is no public BL808 LP OpenOCD target config in the vendor bundle.

The SDK README also says:

- `/Users/gabriel/Documents/nimlang/bl808-sdk-ref/README.md`

and only advertises CKLink debug support for BL808.

## What the vendor stack does

## 1. Probe-side transport

Confirmed from `libCklink.so`:

- `ice_jtag_operator` sends and receives CKLink USB command packets.
- `link_jtag_execute` builds a packet with command byte `0x68` and terminator `0x16`.
- `link_write_tms` builds a packet with command byte `0x69` and terminator `0x16`.

So CKLink is not exposing raw USB JTAG bit-banging directly. There is a proprietary probe command layer on top of USB.

Confirmed from disassembly:

- `ice_set_hadver` reads and rewrites an internal probe self-register at index `0x8000`, updating bits `31:28`.
- `ice_set_hadcditype` reads and rewrites an internal probe self-register at index `0x0000`, updating bits `27:24`.

Inference:

- `hadver` and `hadcditype` are probe-side mode selectors.
- `ICE_REG_CPU_SEL` is likely the probe register used when the probe needs to select among CPUs or chains.

## 2. JTAG/CDI port detection

The first major attach stage is `riscv_jtag_port_detect`.

Confirmed from disassembly, it tries several `link_config` / `set_cdi_for_013` combinations before attempting the first DTM register read.

Observed attempts:

1. `link_config(3, 2)` then `link_config(0x18, 0)` then `set_cdi_for_013(2)` then read DTM register `1`
2. `link_config(5, 6)` then `link_config(3, 1)` then `set_cdi_for_013(1)` then read DTM register `1`
3. `link_config(5, 6)` then `link_config(3, 0)` then `set_cdi_for_013(0)` then read DTM register `1`

These modes are selected based on a target option field at offset `0x2c` in the vendor target state.

The exact meaning of the `link_config` opcodes is not public in this bundle.

Inference:

- One of these combinations is the vendor's 5-wire JTAG mode.
- One is a 2-wire/cJTAG/CDI variant.
- One is probably the default or auto path.

The important point is that CKLink does not assume a single fixed attach mode. It probes multiple port-mode configurations in code.

Follow-up disassembly resolves two more details:

- `set_cdi_for_013(x)` only writes a host-side global used by the vendor DTM
  access helpers; it is not target MMIO and does not itself emit JTAG.
- `link_config(0x18, 0)` emits this probe operation sequence:
  `link_write_escape(10)`, `link_write_tms(0xffff, 24)`,
  `link_write_escape(7)`, `link_write_tms(0x0c, 4)`,
  `link_write_tms(0x08, 4)`, `link_write_tms(0x00, 4)`.

Running that exact sequence through the FTDI helper after moving Ox64 J6 to GPIO
function 25 did not expose LP RVDM. OpenOCD saw shifted-looking scan values
(`idcode=0x06fa00fa`, auto TAPs `0x037d007d`/`0xffff807d`) and then
`Unsupported DTM version: 15`. That suggests CKLink's port-mode sequence is not
reproducible by only clocking the visible TMS/escape operations before starting a
normal 5-wire FTDI/OpenOCD session.

## 3. DTM detection and recovery

The next stage is `riscv_dm_detect`.

Confirmed sequence:

1. Clear internal state and set DMI busy adjustment timing.
2. Read DTM register `1` using `dtm_op_dtm_reg_read`.
3. Treat that value as DTM IDCODE.
4. Check manufacturer bits against `0x5b7` and record whether this looks like a T-Head implementation.
5. Read DTM register `0x10` using `dtm_op_dtm_reg_read`.
6. Treat that value as DTMCS.
7. Decode `version` from low nibble of DTMCS.
8. Dispatch to different helper families depending on the DTMCS version:
   - `dm_op_*` / `riscv013_*`
   - `dm011_*`
9. Decode `abits` from DTMCS and validate it.
10. If `dmistat` is sticky, write `dmihardreset` and reread DTMCS.

Confirmed helper behavior:

- `dm_op_dtm_abits_check` takes `(dtmcs >> 4) & 0x3f` as `abits`.
- It accepts `abits` in the range `7..32`.
- It stores `abits + 0x22` into a global used later for DM register addressing.

This is important because it means the vendor stack does not hardcode a single DMI width. It validates what the target reports and adapts.

## 4. Debug Module attach

After DTM detection, the vendor stack attempts a normal RISC-V Debug Module attach.

Confirmed in `riscv_dm_detect`:

- It writes DM register `0x10` multiple times.
- It then reads DM register `0x10` back.
- It reads DM register `0x11`.

The surrounding strings identify these as:

- DMCONTROL at `0x10`
- DMSTATUS at `0x11`

The literal DMCONTROL writes observed in the 0.13-style path are:

- `0x00000000`
- `0x00000001`
- `0x07ffffc1`

The vendor strings say this stage sets:

- `dmactive`
- `hasel`
- `hartselhi`
- `hartsello`

So the vendor stack is explicitly bringing up a multi-hart capable DMCONTROL state, not just hoping the default works.

## 5. Low target selection

`riscv_core_debug_connect` always calls:

- `get_riscv_low_target_rvdm`

This is the key architectural result:

- the normal RISC-V path is RVDM
- CKHAD exists in the library, but it is not the default path used by `riscv_core_debug_connect`

This matches the practical observation that BL808 LP appears to be exposed through a normal board-level JTAG/RVDM wrapper, even if the core itself has HAD support internally.

## 6. CPU selection and per-CPU programming

The next key stage is `riscv013_cpu_select`.

Confirmed behavior:

- It calls `riscv_get_dm013_info_by_cpu_num`.
- It computes a per-CPU DMCONTROL value and writes DM register `0x10`.
- It reads DM register `0x10` back and verifies the selected hart fields.
- It then emits a sequence of `link_config` calls with probe-side IDs:
  - `0x0e`
  - `0x0f`
  - `0x10`
  - `0x11`
  - `0x12`
  - `0x13`
  - `0x14`
  - `0x15`
  - `0x0a`

These values come from vendor per-CPU tables, not from a public text config.

This is probably the single most important reason the vendor stack is not reproducible via OpenOCD Tcl alone.

Inference:

- The per-CPU `link_config` sequence likely programs probe-side chain selection, IR values, and register access parameters for the selected CPU.
- On BL808 LP, this is a strong candidate for the behavior we are currently missing.

Follow-up disassembly of `libCklink.so` shows `link_config` is probe-side, not
a target MMIO write. The function reads and writes CKLink self-registers through
`ice_selfreg_read`/`ice_selfreg_write`, including self-register `0x8`. That
means the `riscv013_cpu_select` `link_config` sequence cannot be reproduced with
OpenOCD Tcl commands against the target unless the FTDI/OpenOCD path gains an
equivalent transport-level implementation.

The jump table for `link_config` maps the selectors used here as follows:

- `3` updates CKLink HAD/CDI type state and calls `ice_set_hadcditype`.
- `5` updates CKLink HAD version state and calls `ice_set_hadver`.
- `0x18` emits the escape/TMS sequence above.

The later `riscv013_cpu_select` selectors (`0x0e..0x15`, `0x0a`) also program
CKLink self-register fields. They are not standard RISC-V DMI transactions.

An FTDI/OpenOCD DMI check on the working M0 JTAG path also rules out a simple
standard-hart-selection solution for LP. After an FTDI nSRST pulse and M0
OpenOCD attach, this command sequence:

```sh
../openocd-had/src/openocd -f pine64jtag.cfg -f tgt_e907_v2.cfg \
  -c "halt" \
  -c "riscv dmi_read 0x10" \
  -c "riscv dmi_read 0x11" \
  -c "riscv dmi_write 0x10 0x00010001" \
  -c "riscv dmi_read 0x10" \
  -c "riscv dmi_read 0x11" \
  -c "riscv dmi_write 0x10 0x00020001" \
  -c "riscv dmi_read 0x10" \
  -c "riscv dmi_read 0x11" \
  -c "riscv dmi_write 0x10 0x00000001" \
  -c "shutdown"
```

reported one examined hart (`misa=0x40909125`) and these DMI values:

```text
DMCONTROL 0x10 -> 0x1
DMSTATUS  0x11 -> 0x4303a2
write DMCONTROL hartsel=1, dmactive=1
DMCONTROL 0x10 -> 0x1
DMSTATUS  0x11 -> 0x4303a2
write DMCONTROL hartsel=2, dmactive=1
DMCONTROL 0x10 -> 0x1
DMSTATUS  0x11 -> 0x4303a2
```

So the visible M0 DTM presents only hart 0. Writing hartsel fields for hart 1
or hart 2 reads back as hart 0 and does not expose LP/E902 behind the same DTM.

## 7. E902-specific details

Confirmed from the E902 target description:

- LP is modeled as RV32E, not full RV32I with 32 GPRs.
- The register file contains only `x0..x15`.
- `pc` is regnum `32`.
- `dcsr` and `dpc` are included.

Any OpenOCD path that treats LP as generic `riscv:rv32` without RV32E register semantics will be mismatched.

The local E902 user manual (`XuanTie-E902-R3S0-User-Manual_Rev.12_20260115.pdf`)
also points at the standard RISC-V Debug Module path, not the older OpenE902
raw-HAD register transport:

- E902 supports 5-wire JTAG and 2-wire cJTAG.
- The debug protocol is RISC-V External Debug Support 0.13.2.
- The documented DMI register map includes `DMCONTROL` at `0x10`,
  `DMSTATUS` at `0x11`, `DMCS2` at `0x32`, and XuanTie extension registers
  `CUSTOMCS` at `0x70`, `CUSTOMCMD` at `0x71`, `CUSTOMBUF0-7` at `0x72-0x79`,
  and `COMPID` at `0x7f`.
- XuanTie async halt is `CUSTOMCMD.type = 0`, which matches the OpenOCD patch
  that writes DMI address `0x71`.

That makes the raw `thead_had` OpenOCD transport a poor fit for this BL808 LP
route unless the SoC exposes the older OpenE902 JTAG2/HAD interface somewhere
else. The stronger software path is still standard RVDM once the correct
board-level port or CKLink-equivalent port-selection step is found.

The local OpenOCD build does not expose a generic FTDI `cjtag` transport. It has
`jtag` and the experimental `thead_had` transport; the latter is the older
OpenE902 JTAG2/HAD protocol, not standard E902 RVDM-over-cJTAG. This is why
clocking the CKLink `link_config(0x18, 0)` TMS sequence alone is insufficient:
there is no follow-on FTDI transport in the current tree that speaks the same
mode CKLink likely uses after that port-detect step.

## What this means for BL808 LP support

## Not enough for a cfg-only solution

The vendor behavior that matters is in compiled code, not public `.cfg` files:

- port-mode probing in `riscv_jtag_port_detect`
- DTMCS version and `abits` handling
- `dmistat` recovery via `dmihardreset`
- multi-hart DMCONTROL bring-up
- per-CPU `link_config` programming in `riscv013_cpu_select`
- CKLink probe-side self-register programming behind those `link_config` calls

So a plain OpenOCD target config will not fully reproduce vendor behavior.

## Probably feasible with OpenOCD code changes

This still looks supportable.

Why:

- the path is normal RVDM, not a hidden LP-only transport
- the vendor bundle contains a straightforward E902 RV32E tdesc
- the missing pieces are concentrated in attach and selection logic

What would likely need to be added on the OpenOCD side:

1. Better DTMCS handling
   - read DTM IDCODE
   - read DTMCS
   - validate `abits`
   - clear sticky `dmistat` with `dmihardreset`

2. Better DM 0.13 attach
   - explicit DMCONTROL bring-up
   - robust DMSTATUS checking

3. LP/E902 register model
   - RV32E register count and numbering
   - correct GDB target description

4. Possibly BL808-specific CPU selection
   - equivalent to the vendor `riscv013_cpu_select` sequence

The unknown is whether that last point can be handled entirely in target-side code, or whether it depends on CKLink-only `link_config` operations that generic FTDI/JTAG probes cannot issue.

## Bottom line

This is not an easy support task.

It is probably:

- not solvable by cfg edits alone
- probably solvable by targeted OpenOCD `riscv` driver changes
- only partly recoverable from the public vendor bundle, because the probe behavior is proprietary

The most likely productive path is:

1. keep BL808 LP on the regular JTAG/RVDM path
2. stop trying to expose raw LP HAD at the board header
3. patch OpenOCD's `riscv` attach logic to mimic:
   - `riscv_jtag_port_detect`
   - `riscv_dm_detect`
   - `riscv013_cpu_select`

## Repro commands

The main inspection commands used for this note were:

```sh
nm -D libTarget.so | rg 'riscv|dtm|dm|had|connect'
strings -a libTarget.so | rg -i 'rvdm|ckhad|dtmcs|dmstatus|dminfo|abits|hardreset'
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --disassemble-symbols=riscv_jtag_port_detect libTarget.so
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --disassemble-symbols=riscv_dm_detect libTarget.so
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --disassemble-symbols=riscv013_cpu_select libTarget.so
strings -a libCklink.so | rg -i 'ICE_REG_CPU_SEL|jtag|reset|cJtag'
sed -n '1,220p' riscv-e902-tdesc.xml
```
