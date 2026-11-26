# BL808 Wi-Fi Channel Coverage

Channel 11 was chosen to investigate drops from Frog, not to qualify the
radio. The [BL808 datasheet](https://files.pine64.org/doc/datasheet/ox64/BL808_DS_en_1.1%28open%29.pdf)
identifies a 2.4 GHz 802.11b/g/n radio. The default Nim `US` channel plan
admits channels 1-11. The message builders also know plans that include
12-13 and the distinct 2484 MHz center frequency for channel 14. Encoding
a frequency in a message is not evidence that the radio works there.

| Channel | Center (MHz) | Scan request fixture | Ox64 station evidence |
| --- | ---: | --- | --- |
| 1 | 2412 | US, EU, CN, JP | Pending |
| 2 | 2417 | US, EU, CN, JP | Pending |
| 3 | 2422 | US, EU, CN, JP | Pending |
| 4 | 2427 | US, EU, CN, JP | Pending |
| 5 | 2432 | US, EU, CN, JP | Pending |
| 6 | 2437 | US, EU, CN, JP | Earlier firmware joined Frog and passed DHCP and traffic |
| 7 | 2442 | US, EU, CN, JP | Pending |
| 8 | 2447 | US, EU, CN, JP | Pending |
| 9 | 2452 | US, EU, CN, JP | Pending |
| 10 | 2457 | US, EU, CN, JP | Pending |
| 11 | 2462 | US, EU, CN, JP | Current image joined Frog, served HTTP, and transmitted on air |
| 12 | 2467 | EU, CN, JP | Not enabled by the default plan; pending permitted bench test |
| 13 | 2472 | EU, CN, JP | Not enabled by the default plan; pending permitted bench test |
| 14 | 2484 | JP | Native tuning modeled; no on-air evidence or qualified rate/mode profile |

The scan fixture runs the production country-plan and request builders.
It checks the default list, an explicitly reversed full list, each single
channel, and rejection before allocation when the list is missing or a
channel is absent from the selected plan. A scan without a BSSID uses the
broadcast address. AP start and station join replays cover 1-11, plus
rejection before setup or
join handoff. The station replay also passes channels 12-13 with a fixture
that admits them. These are host results, not radio qualification. Hardware
observations above are from [the vendor comparison notes](bl808_vendor_blobs.md)
and the [connected-scan bench](wifi_connected_scan_ab.md).

Native BL808 tuning is broader than the default channel plan. In the BL808
demo PHY archive (`libbl606p_phyrf.a`, Git blob
`a9935b475d2198000ae7b67d141f00767176a81a`),
`phy.o:phy_set_channel+0x90` passes the center frequency to RF;
`rfc.o:rfc_config_channel+0x38..0x4a` writes the MHz field and starts the
tune sequence. `rfc.o:rfc_init+0x70e..0x74a` explicitly configures the
2484 MHz VCO entry. The native Nim retune fixture checks the write and
strobe sequence for all 14 centers. Neither the register write nor the
calibration entry proves a usable link. In particular, tuning to 2484 MHz
does not switch the MAC to a DSSS/CCK-only rate set; the ordinary AP rate
list still includes OFDM. Keep channel 14 out of automatic TX sweeps until
a dedicated rate profile and peer can be verified.

In the pinned disassembly, `apm_task.o:apm_start_req_handler+0xb4`
reserves a channel context before the lookup at `+0xca`. Nim now rejects
unconfigured frequencies before either step can start AP setup. The vendor
host discards an out-of-plan station hint; the firmware's direct handoff at
`sm_task.o:sm_connect_req_handler+0x1c2` does not check an explicit hint
against the plan. Nim rejects the invalid explicit request at both entry
points instead of quietly joining on a different channel. Channel `0`
still requests normal station selection.

## Hardware Gate

Use a configurable, isolated 2.4 GHz test AP with a unique SSID so the
Ox64 cannot silently join another AP. Keep Frog unchanged. Sweep channels
1-11 at 20 MHz first. For each row use the same candidate image, board,
AP, and workload; record image identity, selected channel and center
frequency, and the observed AP identity. A row passes only when it
discovers the AP, joins, obtains a nonzero DHCP address, serves
bidirectional traffic, and repeats those checks after a local disconnect.
Verify the actual channel, not just the requested value. Record failure
stage and retry counts instead of inferring a failed join from no address.
The standalone HTTP startup marker matches observations delivered during
the join to the joined BSSID and exact SSID. The scan ring has no receive
timestamp, and a warm join can add a cached beacon to it. For a cold row,
start with an empty firmware scan cache. For warm reconnects, compare the
successful connect indication's primary frequency (labeled `center_freq`
in the existing UART log) and BSSID against the requested peer. Use an
independent capture to verify the on-air frequency; a fresh host-side scan
row by itself does not qualify it.
The `allcore_wasm_http_manager_test` image accepts `--nim-define WifiChannel=N`
for directed station coverage; use a bench SSID and keep its password out
of logs. Leave `WifiChannel=0` when exercising automatic selection.

