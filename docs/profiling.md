# Profiling BL808 firmware

Keep the ELF from the image that produced the samples. Use a separate
`--work-dir` or output prefix for each measurement. JTAG PC samples, hardware
counter deltas, and timed source regions answer different questions.

| Measurement | Collection path | Scope |
| --- | --- | --- |
| M0 hotspot addresses | E907 hardware PC sampler via JTAG | Approximate sample shares without a firmware profiler build |
| D0 hotspot addresses | C906 retire monitor read by an M0 observer | D0 retire PCs while the workload runs |
| Hardware performance events | [hpm.nim](../src/bl808/hpm.nim) plus a firmware snapshot or D0 observer hook | Cycle, retirement, cache, branch, and supported D0 TLB events over a window |
| Playback work and wake latency | FreeNetRadio opt-in profiler | Timed M0 regions, IRQ handlers, WFI time, and audio state |

## M0 JTAG PC samples

If the flashed image was built with the default harness paths:

```sh
.venv/bin/python tools/hw_validate.py --jtag-live-profile 30 \
  --jtag-profile-elf build/hw-validation/bin/freenetradio/kernel.elf
```

The TAP-only sampler leaves M0 running and writes
`logs/jtag-live-profile.json` under the harness work directory.
`--jtag-profile-rate` sets the requested sample rate. Supply the matching ELF
to resolve addresses and functions. The E907 samples recent branch
destinations, so an idle or waiting core can repeatedly return the same
address. A large scheduler sample share alone cannot distinguish runnable
work from an interrupt wait. Use the timed scheduler regions and WFI wall
time for that split.

## D0 retire monitor

The manifest's observer and test workload can be RAM-loaded for a bench
check. This temporarily replaces the programs running on M0 and D0.

```sh
.venv/bin/python tools/hw_validate.py --test d0_profile_observer \
  --jtag-load --no-jtag-reset --uart "$UART_PORT"
.venv/bin/python tools/hw_validate.py --d0-live-profile 10 --profile-rate 100 \
  --profile-elf build/hw-validation/bin/d0_profile_observer/d0.elf \
  --profile-hpm --uart "$UART_PORT"
```

The M0 observer sends 40-bit D0 PCs and status over UART0.
`logs/d0-live-profile.json` retains halted and zero-address samples and
excludes them from hotspot shares. A D0 workload that has not retired a new
instruction can repeat its last PC.

For your own D0 firmware, enable the counters in machine mode with
`enableHpm` before calling `serviceD0Hpm` periodically. Reserve XRAM offsets
`0x3b00`–`0x3bbf` for the observer mailbox. A supervisor-mode hook requires
`allowSupervisor = true` at setup, an uncached identity mapping for XRAM,
and `supervisor = true` on the hook. Use PC-only collection for images
without the mailbox service.
[Observer protocol](../src/bl808/d0profile.nim) ·
[Example workload](../examples/d0_profile_workload.nim).

## Hardware events

M0 and D0 can count cycles, retired instructions, L1 instruction-cache
accesses and misses, L1 data-cache reads and writes with misses, and
conditional branches and mispredictions. D0 also has instruction, data,
and joint TLB miss events. Read the event mask from each recording to see
which selectors were configured successfully. Use conditional branches
as the denominator when reporting the misprediction rate.

On D0 configurations with eight programmable slots, choose the TLB or
data-cache group. The observer example defaults to TLB. Build it with
`--nim-define bl808D0ProfileDataCache=1` for the data-cache group. The common
cycle, retirement, instruction-cache, and branch events are present in
both. A whole-window delta can include application, scheduler, and
interrupt activity.

## FreeNetRadio counters and timeline

Build and flash as described in [FreeNetRadio](freenetradio.md), adding
`--nim-define radioProfiler=1`. Set `RADIO_URL` to the board's HTTP base
address, then capture a fixed interval:

```sh
python3 examples/freenetradio/tools/profile_radio.py capture "$RADIO_URL" \
  --seconds 30 --summary-only --out build/radio-profiles/playing
```

The summary includes cycles and retired instructions by region and IRQ
handler, work counts, WFI wall time, and audio wake and queue measurements.
Region clocks include nested calls and time spent in interrupts. Compare each
region separately and use its work count for cycles per decoded frame or
other per-unit metrics. Whole-window HPM counts give aggregate branch and
cache behavior. WFI uses the wall timer. A firmware call can dispatch no
events, and a deferred TX call with work submitted at least one frame.
Audio sleep latency starts at the requested deadline. Yield latency starts
when the audio task posts its continuation. Report histogram percentiles as
upper bounds.

Omit `--summary-only` to capture the timeline. The recorder holds the newest
2,048 events and freezes the history on the first underrun or wake delay past
the configured threshold. The default is 15 ms and `RadioProfileLateUs`
sets it at build time. The tool saves the binary capture, summary JSON, and
a Perfetto JSON timeline when tracing is enabled. Run
`profile_radio.py analyze` with the saved binary to decode it again. Open the
timeline in [Perfetto](https://ui.perfetto.dev/) to inspect audio, rendering,
Wi-Fi, and IRQ tracks.

The opt-in firmware provides `POST /profile/start`,
`POST /profile/start-summary`, `POST /profile/stop`, and
`GET /profile/capture`. The start routes accept a decimal duration from
100 to 120,000 ms. The default is 30,000 ms.

For before-and-after measurements, fix the board, AP and channel, stream,
build options, duration, and traffic schedule. Record connected idle and
steady playback. Use equal capture modes, and measure summary versus trace
overhead separately.
