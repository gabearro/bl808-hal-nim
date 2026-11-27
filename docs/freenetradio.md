# FreeNetRadio on the Ox64

FreeNetRadio plays MP3 internet radio through an I2S DAC and drives an SSD1322
OLED. M0 owns the radio application, Wi-Fi, audio output, and display. An
optional D0 worker takes over MP3 decoding. Playback, Wi-Fi association, and
the opt-in profiling paths have run on the Ox64.

Use the [example guide](../examples/freenetradio/README.md) for the wiring
table, player controls, HTTP API, and preset storage. This page covers the
current harness workflow.

## Build and start playback

Install the [toolchain](getting_started.md) and the
[pinned Wi-Fi SDK inputs](bl808_vendor_blobs.md). Set `BL808_WIFI_SSID` and
`BL808_WIFI_PASSWORD` in your environment. The credentials are compiled into
the firmware. Keep the image and its build tree local.

```sh
.venv/bin/python tools/hw_validate.py --test freenetradio --build-only
```

The [manifest entry](../tools/hardware_validation.json) supplies the Wi-Fi
and linker defines. [freenetradio.nims](../examples/freenetradio/freenetradio.nims)
sets an eight-slot RX DMA ring and requires separate TX pools. The
defaults are 16 host slots, 16 MAC DMA records, and 32 packet buffers.

Set `UART_PORT` to the runtime serial device found by the
[hardware harness](hardware_validation_harness.md). On a JTAG-equipped
bench, flash and reboot through the temporary UART anchor:

```sh
.venv/bin/python tools/hw_validate.py --test freenetradio \
  --uart-anchor-flash --uart-anchor-reset-after-flash --no-jtag-reset \
  --uart "$UART_PORT"
```

With UART alone, use `--rom-flash` in place of the three anchor/reset switches
and follow the BOOT prompt. Watch for `Serving on http://` in the UART log, then
open the printed address or query `GET /radio`. That endpoint reports the
player state, buffer level, sample rate, bitrate, and underrun counter.
Wait for steady playback before starting a profiling or load window.

## Enable the D0 decoder

Use this option on a board where the radio owns D0. The host builds a
RAM-linked worker, embeds its image in M0 flash, and lets M0 start it.

```sh
mkdir -p build
nim c -d:bl808kernel -d:bl808d0 --out:build/freenetradio-d0.elf \
  examples/freenetradio/d0_mp3_worker.nim
riscv64-unknown-elf-objcopy -O binary \
  build/freenetradio-d0.elf build/freenetradio-d0.bin
```

Build the M0 image with the worker included:

```sh
.venv/bin/python tools/hw_validate.py --test freenetradio --build-only \
  --nim-define "radioD0Mp3Image=$PWD/build/freenetradio-d0.bin"
```

Pass the same define when flashing through the harness.
The worker uses fused floating-point operations and can round differently
from the M0 decoder. M0 resumes local decoding if the worker stops responding.
A D0 build should be checked with the exact same MP3 stream and volume as its
M0 comparison. The radio profiler's MP3 region measures M0 work, including
the cost of interacting with the worker. Use the [D0 profiling
path](profiling.md#d0-retire-monitor) for D0-side measurements when the target
build supports that observer.

## Diagnose playback and display

- Add `--nim-define radioDiag=1` for `/stats`, display diagnostics, and
  board self-tests. Use a release build with just
  `--nim-define radioProfiler=1` for comparable CPU and audio captures.
- For underruns, record the counter delta, buffer minimum, and stream bitrate
  during the same capture window.
- For a dark OLED, check the panel's SPI wiring and the pin functions before
  trying the alternate pad documented in the
  [wiring table](../examples/freenetradio/README.md#wiring).

Use [Profiling](profiling.md#freenetradio-counters-and-timeline) for the
capture command and interpretation, and [Wi-Fi](wifi.md#measure-packet-loss)
for reply and MAC retry comparisons.