Qualify the Ox64 AP role separately: start the setup AP on each channel,
observe its beacons at the expected frequency, then join it from a client
and check DHCP and local HTTP in both directions. Use `tools/hw_validate.py`
and the bench's reserved flash layout for image changes. The
`m0_wifi_ap_http_smoke` test accepts `--nim-define WifiApBenchChannel=N`
for channels 1-11; it defaults to 11. Run channels
outside the default plan only on a fixture where that profile and mode are
permitted; changing the country string is not itself a hardware test.

### One-image AP sweep

`m0_wifi_ap_channel_sweep` is a separate manual manifest target. It uses the
bench password environment variable `BL808_WIFI_AP_BENCH_PASSWORD`, never
the station password. After `--build-only` and `--dry-run`, use the UART
anchor flow in `AGENTS.md` once the bench is available. The image starts at
`Ox64-Sweep-Bench-ch01` and waits until the client confirms that row. Run
the client on the AP interface, not through Frog.

1. Record the advertised SSID, BSSID and independently observed center
   frequency. Join that SSID and record the offered DHCP address.
2. Fetch `GET /bench/channel/N` at `192.168.11.1`. Require HTTP 200 and
   `channel=N`; `N` is decimal without zero padding. For example:
   `curl --http1.1 -fsS http://192.168.11.1/bench/channel/1`.
3. After verifying the row, send `POST` to the same URL with
   `curl --http1.1 -fsS -X POST http://192.168.11.1/bench/channel/1`.
   Require HTTP 202 and `advance=1`. The board waits one second, restarts
   DHCP and the AP, and retains the HTTP listener on the same address.
4. Wait for the next `event=ready` UART record and repeat. The firmware
   emits its final pass only after channel 11 has been confirmed and
   stopped. A `client_confirmed` record means the client sent the explicit
   POST; pair it with the client-side records to qualify the RF row.

This is one bounded sweep per boot, not a restart soak. The pinned
`lwip_dhcpd/dhcp_server_raw.c` stop routine removes its socket and server
record but does not free the server's lease-node list.

### First channel 1 run

On 2026-11-23, a verified UART-anchor write replaced only M0. Three
ordinary Mac scans and one targeted scan found no `Ox64-Sweep-Bench-ch01`.
The M0 memory log showed `[FAIL] AP startup`. The command returned
`-ETIMEDOUT`: the setup callback took 300,027 us and the command took
305,396 us, with nothing recorded in the beacon DMA trace. This is a
startup deadline failure; it did not exercise channel 1 over the air.
The logs are in `build/hw-validation-wifi-ap-channel-first-live/logs/`.
The previous M0 image was restored through the anchor; HTTP at
`192.168.1.114` reported healthy M0, D0 and LP afterward.

Keep key setup within the timed AP command for the hardware comparison.
The standard AP image uses the software backend. Build
`m0_wifi_ap_http_smoke` with `--nim-define bl808WifiMbedTlsSha1Hardware=1`
for the hardware comparison. The hardware build links Mbed TLS's regular
derivation and stream functions with a BL808 block provider, without
precomputing the key or wrapping the derivation. It checks a non-default
chaining state against the software block function of the vendored
Mbed TLS 3.6.8 (`vendor/mbedtls`) before using
hardware and requires no fallback during the timed bench command.

The first channel 1 hardware comparison on 2026-11-23 passed the provider
self-check and used 32,769 hardware blocks, zero software blocks, and zero
engine timeouts. The AP callback took 1,406,441 us and the command took
1,411,723 us. The AP command returned `-ETIMEDOUT` before beacon DMA.
This verifies hardware execution through Mbed TLS, not AP readiness or
the 200 ms budget. The anchor's reboot acknowledgement timed out, but
the new image's markers and counters were read on the running board.
See `build/hw-validation-wifi-mbedtls-sha1-hardware-live/logs/`.

For a diagnostic image, add
`--nim-define bl808WifiMbedTlsSha1Profile=1` and read five words at
`nim_mbedtls_sha1_profile`: measured blocks, total setup microseconds,
total post-trigger wait microseconds, total cleanup microseconds, and
maximum post-trigger wait. Keep these measurements separate from the
uninstrumented AP timing above. `ap_m0_cycles` and `ap_observed_us` bracket
the same AP call to measure the effective M0 clock in that run.

