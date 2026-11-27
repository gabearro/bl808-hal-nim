# FreeNetRadio on the BL808 (Pine64 Ox64)

A Nim port of [FreeNetRadio](https://github.com/alexhorner/freenetradio) (Rust, WCH CH32V307, MIT) to the BL808's M0 core, as an example for this HAL. It is an internet radio: it plays MP3 streams through a PCM5102A I2S DAC, shows what is playing on a 256×64 SSD1322 OLED, and is controlled from a web page or an NEC infrared remote.

The application, including the decoders, player, and rendering code,
is written in Nim. It uses the repository's Wi-Fi backend, lwIP,
WPA supplicant, and Mbed TLS integrations. Playback, connectivity,
and the opt-in profiler have been exercised on an Ox64. The
[FreeNetRadio guide](../../docs/freenetradio.md) has the current build and
flash workflow. This example guide covers wiring and operation.

## What it does

- Plays MP3 internet radio over `http://` and `https://` (Icecast/Shoutcast), follows redirects (up to 6) and `.m3u` / `.pls` playlists, and shows the station name and the ICY "now playing" title. AAC and Ogg streams are reported as unsupported.
- Status bar, scrolling station and title, stereo VU meters or a 40-band spectrum analyser (or both, alternating), message boxes, a boot animation, and a logo screen that dims after 10 s and can show the time.
- Volume on a perceptual curve, mute, a three-band equaliser with presets, click-free fades.
- A web page (`http://<address>/`) to play a URL, set the volume, edit and play the 99 presets, and press the buttons of a virtual remote; an HTTP API behind it.
- A 17-key NEC remote: volume, mute, previous/next preset, play/stop, preset numbers, and a settings menu (`#`) with time zone, daylight saving, status bar contents, visualiser, sleep clock, equaliser and an About page.
- 99 presets (ten SomaFM stations built in) and the last station, volume, mute and playing state are kept in flash, with debounced, wear-levelled saves.
- The clock is set by NTP (`pool.ntp.org`), with a time zone and EU/UK daylight saving.
- It reconnects by itself when a stream stalls or the network drops.

## Parts

| Part | Notes |
|---|---|
| Pine64 Ox64 (BL808) | The firmware runs on the M0 core (E907) and uses the on-board Wi-Fi. |
| PCM5102A I2S DAC module | Line-level output; needs an amplifier, powered speakers or headphones. |
| SSD1322 256×64 OLED module | 4-bit greyscale, configured for **4-wire SPI** (check the solder pads on the back). |
| VS1838B infrared receiver and a 17-key NEC remote | Usually sold together. |
| A USB-serial adapter | UART0 console (GPIO14 TX, GPIO15 RX, 230400 baud) and flashing. |

## Wiring

From `board.nim`. Every pin can be changed at build time with `-d:<Name>=<gpio>` (the names are in the table); the build fails if a pin cannot carry its function.

| From | To (Ox64 GPIO) | Define |
|---|---|---|
| DAC **BCK** | GPIO20 | `I2sBclkPin` |
| DAC **LCK** (LRCK) | GPIO21 | `I2sFsPin` |
| DAC **DIN** | GPIO23 | `I2sDoPin` |
| DAC **SCK**, **FMT** | GND | |
| DAC **XSMT** | 3V3 (if the module has this pin) | |
| DAC **VIN** / **GND** | 3V3 (or 5V) / GND | |
| OLED **SCLK (D0)** | GPIO27 | `OledSclkPin` |
| OLED **SDIN (D1)** | GPIO25 | `OledSdinPin` |
| OLED **CS** | GPIO24 | `OledCsPin` |
| OLED **D/C** | GPIO28 | `OledDcPin` |
| OLED **RES** | GPIO29 | `OledResPin` |
| OLED **VCC** / **GND** | 3V3 / GND | |
| IR receiver **S** (signal) | GPIO19 | `IrPin` |
| IR receiver **+** / **−** | 3V3 / GND | |

BL808 pin functions repeat every four GPIOs: BCLK needs `gpio mod 4 = 0`, FS `1`, I2S data out `3`, SPI data `1`, SPI clock `3`. The map stays clear of the console (14, 15), JTAG (6, 7, 12, 13), the microSD nets (0–5) and the D0 console (16, 17). If the panel stays dark, the SPI data pad may be the other one of the pair: rebuild with `-d:radioOledSpiSwap -d:OledSdinPin=26` and move the wire to GPIO26.

## Quick start

Wire the peripherals, then follow [Build and start playback](../../docs/freenetradio.md#build-and-start-playback).
Open the address printed by the board once it has joined Wi-Fi.

## Prerequisites

From the repository root, install the
[toolchain](../../docs/getting_started.md#toolchain) and prepare the
[pinned Wi-Fi SDK and patches](../../docs/bl808_vendor_blobs.md#wi-fi-application-build-inputs).
The build also uses `gzip` and `od` to embed the web page.

Wire a 3.3 V serial adapter to UART0 for the console and serial flashing.

| Adapter | Ox64 |
|---|---|
| RX | GPIO14 (UART0 TX) |
| TX | GPIO15 (UART0 RX) |
| GND | GND |

Power the Ox64 from its USB input.

## Build

Set `BL808_WIFI_SSID` and `BL808_WIFI_PASSWORD` in your local environment.
The credentials are compiled into the image. Keep the image and build
tree local.

```sh
.venv/bin/python tools/hw_validate.py --test freenetradio --build-only
```

The harness writes `kernel.elf` and `kernel.bin` under
`build/hw-validation/bin/freenetradio/`. Keep the matching ELF for
profiling. The [build configuration](freenetradio.nims) sets the eight-slot
Wi-Fi RX DMA ring, separate host TX and MAC DMA pools, and a 10 KiB lwIP
TCP receive window.

### Optional D0 MP3 decoder

The default build decodes on M0. On a board where FreeNetRadio owns D0,
build the [D0 worker](d0_mp3_worker.nim) and pass its image through
`--nim-define radioD0Mp3Image=...` when building or flashing. D0 uses fused
floating-point operations, so PCM can differ from M0. If the worker stops
responding, M0 resumes decoding locally.
[Build the D0 variant](../../docs/freenetradio.md#enable-the-d0-decoder).

### Other build options

| Define | Effect |
|---|---|
| `-d:radioDiag` | Adds `GET /stats`, `POST /stats/reset` and `GET /screen/stream`, lengthens the web request deadline from 5 s to 60 s, and measures stack use. |
| `-d:radioProfiler` | Enables on-demand cycle counts, hardware events, and audio timing captures. |
| `-d:radioNoTls` | Builds without `bl808/kernel/tls`; `https://` URLs then fail with a message. |
| `-d:radioOledSpiSwap` | Use the other SPI data pad (see Wiring). |
| `-d:StoreOffset=<n>` | Where the 512 KB preset and settings store starts in flash (default: the HAL's application-data partition, `0x680000`). Numeric defines take decimal values only. |
| `-d:radioRingAddress=<n>` `-d:radioRingFrames=<n>` | Place the I2S ring and DMA list at a fixed address. The default FreeNetRadio ring is 12,288 four-byte frames. |
| `-d:bl808MbedTlsSoftware` | The repository's switch for TLS without the crypto engines; see `src/bl808/mbedtls/build.nim` for the per-engine ones (SHA-256, SHA-512, AES, P-256, RSA). |

### Memory use

Run `riscv64-unknown-elf-size -A` on the ELF for the build you plan to flash.
`.wifibss` holds uncached Wi-Fi state and DMA buffers, and `.psrambss` holds
application state. Measure runtime heap and stack peaks during playback
when comparing build options. Use the [Wi-Fi guide](../../docs/wifi.md#service-and-dma)
for the RX ring and TX pool defaults.

### Host tests

From the repository root:

```sh
(
  set -e
  for test_file in examples/freenetradio/tests/t_*.nim; do
    test_name=$(basename "$test_file" .nim)
    nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --hints:off \
      --nimcache:"build/freenetradio-tests/cache/$test_name" \
      --out:"build/freenetradio-tests/bin/$test_name" "$test_file"
  done
)
```

The tests cover the MP3 decoder, player, stream, display, controls, and
HTTP server. `t_stream_https` launches a local `openssl s_server` and
skips its HTTPS cases if `openssl` is unavailable.

## Flash and open the radio

Set `UART_PORT` to the adapter found by
`.venv/bin/python tools/hw_validate.py --list`. On a serial-only bench, run:

```sh
.venv/bin/python tools/hw_validate.py --test freenetradio \
  --rom-flash --uart "$UART_PORT"
```

At the prompt, remove board power, hold BOOT while restoring power,
release BOOT, and press Enter. The harness verifies the flash writes
and reboots. It captures the console under `build/hw-validation/logs/`.
If your bench has JTAG, use the
[JTAG-loaded UART anchor workflow](../../docs/freenetradio.md#build-and-start-playback).

At 230400 baud, look for `wifi: joined`, the DHCP address, and
`Serving on http://`. Open the printed address in a browser. If association
fails, check the build credentials and the availability of the 2.4 GHz
network. Close other serial clients before running the flash harness.

## Use

Power it up. It joins the Wi-Fi network it was built for, gets an address by DHCP and shows it on the logo screen while stopped. Open `http://<that address>/` in a browser, paste a stream link and press Play, or use the remote. If it was playing when the power went, it starts playing again.

### The remote

| Button | What it does |
|---|---|
| ▲ / ▼ | Volume up / down (hold to repeat) |
| `*` | Mute / unmute |
| ◀ / ▶ | Previous / next preset |
| OK | Play / stop |
| `0`–`9` | Jump to a preset number (one or two digits; a lone `0` is preset 10) |
| `#` | Open or close the settings menu |

In the settings menu, ▲/▼ pick a row, ◀/▶ change it, and OK goes in or out of a submenu. A button the radio does not know shows its code on the display, so another NEC remote can be mapped in `remote.nim`.

### HTTP API

| Request | Does |
|---|---|
| `GET /` | The web page (gzip). |
| `GET /radio` | Player status as JSON: `state` (`stopped`, `connecting`, `buffering`, `playing`, `error`, `offline`), `message`, `url`, `station`, `title`, `sample_rate`, `bitrate`, `channels`, `buffer`, `underruns`, `volume`, `muted`. |
| `POST /radio/play` | Start a stream. Body: the URL as plain text, or a form field `url=`. |
| `POST /radio/stop` | Stop. |
| `POST /radio/volume` | Body `0`..`100`, or a form field `volume=`. |
| `GET /presets` | The 99 presets as a JSON array of `{"name":…,"url":…}`. |
| `POST /presets/<1..99>` | Save a preset: form fields `name=` and `url=` (an empty `url` clears it). |
| `POST /presets/<n>/play` | Play a preset. |
| `POST /presets/reset` | Back to the built-in presets. |
| `POST /remote/<key>` | Press a remote button: `0`..`9`, `star`, `hash`, `up`, `down`, `left`, `right`, `ok`. Append `?repeat` for a held button's repeats. |
| `GET /licenses` | The open source list, one `name|author|license` line each. |
| `GET /screen` | The raw framebuffer: 8192 bytes, 256×64, 4 bits per pixel, left pixel in the high nibble. |
| `GET /stats` (diag) | Counters and timings as text. |
| `POST /stats/reset` (diag) | Restart the high/low-water marks. |
| `GET /screen/stream?n=<frames>` (diag) | A screen recording: `n` whole frames (default 100), 8192 bytes each. |

The `/radio/*` and `/remote/*` POSTs reply with the status JSON, and the preset POSTs with `ok`, or with `303 See Other` to `/` when the request's `Accept` header includes `text/html` (a plain HTML form submit). A failed preset change is a `500` with the reason. A request must fit in 1024 bytes (`413` otherwise) and be complete within 5 s. Two connections are served at a time; a third is refused.

```sh
# Set RADIO_URL to the URL printed by the board, without a trailing slash.
curl -d 'http://ice1.somafm.com/groovesalad-128-mp3' "$RADIO_URL/radio/play"
curl -d 30 "$RADIO_URL/radio/volume"
curl -X POST "$RADIO_URL/remote/ok"
curl "$RADIO_URL/radio"
curl -s "$RADIO_URL/screen" | \
  python3 -c 'import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(b"P5 256 64 15\n"+bytes(n for b in d for n in (b>>4, b&15)))' > screen.pgm
```

## Differences from upstream

- **Wi-Fi instead of Ethernet.** The Ox64 has no Ethernet jack, so the radio is a Wi-Fi station (SSID and password are build-time defines). "Link" means associated with the access point: upstream's "No network link" and "Getting address..." status texts are kept, and the stream's link-down message reads "The Wi-Fi link is down. Check that the access point is in range." It reconnects with a back-off and never reboots.
- **TLS** comes from the repository (`bl808/kernel/tls`, Mbed TLS 3.6) rather than a patched `embedded-tls`. On the M0 it runs on the chip's crypto engines, each with a software fallback: whole AES-GCM records (AES in counter mode and GHASH, 2.9 MB/s against 0.7 MB/s with GHASH in software), the SHA-256 and SHA-384/512 compression functions, P-256 for the key exchange and the server's signature check (multiples of the base point excepted: the software table is faster than the chip), RSA signature checks up to 2048 bits, and the random numbers. Joining the Wi-Fi network derives the WPA2 key with SHA-1 on the chip too. ChaCha20-Poly1305, X25519, P-384 and RSA keys above 2048 bits are software: the chip has nothing for the first two, and the last two only matter when certificates are verified, which this firmware does not do. It offers TLS 1.3 with upstream's AES-128-GCM-SHA256 and P-256 first, then AES-256-GCM, ChaCha20-Poly1305, X25519 and P-384, and falls back to TLS 1.2. Full-size TLS records are accepted, so upstream's "records too big" failure should not occur; the message remains for that error class. The two handshake messages keep upstream's wording ("may not offer TLS 1.3", "needs AES-128-GCM and P-256") although more is accepted here. As upstream, certificates are not verified, and a stream whose connection ends without TLS's close_notify counts as lost (it reconnects), not as ended.
- **User-Agent** is `BL808-FreeNetRadio/0.1`.
- **DNS**: the radio has its own small resolver. It asks the DHCP gateway first, then 1.1.1.1 and 8.8.8.8, hands NTP all the addresses it gets, and tells a name that has no address from a lookup that failed. lwIP's resolver can be built into the Wi-Fi profile (`-d:bl808WifiRealLwipDns`), but it gives one address per name and a single kind of failure, and takes about 1.2 KB of on-chip RAM, so the radio does not use it.
- **Storage**: 512 KB of flash at `0x680000` (the HAL's application-data partition). Records are upstream's 256-byte pages byte for byte, but each preset has a 4 KB sector of its own (the erase unit here) and the settings are appended to two 32-slot rings, so most saves are a 1 ms page program rather than an erase.
- **`/stats`**: the same lines in the same format. "rx ring overflows" is always 0 (there is no Ethernet receive ring), "last error" is the raw Mbed TLS error code, "tls decoded" and "pending" are Mbed TLS's nearest equivalents (plaintext of the current record not yet read, and bytes of the record being received), and one line is added at the end: "wifi reconnects". The stack line is measured as upstream, from the end of `.bss` to the top of on-chip RAM.
- **Web server details**: a path of `/presets/play` answers "No such preset" (upstream panics on it); `/screen/stream` refuses a second recording while one is running and always releases the display when its connection ends.
- **Playback buffers** hold 12,288 stereo frames in the DAC ring (279 ms at 44.1 kHz) and 64 KiB of stream data. When the DAC has less than 3,456 frames queued, the audio task can decode up to three frames before yielding.
- **OLED rendering and transfer** use precomputed glyph rows and packed 4-bit framebuffer writes. The HAL sends the 8 KiB framebuffer through SPI0 DMA and reports completion after the bus goes idle. A frame that misses its 100 ms deadline is dropped.
- **Preset saves at the same moment** (two browser tabs, a double click, a save straight after "reset to defaults") run one after the other in the order they arrived, each answering for itself. Upstream runs them interleaved, where two first saves can overwrite each other's slot.
- **TCP receive window**: 10 KB for the stream, as upstream's plain-http connection (upstream's https one has 7 KB). It is lwIP's `TCP_WND`, set in `freenetradio.nims`, so the web server's two connections have the same window and a 10 KB receive buffer each.
- **About page and `/licenses`** list this port's components instead of upstream's Rust crates.

Not applicable on this board, and so not ported: the RJ45 jack LEDs, the `ram-split` flash/RAM option tool, the fast/slow flash placement of code, and the Ethernet PHY polarity handling.

## Checking the board with no parts attached

A `-d:radioDiag` build can test most of the audio, display and remote paths on a bare Ox64 (`pincap.nim`, routes under `/selftest/`). On the Ox64 this was run on, with a stream playing:

| Path | How it is checked | Result on the board |
|---|---|---|
| I2S clock and framing | `GET /selftest/i2s`: the I2S registers, and how many frames the audio DMA takes from the ring in 60 ms with interrupts off | 44,102 frames/s for a 44.1 kHz stream (BCK 2.8225 MHz from a 22.58 MHz audio PLL); registers say master, Philips I2S, 16 bits in 32-bit slots, one FIFO word per stereo frame |
| Display control pins | `POST /selftest/capture?t=init`: a spare DMA channel samples the GPIO input register 4.16 million times a second while the panel init and one frame go out at 1 MHz | all 23 commands seen on CS and D/C with the right argument counts, RES high, pixel data after `0x5C`; each byte lasts the 9.5 us a 1 MHz SPI clock gives |
| Display transfer | `/stats` and the cycle profiler | About 49 frames a second during playback, zero flush timeouts and zero SPI0 interrupts in a 12-second capture |
| IR receive | `POST /selftest/ir` plays an NEC frame on the IR pin by switching the pad between pull-down and pull-up | decoded as address 0x00 command 0x45, no errors, on a pin with nothing attached |

The same build can say where the processor's time goes, which is how the drop-outs above were traced: `GET /selftest/slices` (the longest stretch and the share of time of each task since the last read), `POST` then `GET /selftest/stalls` (a task that only yields logs every turn of the scheduler that took over 15 ms), and `POST /selftest/profile` then `GET` (16,384 program counters sampled at 2 kHz by a timer interrupt; match them to functions with `riscv64-unknown-elf-nm -S`; with `?stall` the run keeps the newest samples and stops at a 40 ms stall).

`tools/pincheck.nim` turns the captures and the I2S report into pass/fail lines (its header has the commands). `tests/t_panel.nim` plays the driver's bytes into a model of the SSD1322 written from the controller's command table.

What this cannot show: the BL808 reads a pad back only while the pad is a GPIO, so BCK, LCK, DIN, SCLK and SDIN themselves are not observed. That the pins carry those signals rests on the pin function numbers and the vendor's pin tables; it takes the real parts or a logic analyser to see it. The first thing to try if the panel stays dark is still `-d:radioOledSpiSwap`.

Two things found this way. GPIO19, the default IR pin, is held high by something on the board that was tested (`GET /selftest/pulls` lists which unused pins follow their pull resistors); a VS1838B idles high and pulls low, so that is no obstacle, but the pull-resistor test needs a floating pin (`-d:IrPin=18`). And a capture slows the CPU while it runs, so frame times measured from a full-speed capture (`t=fast`) are longer than the real ones.

## CPU profiling

Use the [profiler guide](../../docs/profiling.md) for the M0 JTAG sampler,
D0 retire monitor, and the FreeNetRadio hardware-counter and audio captures.

## Check a new build on the board

1. Confirm the console reaches `Serving on http://` and the HTTP controls respond.
2. Start steady playback and sample the buffer level and underrun count in `/radio`.
3. Check the OLED refresh, IR controls, and settings persistence if the peripherals are attached.
4. Use [Profiling](../../docs/profiling.md) for comparable CPU and audio captures.

## Files

| | |
|---|---|
| `freenetradio.nim`, `freenetradio.nims` | `main`: memory, console, init order, task start; the build's lwIP setting |
| `board.nim` | pins, flash layout |
| `mp3dec.nim`, `mp3tables.nim` | MP3 decoder (port of `nanomp3-core`, with the spectrum patch) |
| `player.nim`, `eq.nim`, `i2s_ring.nim`, `i2s_out.nim`, `audio_task.nim` | decode loop, equaliser, fades, I2S + DMA output |
| `stream.nim`, `stream_task.nim`, `tlsbind.nim`, `tcpconn.nim`, `resolver.nim`, `dnsmsg.nim`, `net_task.nim` | stream client, its TLS binding, TCP, DNS, Wi-Fi and DHCP |
| `display.nim`, `gfx.nim`, `fonts.nim`, `framebuf.nim`, `ssd1322.nim`, `display_task.nim` | screens, drawing, fonts, panel driver |
| `pincap.nim`, `tools/pincheck.nim` | diag builds: the pin self-test and its host-side checker |
| `ir_rx.nim`, `ir_nec.nim`, `remote.nim`, `menu.nim`, `controls_task.nim` | IR receiver, button actions, settings menu, NTP |
| `presets.nim`, `settings.nim`, `flashdev.nim` | presets and remembered settings in flash |
| `httpd.nim`, `http_task.nim`, `webpage.nim`, `index.html` | web server and page |
| `status.nim`, `prefs.nim`, `ui.nim`, `pipe.nim`, `netstate.nim`, `netio.nim`, `spectrum.nim`, `wallclock.nim`, `diag.nim`, `text.nim`, `timebase.nim`, `about.nim`, `licenses.txt` | shared state and helpers |
| `tests/` | host tests |

## License

FreeNetRadio is by Alexander Horner and released under the MIT License; this port is under the same terms as the rest of this repository (MIT). The components are listed in `licenses.txt`, on the radio (Settings → About) and at `GET /licenses`. The built-in stations are public streams from [SomaFM](https://somafm.com), which is not affiliated with either project.
