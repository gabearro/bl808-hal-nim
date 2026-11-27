# FreeNetRadio on the BL808 (Pine64 Ox64)

A Nim port of [FreeNetRadio](https://github.com/alexhorner/freenetradio) (Rust, WCH CH32V307, MIT) to the BL808's M0 core, as an example for this HAL. It is an internet radio: it plays MP3 streams through a PCM5102A I2S DAC, shows what is playing on a 256×64 SSD1322 OLED, and is controlled from a web page or an NEC infrared remote.

The port is pure Nim: the MP3 decoder, HTTP client and server, graphics, fonts and drivers are all in this directory. The only C underneath is what the repository already provides (lwIP, the Wi-Fi stack, Mbed TLS).

**Status: builds and passes its host tests; it has not been run on hardware.** The host tests include an end-to-end one that plays an https Icecast-style stream from a local `openssl s_server` through the stream client, the repository's TLS, the player and the MP3 decoder. The radio's hardware code (I2S and DMA, the OLED, the IR input, flash) and its Wi-Fi and lwIP glue have only been compiled, and several of the HAL procedures they call are new and have only run against register-level fakes or in QEMU. See [Bring-up checklist](#bring-up-checklist) before trusting any of it on a board.

## What it does

The same as upstream:

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

1. Install the tools (Prerequisites).
2. Build `build/freenetradio.bin` with your Wi-Fi network's name and password (Build).
3. Put the Ox64 in its boot loader and write the image over the serial adapter (Flash; the harness there also does step 2).
4. Power-cycle the board and open the address it prints (First boot).

## Prerequisites

All commands run from the repository root.

| Tool | Version used here | For |
|---|---|---|
| Nim | 2.2.6 | the compiler (`nim`) |
| `riscv64-unknown-elf-gcc`, `-objcopy`, `-size` | GCC 14.2 | the RISC-V cross toolchain Nim hands the C to; it must be on `PATH` |
| Python 3 with a venv in `.venv` | `requirements.txt` | `pyserial`, for flashing and the console, and `pytest` for the harness's own tests |
| The vendor SDK checkout | `build/bl_iot_sdk_b773b3f` | lwIP, the WPA supplicant and the radio calibration library that every Wi-Fi image in this repository builds against; `docs/bl808_vendor_blobs.md` describes the pinned commit and the repository's patches to it |
| A 3.3 V USB-serial adapter | | flashing and the console |

```sh
uv venv .venv && uv pip install -r requirements.txt     # once
```

Without `uv`: `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`. `make venv` installs `requirements-hw.txt` instead, which adds the vendor's `bflb-iot-tool` for the alternative flashing route.

Wire the adapter to UART0, which is both the boot loader's port and the firmware's console:

| Adapter | Ox64 |
|---|---|
| RX | GPIO14 (UART0 TX) |
| TX | GPIO15 (UART0 RX) |
| GND | GND |

Power the Ox64 from its own USB port, not from the adapter's 3.3 V pin.

## Build

Pass the Wi-Fi credentials on the command line; they are compiled into the image, so never put them in a file in the repository.

```sh
nim c -d:bl808kernel -d:bl808m0 -d:bl808WifiApp -d:bl808WifiHttpServer -d:bl808WifiNimFw \
  -d:bl808WifiUseBl808Rf -d:bl808WifiNativeWlanCalibration \
  -d:bl808WifiRealLwip -d:bl808WifiRealLwipTcp -d:bl808WifiRxPbufInput \
  -d:HwValidationLogExternalBuffer=1 -d:HwValidationLogSection=.psrambss.jtaglog \
  -d:WifiSsid=<ssid> -d:WifiPassword=<password> \
  --nimcache:build/nimcache_freenetradio -o:build/freenetradio.elf \
  examples/freenetradio/freenetradio.nim
riscv64-unknown-elf-objcopy -O binary build/freenetradio.elf build/freenetradio.bin
riscv64-unknown-elf-size -A build/freenetradio.elf
```

The first build takes a few minutes (it compiles lwIP, the Wi-Fi stack and Mbed TLS); later ones reuse `build/nimcache_freenetradio`. The result is `build/freenetradio.bin`, about 800 KB. A network name or password with spaces or shell characters needs quoting: `"-d:WifiSsid=My Network"`.

`freenetradio.nims`, next to the main file, is read by Nim on every build and adds what is not a define: the TCP window, the stack size and the hardware SHA-1 for joining the network.

`bl808WifiApp` selects the linker profile for a Wi-Fi application (`src/linker/bl808_m0_wifi_app.ld`): a 1 MB heap in PSRAM, and the zero-initialised globals of every module in this directory in PSRAM too, which leaves the 64 KB of on-chip RAM to the HAL, Wi-Fi, lwIP and the stack. `bl808WifiHttpServer` stays: the Wi-Fi code keys its own RAM placement on it. The two `HwValidationLog*` defines move a log buffer out of the nearly full on-chip RAM. `freenetradio.nims`, which Nim reads by itself, sets lwIP's TCP receive window to 10 KB (`TCP_WND` is a C setting and has no Nim define). The build needs `gzip` and `od` on the build machine (the web page is compressed at compile time).

### Optional D0 MP3 decoder

On an Ox64 dedicated to FreeNetRadio, the D0 worker can decode MP3 while M0
services Wi-Fi and the display. Build the RAM-linked worker from the repository
root.

```sh
nim c -d:bl808kernel -d:bl808d0 --out:build/freenetradio-d0.elf \
  examples/freenetradio/d0_mp3_worker.nim
riscv64-unknown-elf-objcopy -O binary build/freenetradio-d0.elf build/freenetradio-d0.bin
```

Add `-d:radioD0Mp3Image="$PWD/build/freenetradio-d0.bin"` to the M0 build above.
The M0 image includes the worker and starts it in D0 RAM. The worker uses fused
floating-point operations. If D0 stops responding, M0 resumes decoding locally.

### Other build options

| Define | Effect |
|---|---|
| `-d:radioDiag` | Adds `GET /stats`, `POST /stats/reset` and `GET /screen/stream`, lengthens the web request deadline from 5 s to 60 s, and measures stack use. |
| `-d:radioNoTls` | Builds without `bl808/kernel/tls`; `https://` URLs then fail with a message. |
| `-d:radioOledSpiSwap` | Use the other SPI data pad (see Wiring). |
| `-d:StoreOffset=<n>` | Where the 512 KB preset and settings store starts in flash (default: the HAL's application-data partition, `0x680000`). Numeric defines take decimal values only. |
| `-d:radioRingAddress=<n>` `-d:radioRingFrames=<n>` | Put the I2S ring (4 bytes per frame, default 4096 frames) and its DMA list at a fixed address instead of on the heap (see the bring-up checklist). |
| `-d:bl808MbedTlsSoftware` | The repository's switch for TLS without the crypto engines; see `src/bl808/mbedtls/build.nim` for the per-engine ones (SHA-256, SHA-512, AES, P-256, RSA). |

### Size

Measured with `riscv64-unknown-elf-size -A` on a build with the command above (GCC 14.2, Nim 2.2.6):

| Region | Size | Used | Free |
|---|---|---|---|
| Flash (`.init` + `.text` + `.data`) | 1,048,576 bytes in the linker profile; the harness's firmware partition is 983,040 | 800,810 bytes | 247,766 bytes (184,894 of the partition) |
| On-chip RAM (`.data` + `.bss`, then the stack) | 65,536 bytes | 38,540 bytes | 26,992 bytes: the 20 KB stack (`freenetradio.nims`; its deepest use so far, through a TLS handshake, is 5 KB) and 6.5 KB of slack, of which the linker script insists on 4 KB |
| Uncached Wi-Fi RAM (`.wifibss`, including the crypto engines' DMA buffers) | 117,760 bytes | 51,664 bytes | 66,096 bytes |
| PSRAM bss window (`.psrambss`: the radio's globals and the 8 KB log buffer) | 131,072 bytes | 11,024 bytes | 120,048 bytes |
| PSRAM heap (every buffer over ~1 KB, lwIP, Mbed TLS) | 1 MB | at run time; a TLS session peaks around 36 KB | |

FreeNetRadio uses an eight-slot native Wi-Fi RX DMA ring, set in
`freenetradio.nims`. The Wi-Fi firmware default is 41 slots for builds
without an application setting.

`-d:radioDiag` adds 14,628 bytes of flash (the diagnostic routes, the `/stats` text and the pin and crypto self-tests are left out of the firmware without it). `-d:radioNoTls` takes flash down to 655,390 bytes, but on-chip `.data` + `.bss` grow to 45,688 bytes, leaving 19,840 bytes for the stack: without the TLS module the Wi-Fi code's software AES builds its lookup tables in RAM, while the TLS build keeps them in flash. `-d:bl808MbedTlsSoftware` (TLS without the crypto engines) is 19,468 bytes smaller in flash than the default and has the same RAM cost as `radioNoTls` plus 1,452 bytes, so its stack is 12 KB. `freenetradio.nims` also switches on the repository's SHA-1 engine provider for Wi-Fi key derivation (`bl808WifiMbedTlsSha1Hardware`), which the repository's other Wi-Fi images leave off by default.

### Host tests

The platform-independent logic (decoder, stream client, renderer, remote, presets, settings, web server...) is tested on the build machine:

```sh
for t in examples/freenetradio/tests/t_*.nim; do
  nim c -r --skipUserCfg --skipParentCfg --skipProjCfg --hints:off \
    --nimcache:build/nimcache_freenetradio_tests/$(basename $t .nim) \
    -o:build/freenetradio_tests/$(basename $t .nim) $t || break
done
```

Each prints `<name>: ok`. `t_stream_https` needs `openssl` on the PATH (it starts `openssl s_server` on a free local port with a throwaway certificate) and says it was skipped without it; it is the only test that touches the repository's Mbed TLS, which it builds for the host (software crypto: the engines exist only on the chip, and have their own tests against register-level fakes in `tools/test_tls_*_alt.py`). `tests/data/mp3/regen/` holds the scripts that made the MP3 fixtures; nothing builds or runs them.

## Flash

This needs nothing but the USB-serial adapter, wired as in Prerequisites. The repository's harness builds the image, loads a small flash programmer into the chip's RAM through the BL808's boot ROM, writes and verifies flash through it, and restarts the board into the radio. No vendor flashing tool is involved: the boot ROM's serial protocol is `tools/bl808_isp.py`, the programmer is `tools/uart_flash_anchor.c`.

1. **Find the adapter's port.** `ls /dev/cu.usb*` on macOS, `ls /dev/ttyUSB* /dev/ttyACM*` on Linux; unplug and replug the adapter if you are unsure which one it is.
2. **Start the harness.**

   ```sh
   export BL808_WIFI_SSID=<ssid> BL808_WIFI_PASSWORD=<password>
   .venv/bin/python tools/hw_validate.py --test freenetradio --rom-flash --uart <port>
   ```

   It builds `freenetradio` as listed in `tools/hardware_validation.json` (the defines of the Build section, with the network name and password from the environment), then stops and asks for the boot loader.
3. **Put the board in its boot loader when it asks.** The Ox64 has one button, BOOT, and no reset button, so "reset" means removing and re-applying power:
   - unplug the Ox64's USB power,
   - press and hold **BOOT**,
   - plug the power back in with BOOT still held,
   - release BOOT after about a second,
   - press Enter.

   The board stays in the boot loader until it is restarted, so there is no hurry.
4. **Wait.** It writes the boot loader's second stage, the partition tables and the firmware (at flash offset `0x10000`), about 870 KB in a minute or so at 230400 baud, reading each block back. It does not touch the presets and settings at `0x680000`. Then the programmer restarts the chip into the radio (BOOT is only read at power-up, so there is nothing to unplug), and the run passes once the console has printed `Serving on http://`. The console log is kept in `build/hw-validation/logs/`.

If it reports that the boot ROM did not answer, the board was not in the boot loader, or the port or wiring is wrong: check that adapter RX goes to GPIO14 and TX to GPIO15, and run it again. Nothing has been written at that point. To check only that the board is in its boot loader: `tools/bl808_isp.py probe <port>`. A failure part-way through leaves a board that will not start the radio but still enters the boot loader: run it again.

To update later, run it again. Presets and settings survive. Add `--nim-define radioDiag=1` for the diagnostics build, `--dry-run` to see what would be done.

The harness takes the second-stage boot loader from the vendor SDK checkout (`build/bl808-sdk-a05/bsp/board/bl808dk/builtin_imgs/boot2_bl808_release_v8.1.1.bin`, or the file `BL808_BOOT2` names); it is also where the RAM programmer's boot header comes from.

Status: this route was run on an Ox64 with the diagnostics build: the boot ROM loaded the programmer, about 880 KB were written and read back in 63 seconds, and the radio came up without a power cycle.

### With the vendor's tool instead

`tools/upload.sh` writes an image you built yourself (Build section) through the same boot loader with Bouffalo's `bflb-iot-tool`, which `make venv` (or `uv pip install -r requirements-hw.txt`) installs. Put the board in its boot loader as in step 3, then:

```sh
./tools/upload.sh m0 build/freenetradio.bin <port> 230400
```

It ends with "Flash complete!"; power-cycle the board without BOOT to start the radio.

### First boot

Watch the console on the same adapter, at 230400 baud:

```sh
.venv/bin/python -m serial.tools.miniterm <port> 230400
```

(`Ctrl-]` leaves it.) Within about twenty seconds of power-up it prints (among the Wi-Fi stack's own messages):

```text
[INF] === FreeNetRadio (BL808) ===
[INF] wifi: joined
[INF] wifi: address 192.168.1.114
[INF] Serving on http://192.168.1.114/
```

Open that address in a browser. If `wifi: joined` never comes, the name or password in the build is wrong or the access point is out of range (the BL808 is 2.4 GHz only): rebuild and flash again. Close the console before flashing: the script needs the port.

### With JTAG on the bench (optional)

The repository's hardware harness can build, flash and check the image without the BOOT button, for a bench with a JTAG adapter on the Ox64's J6 header. Follow the repository's `AGENTS.md`; the harness takes the hardware lock and keeps the logs. This example's entry in `tools/hardware_validation.json` is `freenetradio` (tier `manual`), with the defines of the Build section; the network name and password come from the environment:

```sh
export BL808_WIFI_SSID=<ssid> BL808_WIFI_PASSWORD=<password>
.venv/bin/python tools/hw_validate.py --list
.venv/bin/python tools/hw_validate.py --preflight --uart <port>
.venv/bin/python tools/hw_validate.py --test freenetradio \
  --uart-anchor-flash --uart-anchor-reset-after-flash --no-jtag-reset \
  --uart <port> --ftdi-reset-sudo --keep-going
```

Add `--nim-define radioDiag=1` for the diagnostics build, `--build-only` to build without touching the board, `--dry-run` to see what would be written. The run passes when the console has printed `Serving on http://`.

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
curl -d 'http://ice1.somafm.com/groovesalad-128-mp3' http://<address>/radio/play
curl -d 30 http://<address>/radio/volume
curl -X POST http://<address>/remote/ok
curl http://<address>/radio
curl -s http://<address>/screen | \
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
- **Buffers are deeper** than upstream's, because Wi-Fi is not wired Ethernet and its stack shares the processor with the decoder (`freenetradio.nims`). The DAC queue is 12,288 frames (279 ms at 44.1 kHz) instead of 4,096: on this chip the decoder regularly waits 50 to 150 ms for its turn, which emptied a 93 ms queue about once in ten minutes. The audio task also decodes up to three frames without yielding when less than 78 ms is queued. The stream buffer is 64 KB instead of 10 KB; playback still starts at upstream's level, and the rest (four seconds at 128 kbit/s) carries the radio through a pause in reception. Volume and equaliser changes are heard a quarter of a second later than upstream, and the level meters lead the sound by as much. The host tests run at upstream's sizes.
- **Display SPI** uses the HAL's bulk SPI DMA path to feed the SPI0 FIFO from the 8 KiB framebuffer. The HAL claims a DMA channel for the transfer and reports completion once the SPI bus goes idle. The display checks completion on its existing frame timer and then releases chip select. A frame that misses its 100 ms deadline is dropped and the next one starts afresh, as upstream.
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

### From the host over JTAG

With the Ox64 JTAG pins routed to M0, sample a running build using the
T-Head hardware PC sampler. A matching ELF supplies function names.

```sh
.venv/bin/python tools/hw_validate.py --jtag-live-profile 30 \
  --jtag-profile-elf build/hw-validation/bin/freenetradio/kernel.elf
```

This uses a TAP-only OpenOCD session. The MCU keeps running during attach
and capture. It works on builds with no profiling option, needs accessible
M0 JTAG, and saves the individual samples and a hotspot table in
`build/hw-validation/logs/jtag-live-profile.json`. Use `--work-dir` to
keep separate runs and `--jtag-profile-rate` to change the requested rate
from 30 Hz. Omit the ELF to record addresses alone.

The hardware reports the most recent branch destination, so samples taken
while idle can repeat the same address and tight loops can be overrepresented.
Use the counts to locate potential hotspots. Sample shares are approximate,
especially for WFI and straight-line code. See table 5.3 in the
[E907 manual](https://bbs.aw-ol.com/assets/uploads/files/1658215723286-%E7%8E%84%E9%93%81e907-r1s1%E7%94%A8%E6%88%B7%E6%89%8B%E5%86%8C_occ.pdf#page=61).

### D0 from the M0 observer

The M0 observer reads the C906 retire monitor and sends samples over UART0.
For a bench check, load the observer and the D0 test workload into RAM, then
collect a profile with the matching D0 ELF. Set `UART_PORT` to the runtime
serial device.

```sh
.venv/bin/python tools/hw_validate.py --test d0_profile_observer \
  --jtag-load --no-jtag-reset --uart "$UART_PORT"
.venv/bin/python tools/hw_validate.py --d0-live-profile 10 --profile-rate 100 \
  --profile-elf build/hw-validation/bin/d0_profile_observer/d0.elf \
  --uart "$UART_PORT"
```

The RAM load uses JTAG and temporarily replaces the running M0 and D0 images.
Capture runs over UART while D0 executes. `logs/d0-live-profile.json` contains
the 40-bit PCs, raw status, and hotspot shares. Halted and zero-address samples
are retained in the report and excluded from hotspot shares. While D0 is
idle, the monitor can repeat the last retired PC.

Add `--profile-hpm` to include cycles, retired instructions, L1 instruction
and data cache accesses and misses, conditional branches and mispredictions,
and I-uTLB, D-uTLB, and joint TLB misses. The test workload enables counters
and exercises Sv39. Other D0 images can opt in by calling `enableHpm` at boot
in machine mode and passing its configuration and a persistent request
sequence variable to `serviceD0Hpm` from a periodic hook. For a
supervisor hook, enable supervisor reads at boot with `allowSupervisor = true`,
identity-map XRAM uncached, and pass `supervisor = true` to the hook. Reserve
XRAM offsets `0x3b00`–`0x3bbf` for the mailbox. The counters cover the whole
capture window and can include scheduling and interrupt work. Use PC-only
capture for D0 images without the counter hook.

On C906 configurations with eight event slots, the default group includes
the TLB events. To capture data-cache activity on those configurations,
RAM-load the example with `--nim-define bl808D0ProfileDataCache=1`, or pass
`preferDataCache = true` to `enableHpm` in your D0 firmware. Both groups
include cycles, retired instructions, I-cache, and branch events. The report
includes only events that the firmware configured successfully. See
[C906 HPM, chapter 12](https://cs107e.github.io/readings/XuanTie-OpenC906-UserManual.pdf).

### Cycle counts and audio timeline

Add `--nim-define radioProfiler=1` to the normal harness build and flash
command. This flag works on its own, with release optimization and without
`radioDiag`. The profiler starts on request and stops automatically.

```sh
python3 examples/freenetradio/tools/profile_radio.py capture http://192.168.1.114 \
  --seconds 30 --out build/hw-validation/logs/radio-playing
```

The command prints call counts, wall time, cycles and retired instructions
per region and interrupt vector, plus audio wake delays, the DAC queue
low-water mark and WFI time. It saves the binary capture, a summary JSON
file, and a Perfetto JSON
file for runs with tracing enabled. Open the latter in
[Perfetto](https://ui.perfetto.dev) to see the audio wake, rendering, Wi-Fi
and IRQ tracks. Decode a saved capture again with
`profile_radio.py analyze <file.bin>`.

The recorder retains the newest 2,048 events in RAM. The first playback wake
that is at least 15 ms late, or the first underrun, freezes that history.
Counters continue through the end of the window. Set `RadioProfileLateUs` at
build time to change the trigger threshold. Use `--summary-only` for work
comparisons without timeline writes. Board controls are
`POST /profile/start` or `POST /profile/start-summary` (decimal milliseconds,
100–120,000, default 30,000), `POST /profile/stop` for an early stop, and
`GET /profile/capture` for the completed capture. The opt-in build exposes
these routes to hosts that can reach the radio.

The scope totals include nested calls and any interrupt time within the
scope. Compare them individually. A Wi-Fi firmware call with work dispatched
an event. A deferred TX call with work sent at least one frame. A posted
Wi-Fi service call may still find an empty queue. Audio sleep delay is
measured from the requested timer deadline, and yield delay from the time the
audio task posts its continuation. Percentiles are histogram upper bounds.
IRQ totals cover registered handler bodies. WFI is measured with the wall
timer.

The opt-in M0 capture also reports whole-window hardware counters for cycles,
retired instructions, L1 instruction and data cache accesses and misses,
conditional branches, and conditional branch mispredictions. The report lists
the events that the firmware configured successfully. The decoder can still
read older captures. See [E907 HPM, §5.2](https://bbs.aw-ol.com/assets/uploads/files/1658215723286-%E7%8E%84%E9%93%81e907-r1s1%E7%94%A8%E6%88%B7%E6%89%8B%E5%86%8C_occ.pdf#page=62).

For a meaningful before-and-after comparison, repeat runs on the same board
with the same network and fixed MP3 input. Record both connected idle and
playback. To estimate the extra cost of trace writes, compare WFI and audio
wake delays in summary-only and trace runs. The existing `radioCpuMeter`
build can provide a WFI baseline with the profiler disabled.

## Bring-up checklist

Nothing here has been run on hardware. Check, in this order:

1. The chosen GPIOs are on the Ox64 header as wired, and the SPI data pad direction (`-d:radioOledSpiSwap -d:OledSdinPin=26` otherwise): the vendor sources disagree about which of the two data pads is the master's output.
2. The firmware boots to `Serving on http://`. The linker profile (`bl808_m0_wifi_app.ld`) has only been linked: the radio's globals and its 1 MB heap are in PSRAM, and `main` zeroes the one and sets up the other before anything uses them.
3. Wi-Fi joins and gets an address. The Wi-Fi code now runs on the repository's Mbed TLS 3.6 (it was 2.28), and that has not associated on hardware yet either; check a known-good Wi-Fi example first if the radio does not join.
4. DMA0 reads the I2S ring from PSRAM correctly after `dcacheCleanRange`, one word per request (`i2s.enableDmaTx`, `dma.buildLli` with a burst of 1). The fallback is to put the ring and the DMA list in the 13 KB of uncached RAM at `0x2204_CC00` that this firmware leaves unused (the D0 SD-host and SD DMA windows of the linker profile): build with `-d:radioRingAddress=570739712 -d:radioRingFrames=3072` (the address in decimal). That variant has been built but, like the rest, not run.
5. The I2S clock tree: the actual sample rates at 44.1 and 48 kHz, and the framing (`i2s.initI2s`: Philips, 16 bits in 32-bit slots; the block is left off until the clock and the DMA ring are ready). The audio PLL is reprogrammed by `glb.configAudioPll`, for a 40 MHz crystal, on the assumption that nothing else (in particular the M0's own clock) runs from that PLL; its settling delays are a counted loop, not a timer.
6. An `https://` stream plays. With `-d:radioDiag`, read the `tls handshake` time and the `stack:` line of `/stats` afterwards (every task and the whole TLS handshake share one stack), and `GET /selftest/crypto`: for each crypto engine, its state and how many operations ran on hardware and in software. State 2 means the engine passed its first-use comparison with software and is in use; 3 means it failed and was retired. `GET /selftest/bench` times each engine against software. `-d:bl808MbedTlsSoftware` (or one of the per-engine defines in `src/bl808/mbedtls/build.nim`) turns the engines off if one misbehaves.
7. The stream keeps up at 320 kbit/s. If one stalls where a 128 kbit/s stream does not, look at the receive window in a packet capture first: it should open at 10240 bytes (2920 means the build did not read `freenetradio.nims`).
8. The display. Confirm it refreshes in SPI mode 0. Check `display frames` and `flush timeouts` in `/stats` while the screen animates. Each flush should finish within 100 ms, including when a preset is saved during playback.
9. Whether a 4 KB sector erase (interrupts off, about 45 ms) is audible. It happens on one settings save in sixteen and on preset saves.
10. Flash `0x680000..0x6FFFFF` is unused in the board's image layout, and presets and settings survive a power cycle: they are read back with `flashReadRaw`, which is new.
11. The IR receiver: the GPIO interrupt keeps firing after the first edge (`gpioClearInterrupt` pulses the latch's clear bit).
12. How long `wifiInit()` delays the boot animation.

## For the HAL

The gaps this example first worked around are closed in the HAL, and the example now uses the HAL for them: the lwIP client bindings and the TCP window, I2S with the audio PLL and the DMA ring, SPI0 with DMA and the GPIO setup, raw flash reads and the application-data partition, the Wi-Fi application linker profile, TLS's two kinds of "closed", and the validation manifest entry.

Still open, and still worked around here:

1. Module initialisers only run inside `wifiInit()` (`src/bl808/startup.nim` says why startup cannot run them), so every module here has an explicit init and `main` starts the network first.
2. The Wi-Fi facade has no "link lost" event; `net_task.nim` polls the association and the WPA state.
3. lwIP's `TCP_WND` is set with a C compiler flag, which the validation manifest's defines cannot carry; hence `freenetradio.nims`.

Found on the way and fixed too, though not used here: the FIFO DMA request enables in `src/bl808/uart.nim` and `src/bl808/i2c.nim` were exchanged (the vendor headers have TX at bit 0 and RX at bit 1, as in `i2s.nim` and `spi.nim`). Code that turns on both directions, as everything in the repository does, sees no change.

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