The first diagnostic run recorded 32,770 provider operations, including
the known-answer check. Setup took 433,908 us, post-trigger wait took
49,212 us (maximum 8 us), and cleanup took 868,538 us. The full AP
command timed out at 1,575,710 us. The linked provider called byte-loop
`memcpy` and `memset` for its DMA buffers. The driver now writes the same
bytes with aligned word stores and places its hardware operation in
`.ramfunc.sha1` on the Wi-Fi HTTP image. It still wipes all 136 scratch
bytes after each completed request and retains the timeout and fallback
behavior. The profile capture is in
`build/hw-validation-wifi-mbedtls-sha1-profile-live/logs/`.

The uninstrumented word-DMA/OCRAM run completed the same 32,769 hardware
blocks with zero fallback and zero engine timeouts. Its AP callback took
854,778 us and the command took 929,868 us, down from 1,411,723 us for the
previous uninstrumented hardware build. The command still timed out; no
channel 1 AP pass is claimed. Radare2 showed the hardware routine at
`0x62020000`, with no calls to the flash-resident copy or wipe routines.
See `build/hw-validation-wifi-mbedtls-sha1-word-dma-live/logs/`.

#### Detached startup profile

The anchor's JTAG acknowledgement polling continued after reboot into the
AP image. With that polling, the word-DMA/OCRAM profile timed out at
1,221,591 us and recorded a single post-trigger interval of 109,925 us.
Do not use that run or the earlier attached runs as clean timing baselines.

Rebooting the **same flashed image** with no JTAG attachment after the
UART reboot request changed the result. The full command still timed out,
but at 398,377 us. Hardware completed all 32,769 application blocks with
zero fallback and zero timeout. The profile includes one extra operation
for the initial known-answer check:

| Phase | Time (us) |
| --- | ---: |
| Driver setup | 48,843 |
| Wait after trigger | 48,711 (maximum 2 us per operation) |
| Driver cleanup | 61,072 |
| Remaining time in key setup | 234,847 |
| AP command outside key setup | 4,904 |
| Complete timed command | 398,377 |

The remaining key setup time includes Mbed TLS, the block wrapper, libc,
and profile bookkeeping not included in the three sums. It is not a
function-level attribution. M0 recorded 127,933,959 cycles in 399,794 raw
timer ticks. The HBN root selects PLL, PDS selects Wi-Fi PLL 320 MHz, and
HCLK is undivided. The M0 timer is enabled with divider `0x13f` (/320),
confirming a 1 MHz timer with M0 already at 320 MHz. The cache enable
register was not readable in this JTAG capture.

Use detached boots for future comparisons: verify the SRAM anchor and
JEDEC ID, detach JTAG while the anchor is running, send the UART-only
reboot frame without polling memory for its acknowledgement, then attach
once after startup. Keep the instrumented and uninstrumented runs separate.
The capture is in
`build/hw-validation-wifi-mbedtls-sha1-word-dma-profile-live/logs/`.

At this workload size the command has about 5.95 us per application
block after its other AP work. With about 1.49 us of engine wait, that
leaves about 4.47 us per block for all other work. First A/B code placement
for the existing Mbed TLS derivation, HMAC and SHA-1 stream functions and
their repeated libc calls; the word-DMA provider alone is already in OCRAM.
If needed after that, measure the register work saved by an exclusive,
bounded SHA-engine lease over the standard operation. Do not bypass
Mbed TLS, omit blocks, or relax the deadline for these comparisons.

#### Detached OCRAM placement A/B

Both channel 1 images used the same bench credentials and standard
Mbed TLS call path with `-d:bl808WifiMbedTlsSha1Hardware=1`, without
per-block profiling. The only A/B flag was
`-d:bl808WifiMbedTlsHotOcram=1`: it links the hot Mbed TLS derivation,
digest and SHA-1 stream functions, the provider entry, and the existing
libc copy/fill routines into OCRAM. The engine driver itself was already in
OCRAM in both builds. ELF and startup checks verified the placement of
15 symbols, that the normal Mbed TLS derivation is still called, and that
startup copies the code before calling it. The candidate added 1,960
bytes of OCRAM and left 5,928 bytes above the link-time stack guard.

After each verified M0-only flash, the harness closed OpenOCD and the
RAM anchor was sent the reboot frame over UART. JTAG attached only after
startup to read the result.

| Image | Key setup (us) | AP command (us) | Hardware / software blocks | Engine timeouts |
| --- | ---: | ---: | ---: | ---: |
| Flash-resident Mbed TLS hot path | 395,861 | 400,730 | 32,769 / 0 | 0 |
| OCRAM-resident Mbed TLS hot path | 212,398 | 217,630 | 32,769 / 0 | 0 |

Moving the hot path saved 183,100 us (45.7% of total command time).
The command still returned `-ETIMEDOUT` before beacon setup in both
images, so this is not a channel 1 AP pass. The candidate needs more
than another 17,630 us of savings, or about 0.54 us per block, to
clear the 200 ms threshold on this workload. That is the measured
shortfall, not a worst-case margin.

Re-profile the OCRAM candidate to attribute the remaining time. The
previous detached driver profile suggests testing a bounded, exclusive
engine lease across the standard Mbed TLS call, with an owner check and
saved engine configuration at entry, bounded polls per block, and
restore and scratch wipe on exit. Prove that all engine users honor
ownership, that interrupts are not held off for the whole operation,
and that timed-out DMA buffers remain untouched until DMA stops. Keep
the same Mbed TLS operation and verify the result repeatedly with
the all-core image before enabling the change by default.

See `build/hw-validation-wifi-mbedtls-ocram-ab-baseline/logs/detached-timing.*`
and `build/hw-validation-wifi-mbedtls-ocram-ab-hot-ocram/logs/detached-timing.*`.

#### OCRAM driver phase profile

Rebuilt the channel 1 OCRAM candidate with
`-d:bl808WifiMbedTlsSha1Profile=1` and measured after a detached boot.
The application used 32,769 hardware blocks, with no software fallback
or engine timeout. Driver phase sums include one extra block for the
initial known-answer check.

| Phase | Time (us) |
| --- | ---: |
| Driver setup | 47,870 |
| Wait after trigger | 49,159 (maximum 2 us per operation) |
| Driver cleanup | 61,550 |
| Other key setup time, including unaccounted profile work | 58,857 |
| AP command outside key setup | 5,219 |
| Complete timed command | 222,655 |

Key setup took 217,436 us. The independent call bracket measured
71,785,870 M0 cycles in 224,331 timer ticks (320 MHz). Use the
uninstrumented 217,630 us command as the deadline comparison.

Radare2 and the original map showed that the OCRAM digest functions
still loaded their dispatch tables and descriptors from flash. An
uninstrumented trial verified these data inputs in OCRAM and measured
217,704 us total, with the same block counts and no engine timeouts.
Both trials returned `-ETIMEDOUT` before beacon setup. The 74 us
difference did not show a useful saving, so the additional linker
placement was removed. See
`build/hw-validation-wifi-mbedtls-hot-ocram-profile/logs/detached-timing.*`
and `build/hw-validation-wifi-mbedtls-hot-ocram-data/logs/detached-timing.*`.

The next bench comparison should lease the engine to one Mbed TLS digest
context at a time, keeping the standard call, per-block completion
checks, and DMA ordering intact. Keep scratch private and writable
through lease exit; scrub it and restore the saved configuration only
after DMA is idle. Contention must not retire the backend, and a stalled
DMA must quarantine both the engine and scratch. The pinned vendor
`hostapd_derive_psk` and `hostap_init` ignore the status of their key
setup calls; propagate failure into the Nim AP rollback before enabling
an early deadline abort. No all-core timing or AP readiness is established.

#### Standalone AP with a context-scoped engine lease

Add `-d:bl808WifiMbedTlsSha1Lease=1` to the standalone AP build with
`-d:bl808WifiMbedTlsSha1Hardware=1 -d:bl808WifiMbedTlsHotOcram=1`.
Leave per-block profiling off for the deadline test. This path is not
enabled by default in the all-core image; see the build-only gate below.

The bridge passes the unchanged arguments to stock Mbed TLS. The Nim
provider binds the engine to that digest context, leaves IRQs in their
previous state during block processing, and checks completion before
committing every block. It restores configuration and wipes DMA scratch
once at release. A busy timeout quarantines the engine and scratch
until reset. The AP gate checks the true result even if the SDK callback
returns a partial context, and uses the existing rollback before beacon
setup. The lease has a 193 ms internal bench cutoff; the command budget
remains 200 ms.

After a verified M0-only flash and detached reboot, channel 1 passed
the RFC 6070 known-answer check before starting the timer. The timed
AP command took **186,592 us** (key setup **178,424 us**) and finished
**13,408 us** before the 200 ms deadline. This was **31,038 us** faster
than the code-placement-only run, which timed out before beacon setup.
The timed call used all 32,769 hardware blocks, with zero software
blocks and zero engine timeouts. AP firmware, netif, and DHCP ready
markers appeared, the beacon DMA trace advanced, and the HTTP loop ran.
There was no client join or HTTP request in this run.

The focused host tests cover owner mismatch, bounded completion,
deadline expiry across timer wrap, safe cleanup and busy-DMA quarantine,
and AP rollback even when the callback returns a non-nil context.
Hardware capture:
`build/hw-validation-wifi-mbedtls-sha1-lease/logs/detached-timing.*`.
This is one physical startup, not a worst-case bound, all-channel
qualification, or a pass under all-core load.

#### All-core engine bench: build-only gate

Fix the CPS frame-local type visibility for `AllcoreLinkDrop` without
enabling diagnostics in the default build. The default and explicit
link-drop diagnostic builds now link. The opt-in
`bl808AllcoreWifiApEngineBench` build starts and stops a temporary AP
before normal station startup. It also checks the known-answer result,
the 200 ms command budget, all hardware block counts, and advancing D0
and LP heartbeats. It needs the AP timing, hardware provider, OCRAM and
lease flags used above, plus an `AllcoreApBenchPassword` fixture.

The linked DMA objects are at `0x2204EC00` and `0x2204EC40` in the
reserved 1 KiB WRAM page, disjoint from D0 SD DMA, WLAN buffers and the
all-core RAM code bank. The driver checks the WRAM range and group
fields and the SHA block ownership. It explicitly initializes the
NOLOAD scratch after the engine is known idle. The linked RAM code bank
uses 3,992 of 4,096 bytes, and the stack guard has 1,020 bytes of extra
headroom beyond its required 1 KiB. The host tests cover incorrect
group/range, overlapping windows, and ownership denial. They do not
prove that the engine or specific peer bus masters see the intended
permissions on the real board.

Do not flash the ordinary compiler-mode builds on the retained LP layout. With M0 at
`0x10000` and LP at `0xE0000`, the maximum wrapped M0 image is
851,968 bytes. The ordinary link produced the following boot2 images:

| Build | Wrapped bytes | Exclusive erase end |
| --- | ---: | --- |
| Default all-core | 856,672 | `0xE2000` |
| All-core link-drop diagnostics | 855,680 | `0xE1000` |
| All-core AP engine bench | 869,360 | `0xE5000` |

The AP bench flag now selects `-Oz -fcrossjumping` on M0 only. The
size-optimized harness build wrapped to 838,144 bytes, ending its erase
range at `0xDD000` with 12 KiB left before LP. The LP and D0 images
also fit at `0xE0000` and `0x100000`. M0 uses 3,936 of 4,096 bytes
in its RAM code bank and retains 1,020 extra bytes beyond the stack
guard. The regular all-core build still uses its original compiler
options. See
`build/hw-validation-allcore-mbedtls-ap-lease-size/` and
`build/hw-validation-allcore-mbedtls-ap-lease-size-dry-run/`.

Read back the WRAM and SHA settings on the board and check
access from real peer contexts before relying on this policy. The
all-core dev image is not locked; a group-0-only window does not
automatically rule out every other bus master. This stage did not
reflash or reset the working Frog image.

#### All-core engine bench: detached hardware result

The synthetic-credential image wrapped to 838,192 bytes and erased no
farther than `0xDD000`. Only M0 was written; the peer flash slots and
their boot configuration were not changed. Boot was initiated over UART
with OpenOCD closed, and the snapshot was taken after the timed request.

| Measurement | Result |
| --- | ---: |
| Whole AP command, including failed confirmation | 199,982 us |
| Key setup callback until return | 194,647 us |
| Hardware blocks completed before the cutoff | 3,605 of 32,769 |
| Fallback blocks / engine timeouts | 0 / 0 |
| D0 / LP heartbeat increments during the call | 4,714 / 56 |

The Mbed TLS hardware known-answer check passed before the command. The
193 ms internal lease cutoff stopped the derivation, and the AP handler
returned a failure confirmation at firmware stage 7. It did not reach
beacon setup. The total command time alone is not a pass. The M0 and
enclave smoke statuses and both peer smoke statuses were OK; the deltas
show peer progress during this one call, not a workload or timing bound.

WRAM R0 read back as `0x013B013B`, enabled with group-0 instruction
and data permissions; the SHA block also read back as group-0 owned.
This proves the programmed settings and successful engine access by
M0, not denial of access from each peer or DMA master.

The observed callback time per completed block was about 54.0 us,
versus 5.45 us in the successful standalone run. Both runs selected the
same M0 PLL and timer divider. Radare2 shows that the all-core hot code
executes from non-cached WRAM at `0x2204F000`, versus cached OCRAM in
the standalone build. The leased block body is nearly the same size,
and both binaries still call XIP helpers for block packing and byte
swapping. These are placement and bus-contention hypotheses; use the
lease phase profile to separate work before trigger, accelerator wait,
and cleanup from remaining callback time before choosing the next A/B.

See `build/hw-validation-allcore-mbedtls-ap-lease-live/logs/allcore-ap-detached.*`.

#### All-core lease phase profile

The detached, M0-only profile run completed 3,535 AP blocks before the
lease cutoff, with zero fallback and engine timeouts. The timed AP
callback returned after 194,641 us, and its failed command took
199,970 us. Both peer heartbeat counters advanced. The driver phase
counters also include nine leased blocks from the known-answer test:

| Phase | Total (us) | Mean per profiled block (us) |
| --- | ---: | ---: |
| Driver setup | 24,163 | 6.82 |
| Trigger-to-completion wait | 9,205 | 2.60 |
| Driver cleanup | 19,182 | 5.41 |

The maximum trigger-to-completion wait was 3 us. Subtracting the three
phase sums from the AP callback leaves 142,091 us (73%); this is an
approximate residual since the sums include the small known-answer test.
It includes Mbed TLS, wrapper and libc work, instrumentation overhead,
and anything else outside the three phase brackets. It does not identify
a particular helper or prove where the remaining cycles stall.

The live profile image wrapped to 838,272 bytes and its erase range
ended at `0xDD000`. See
`build/hw-validation-allcore-mbedtls-ap-lease-profile-live/logs/allcore-ap-detached.*`.
The preceding Frog M0 image was restored and the M0, D0, LP, and enclave
status entries were read successfully over HTTP.

#### Cached WRAM placement A/B: detached hardware pass

Add `-d:bl808WifiMbedTlsCachedWram=1` to the all-core AP lease bench.
The experimental linker fragment takes only the previously RAM-resident
Mbed TLS/provider code and its copy/fill helpers into the cached alias
from `0x6204F440`. The startup loop copies the image from flash through
uncached `0x2204F440` and synchronizes instruction fetch before `main`.
The flash-service code remains in uncached WRAM, and the DMA descriptor
and input block are unchanged. Keep this opt-in. Read
`allcore_ap_mhcr` at the snapshot to confirm that `MHCR.IE` was enabled
immediately before the timed call. This option does not enable a
disabled cache or change the Mbed TLS workload, hardware driver, or
deadline.

The synthetic-credential candidate wrapped to 838,336 bytes, with erase
end `0xDD000`. Only M0 was written. On a detached channel 1 boot, the
AP startup command succeeded in **189,020 us**, of which **177,497 us**
was key setup. This leaves **10,980 us** before the 200 ms deadline.
All 32,769 timed blocks used the engine, with zero fallback blocks and
zero engine timeouts. D0 and LP heartbeats advanced by 4,386 and 51.
The bench then stopped the AP and continued to the synthetic station
scan without trying to join Frog.

The M0 snapshot reported `MHCR=0x0000103F` before the AP call, with
instruction caching enabled. Reading the uncached copy after timing
matched all 2,852 bytes against the ELF. Clock and timer settings and the
SHA DMA aperture readback matched the prior all-core run. The cached
layout met the deadline in this run; the earlier uncached layout hit
the cutoff after only 3,605 hardware blocks. Neither run establishes a
worst-case bound, client discovery, channel coverage, or peer DMA access
denial. The linked block packing and byte swapping helpers remain in
flash, as do Mbed TLS's digest descriptor and jump tables. Those are
placement candidates only if further measurements show a need.

See `build/hw-validation-allcore-mbedtls-ap-lease-cached-wram-live/logs/allcore-ap-detached.*`.
The previous Frog M0 image was restored after the test.

The existing `m0_wifi_ap_channel_sweep` also builds with the same
hardware provider and lease. Its standalone wrapped M0 image is 575,072
bytes, with erase end `0x9D000`. This is build-only evidence; the client
sweep on channels 1 through 11 has not yet been run for this build.

#### Attribution of the uncached all-core timing gap

Re-ran the uncached all-core diagnostic with
`-d:bl808WifiMbedTlsSha1Profile=1 -d:bl808AllcoreWifiApPcProfile=1`.
The sampler used the otherwise unowned Timer0 match channel, not the
kernel's machine timer. It kept 804 of 848 timestamped PCs inside the
194,684 us key callback. No samples overflowed; inter-sample gaps were
156/241/1,117 us (min/median/max). The sampling ISR body measured 67 us
in total, excluding the trap wrapper. The request still returned
failure after 3,489 hardware blocks, with zero fallback or engine
timeouts. This is a profile of the slow build, not a deadline test.

Direct timers measured 24,275 us in driver setup, 9,110 us in
trigger-to-completion wait, and 19,963 us in cleanup, including the
nine leased known-answer blocks. The residual was 141,336 us in this
run, close to 142,091 us in the unsampled profile. PC samples attributed
that residual approximately as follows:

| Work outside the direct phase brackets | Estimated time (ms) |
| --- | ---: |
| libc fill and copy loops (`memset` 29.5, `memcpy` 27.1) | 56.7 |
| Mbed TLS SHA stream and padding | 23.7 |
| C/Nim block wrappers | 19.6 |
| Mbed TLS digest dispatch and HMAC | 17.9 |
| Mbed TLS derivation loop | 14.0 |
| Driver entry, return, and profile bookkeeping | 9.7 |
| Other | 0.5 |

The non-driver rows use ELF symbol ranges. The driver bookkeeping row
uses `[0x2204fcf6, 0x2204fd2e)`, `[0x2204fe2a, 0x2204fe60)`, and
`[0x2204fdd0, 0x2204fde6)` in this ELF, covering the entry, counter
updates, and return. The numbers are sample-based estimates and need not
sum exactly to the direct residual. Radare2 identifies both libc hotspots
as byte loops in uncached WRAM. The uncached run also reported
`MHCR=0x0000103F`, so the core's instruction cache was enabled in both
runs despite the slow routines using a non-cacheable address. Sampling
does not distinguish instruction stalls from data stalls inside a
function. The cached placement run did complete the same Mbed TLS
operation within the budget.

Raw timestamps and PCs:
`build/hw-validation-allcore-ap-uncached-pc-profile/logs/allcore-ap-pc-samples.bin`.
Pass that file, its matching M0 ELF, and callback limits
`0x0044dc1b 0x0047d497` to `tools/analyze_wifi_ap_pc_profile.py`.

#### Cached all-core AP survey: channels 1 through 11

Build `allcore_wasm_http_manager_test` with the cached WRAM lease bench
flags above plus `-d:bl808AllcoreWifiApChannelSurvey=1`, without either
profiling flag. Supply a synthetic AP passphrase and a nonexistent station
SSID. The survey checks the configured 11-channel plan, runs the hardware
known-answer test once, then starts and stops the same AP on each channel.
The 200 ms check covers the start command, not the subsequent beacon wait or
stop. Per-start counters are captured before the beacon wait.

An AP start confirmation does not prove beacon transmission. A radare2
cross-check with the pinned BL808 archive and linked Nim path found that both
can confirm before all channel activation work has run. The survey therefore
requires a fresh MAC beacon completion with DONE and success set and checks
the firmware's primary and center frequency readback before requesting stop.
An armed descriptor or software-forced flush confirmation does not count.

On Ox64, with JTAG detached during startup, the pass mask was `0x7ff`.
Every row had successful start and stop, one new beacon success, 32,769
hardware blocks, zero software blocks and timeouts, and advancing D0 and LP
heartbeats during the command.

| Channel | Primary and center (MHz) | Command (us) | Key setup (us) |
| ---: | ---: | ---: | ---: |
| 1 | 2412 | 189,356 | 177,758 |
| 2 | 2417 | 190,611 | 179,084 |
| 3 | 2422 | 190,717 | 179,036 |
| 4 | 2427 | 189,589 | 178,100 |
| 5 | 2432 | 189,573 | 178,068 |
| 6 | 2437 | 190,040 | 178,499 |
| 7 | 2442 | 189,867 | 178,350 |
| 8 | 2447 | 189,825 | 178,345 |
| 9 | 2452 | 190,238 | 178,702 |
| 10 | 2457 | 190,087 | 178,398 |
| 11 | 2462 | 189,854 | 178,345 |

The smallest observed command margin was 9,283 us. The M0 wrapper was
839,008 bytes and erased below `0xDD000` (LP starts at `0xE0000`). The run
did not write D0 or LP. After restoring the previous Frog M0 image, two
reads of `/wasm/cores` confirmed healthy, advancing M0, D0, LP and enclave
heartbeats. The Mac's Wi-Fi configuration was unchanged. Saved table and logs:
`build/hw-validation-allcore-ap-channel-survey-live/logs/allcore-ap-survey.*`.
This establishes MAC-side beacon success on the configured channels, not
external reception, client discovery/association/DHCP/HTTP, STA coverage, or
a worst-case deadline bound under alternate workloads.

#### Temporary engine ownership outside the AP lease

Radare2 on the pre-fix survey ELF showed the unleased provider rejecting
`BUSY | ENABLE | DONE` at `0x6204fb72` and returning the same false result
as a transaction fault. The block callback's false branch at `0x6204fe8c`
stored backend state 3 (disabled). The first-use probe made the same
transition, so one call during temporary ownership could silently disable
hardware use until reboot.

The provider now distinguishes deferral from a fault. A deferred probe is
eligible for retry; a deferred block on a previously verified provider
leaves it eligible. The existing software fallback handles the individual
unleased block without touching engine state. A failed known-answer check
or a hardware transaction fault still retires the provider; live DMA
buffers are not cleared after a busy timeout. The budgeted AP lease still
requires hardware and fails if it cannot acquire the engine.

`tools/test_wifi_mbedtls_sha1_alt.py` verifies both deferral cases against a
Mbed TLS vector and checks the real Nim unleased handler with mock MMIO for
busy, configured, and pending engine states and idle/busy timeouts. The
fixed cached all-core image cross-linked in the existing WRAM bank. The
timing table above is from the preceding hardware run, not this build.

The AP lease is not a station reconnect optimization: the pinned archive
and linked Nim firmware both call the SDK station callback during peer
registration, after the station command has been accepted. That path does
not arm the AP lease. The SDK station setter also ignored a failed key
derivation before copying its result into station state. This was a static
finding, not a diagnosis of a measured Frog disconnect.

#### Station key-setup result and live join

The Nim station registration path now calls the SDK overlay's checked
dispatcher. It preserves the void ABI for other callbacks. The built-in
callback continues to use the linked derivation routine or the existing hex
decoder; it does not publish station state or arm a join timer until the
result is valid. The failure path clears the key buffer and passes the error
back to the ownership-checked registration rollback. Radare2 located the
checked dispatcher in the M0 ELF at `0x5800537A`; the call at `0x58080188`
branches to publication only on a zero result.

The production C overlay host oracle injected a partial write and error,
verified no key or join state was published and no timer armed, then passed
the next attempt. Hex input and forwarding a custom void callback passed as
well. The focused Nim tests exercised station/address rollback and retry,
rejected a mutation that ignored the result, and verified a duplicate
registration failure reply did not publish another terminal result.

The 839,264-byte M0 image fit below the LP slot (erase end `0xDD000`).
On Ox64, it completed the cached AP survey before joining Frog. The pass
mask was `0x7ff` and the commands took 192,175 to 194,016 us, leaving at
least 5,984 us under the 200 ms command budget in this run. Each start used
32,769 hardware blocks with zero fallback and timeouts, stopped cleanly,
and produced a fresh MAC-confirmed beacon at the expected channel readback.
There was one successful STA registration and confirmation. The candidate
obtained a DHCP lease and served `/wasm/cores`; all four heartbeats advanced
between reads. Cumulative hardware block counts advanced after the survey,
but the join was not timed separately. The board run did not inject a key
setup failure or force a reconnect. Raw rows and logs:
`build/hw-validation-allcore-sta-key-result-live/logs/allcore-ap-survey.*`.

The prior Frog image was restored and its HTTP manager and four advancing
heartbeats were verified. D0 and LP flash and Mac Wi-Fi settings were not
changed. The default all-core configuration also cross-linked, but its
857,040-byte wrapper would erase to `0xE2000`, past the retained LP slot
start at `0xE0000`; only the smaller bench variant was eligible to flash.

#### Normal all-core deployment with hardware-backed Mbed TLS

The normal M0 all-core HTTP build now enables GCC cross-jumping to merge
identical code tails. Its wrapped image went from 857,040 to 826,128 bytes
(erase end `0xDA000`). `-Oz` without cross-jumping produced no size change.
Use `-d:bl808WifiPreserveCallSites=1` for distinct call sites in disassembly
audits; check that build's erase span before deploying it.

The cached provider also links without the AP benchmark. The all-core lease
still requires the enclave WRAM layout and, outside the diagnostic bench,
cached execution. To build the hardware-backed manager:

```sh
.venv/bin/python tools/hw_validate.py --test allcore_wasm_http_manager_test \
  --build-only --nim-define bl808WifiMbedTlsSha1Hardware=1 \
  --nim-define bl808WifiMbedTlsHotOcram=1 --nim-define bl808WifiMbedTlsSha1Lease=1 \
  --nim-define bl808WifiMbedTlsCachedWram=1
```

Radare2 verified that the linked ELF includes the Mbed TLS derivation and
cached block provider, not the alternative Nim derivation or AP bench. The
834,336-byte hardware-backed wrapper erases to `0xDC000`, below LP at
`0xE0000`. The bounded UART-anchor path rejected the older wrapper and
verified the new M0 write without writing D0 or LP.

On a detached boot, the normal manager joined Frog, obtained a DHCP lease and
served `/wasm/cores`, with all four heartbeats advancing. The snapshot reported
one successful station registration, 32,805 cumulative hardware blocks, zero
fallback or timeouts, and a 2,860-byte cached WRAM copy matching the ELF. This
does not time the station join or repeat the AP timing sweep on the normal
image. The hardware-backed manager was left running. See
`build/hw-validation-allcore-deploy-mbedtls/logs/allcore-deploy-mbedtls.*`.
