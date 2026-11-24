# Connected Scan A/B Bench

This opt-in test uses the standalone M0 HTTP/UDP server from the original
reason-7 investigation. It does not change scan policy, add a network
control endpoint, or automatically reconnect. The normal example and
ordinary firmware builds do not enable it.

The server warms up for 8 seconds after DHCP and listener startup. Then
it runs matched 40-second windows in `control, scan, scan, control` order.
The scan windows request one normal foreground scan through the Wi-Fi
manager; the controls do not request any scan. Keep the same fixed-rate
HTTP or UDP echo workload running across the whole block. The compile-time
`WifiScanAbWindows` can be set to a larger multiple of four for repeated blocks;
increase the bench capture time accordingly. Four windows are a smoke test,
not enough to rule out a rare drop.

`bench=scan_ab` records report the mode, monotonic timestamps, traffic
counts, scan submission and confirmation, WPA state, IPv4 address, and
the disconnect status/reason. The first home-channel observation means
firmware entered its home-wake path; it is not a radio measurement. The
Null frame telemetry separately counts successful queue admission, actual
MAC ACKs, hardware completions without an ACK, and software retirements.
`last_tx` is the raw last completion and `home_mac_us` is the MAC clock,
not the scheduler clock used for `ms` and `first_home_ms`.

The experiment stops on link loss, address change, rejection, scan failure,
or an unconfirmed scan at the window deadline. `event=finished` means that
the run is analyzable, not that every window passed. Report exposure and
outcomes separately for scan and control, and check the recorded traffic
counts. An ACK alone does not prove the original reason-7 drop's cause.

Use `m0_wifi_connected_scan_ab` with `tools/hw_validate.py`. Supply
`BL808_WIFI_SSID` and `BL808_WIFI_PASSWORD` in the bench environment. First
run `--list`, `--preflight`, `--build-only`, and `--dry-run` as documented
in `AGENTS.md`. On a shared all-core bench verify the M0-only image wrapper
and preserve the installed LP/D0 slots and unrelated flash regions.
Collect UART or the PSRAM JTAG log after the last window; use the harness
hardware lock. Avoid debugger halts during the measured windows.

Host checks:

```sh
.venv/bin/python -m pytest -q tools/test_wifi_scan_ab_bench.py tools/test_wifi_home_wake_ab.py
```

## Ox64 Results

The idle and 2 Hz UDP runs each completed an ABBA block, with no WPA or
IPv4 loss. The loaded run received 159 UDP probes in each arm. Its two
scans confirmed in 3,002 and 2,992 ms; 21 of 22 home-wake transmissions
were ACKed. The idle block recorded 20 of 22. See the two event traces in
`build/hw-validation-wifi-connected-scan-ab-frog/`. The original failing
standalone image did not request scans in its steady-state loop. These
short runs do not exclude a rare failure.

A subsequent no-scan check rebooted the already-flashed all-core image
through the UART anchor, without a flash write. After the two startup
reconnect checks, the host sent no test traffic for five minutes. The
firmware still sent gratuitous ARP every second, so this was not a
radio-idle test. The before/after JTAG samples were 318.5 seconds apart
by firmware uptime. They recorded 3,096 new admitted peer Beacons and
11 keepalive attempts: 10 ACKs, zero queue rejections, and one other
completion. The peer-disconnect, link-drop, and reconnect-failure
records stayed empty, and HTTP still answered at the same lease.
See `build/hw-validation-wifi-no-scan-soak-restored/snapshot-summary.json`.

The standalone follow-up used `m0_wifi_http_server` with
`bl808WifiDiagLinkDrop` and `bl808WifiDiagPeerRxAdmission` enabled.
The UART anchor verified a 733,152-byte M0-only write. The linked
steady-state loop did not request scans, send periodic UDP or
gratuitous ARP, or auto-reconnect. After the first HTTP readiness
check, the host sent no test traffic and JTAG stayed detached for
six minutes. The completion counter still showed zero scans.
The snapshots showed 7,297 more received frames, no peer disconnect
or local link-loss indication, 16 keepalive attempts, 12 ACKs, and
zero queue rejections. The other four completions do not distinguish
an on-air miss from software retirement. HTTP still answered on the
same lease after the final read. See
`build/hw-validation-wifi-standalone-no-scan-frog/snapshot-summary.json`.

No passive on-air capture was taken in this run. The remaining test
is to correlate the first peer-disconnect record (if it recurs) with
the preceding exchanges in a passive channel-11 trace. Neither a
descriptor completion nor a MAC ACK proves that the AP still
considered the STA associated.

## Keepalive Completion Trace

For that capture, add `--nim-define bl808WifiDiagTrafficProbeHistory=1` to
the standalone build with `bl808WifiDiagLinkDrop`. The existing five-word
probe counters and retry policy are unchanged. The new
`nimfw_dbg_traffic_probe_history` export is 19 words; resolve its address
from the running ELF and read it through the hardware harness.

Word 0 is an even sequence number once a write is complete. Retry a
snapshot with an odd sequence. Words 1 and 2 count completions with
hardware-done but no ACK, and completions without hardware-done,
respectively. Starting at word 3 are eight pairs of MAC microseconds
and raw TX callback status. Divide the even sequence by two to obtain
the write count; the next slot is that count modulo eight. Use the same
32-bit MAC clock as the `PEER` record when correlating times.

The history stops accepting entries once the first `PEER` decision is
published. Reconnect and the regular counters continue. Peer publication
and history updates are serialized with M0 IRQs masked and use explicit
volatile stores to publish their commit words. An old callback that loses
session ownership before recording is excluded. This is a device-wide
callback history: older entries can be from earlier associations, and
an earlier transmission whose callback arrives after `PEER` is omitted.
For SA Query, the cutoff is the timeout decision, not reception of the
frame that started the query.

The standalone trace build fits the current M0 partition with the
validation log in PSRAM. For the all-core image, build the
`allcore_wasm_http_manager_test` target with these additional defines:

```sh
.venv/bin/python tools/hw_validate.py --test allcore_wasm_http_manager_test \
  --build-only --nim-define bl808WifiDiagLinkDrop=1 \
  --nim-define bl808WifiDiagPeerRxAdmission=1 \
  --nim-define bl808WifiDiagTrafficProbeHistory=1 \
  --nim-define bl808WifiDiagWarmScanCompact=1
```

This profile omits duplicate UART bring-up, reconnect, and peer dumps.
It keeps the all-core checks, link-loss marker, reconnect IP and completion
markers, LP fault report, and structured failure and TX-history records.
It does not request a connected scan or force a reconnect.

The compact trace wrapper with the state-down and idle-restore fixes is
851,664 bytes at `0x10000`. Its exclusive end is `0xDFED0`; the last
erase sector ends at the installed LP image start, `0xE0000`. The raw
size margin is 304 bytes. D0 and LP payloads were byte-identical to the
previous trace build. Recheck the exact wrapper and erase range for any
rebuild; the earlier verbose wrapper did not fit.

On the Ox64, the UART anchor verified that M0-only write and acknowledged
the reboot. The running M0 instructions matched the staged binary. The
board returned to `192.168.1.114` on Frog, all three cores and the enclave
reported healthy, and wired HTTP WASM `add(19,23)` returned `42`.

The first and last snapshots were 139.410 seconds apart by firmware
uptime. JTAG was detached and no test traffic was sent between them;
the firmware's periodic gratuitous ARP was still enabled. The board
admitted 1,345 new peer beacons and counted 3,249 more RX frames. Of 14
keepalive probes, five reported a MAC ACK and nine completed without an
ACK. No submissions were rejected and no completions lacked a hardware
result. The peer, link-drop, reconnect-failure and boot-lease records
stayed empty. The board served wired HTTP afterward. This does not
exercise either reconnect fix on the device or explain the original
reason-7 drop. See the `soak-*.m0.openocd.log` files under
`build/hw-validation-wifi-idle-restore-notification-trace/`.

A follow-up snapshot at 270.533 seconds of firmware uptime still showed
no drop or failed reconnect. Three more keepalive probes all reported
an ACK; there were no additional misses. The last successful join was
on channel 11 (2462 MHz), and the completed-scan count was still one.
The original forced warm-reconnect failure in `bl808_vendor_blobs.md`
stopped during disconnect cleanup, before candidate selection. The
successful join here and the older failure do not justify changing
the current AP selection policy.

The Mac opened a radiotap capture but did not confirm that it was tuned
to channel 11. It was associated on channel 36 in normal operation, and
the 12-second filtered pilot captured zero frames. That file is not
evidence that Frog or the Ox64 was silent on channel 11. Ethernet stayed
up, and the Ox64 still answered at its existing address after the pilot.

The next capture explicitly set channel 11 before opening the monitor.
The verified 99.945-second window had 1,164 records at 2462 MHz, including
963 Frog beacons and 12 Ox64 Null frames in four sequence groups. The first
group had six captured frames, five marked as retries. The spacing of the
four groups matches the firmware's completion timestamps to within 3 ms:
the first group ended without a MAC ACK and the next three probes reported
ACKs. No peer disconnect frame or firmware drop was recorded; the Ox64
still served HTTP. The Mac rejoined its saved Frog network afterward.
The capture is `frog-fixed-ch11-20261123T213327Z.pcap` under the trace
build directory above. This is evidence for one on-air retry burst, not
a reproduction of reason 7 or qualification of other channels. See
[channel coverage](wifi_channel_validation.md) for that separate gate.

Separate HTTP observation: the same WASM request returned `200` when
sent together and `400 incomplete body` when the body followed its header
by 150 ms. The example dispatched the first TCP receive callback as a
complete request. This was reproduced after the observation window and
was not a Wi-Fi disconnect.

Pinned `txl_frame.o:txl_frame_evt+0x62` passes THD status to the callback.
`txl_frame_release+0x36` can pass zero. The flush writes a different
descriptor word, so a current callback can still see a MAC result
written before the flush. The trace records callbacks that pass the
existing session guard. No-done status is not evidence that nothing was
transmitted; a hardware ACK is also not proof the AP still considered
the station associated.

The separate public STA keepalive API accepts an ACK only when both
bits 31 (hardware-done) and 23 (success) are present. Its confirmation
and failure counts still include software retirements. The
`nimfw_dbg_nullframe_no_hw_result` counter identifies the failures
without hardware-done, rather than attributing every failure to a
missed on-air ACK.

The first Ox64 keepalive smoke image stopped at PHY assertion 586
before scanning. Its manifest selected the legacy calibration path;
the same startup failure is documented in `bl808_vendor_blobs.md`.
Both keepalive manifests now select native BL808 WLAN calibration and
skip the unrelated AP start/stop checks. The assertion itself remains
enabled.

The corrected legacy Null test joined Frog, reported three MAC ACKs
for three confirmations (last status `0x80800000`), disconnected
on request, and completed 13 checks with no failures or PHY assertions.
The QoS Null sibling linked but was not run on the board.
See `build/hw-validation-wifi-keepalive-ack-contract-frog/native-sta-only/keepalive-summary.json`.
This validates the positive ACK path, not the reason-7 disconnect.

A follow-up radare2 audit of `mm.o:mm_check_beacon+0x68..+0x9c` and
`mm_ap_traffic_probe_cfm+0x12..+0x34` confirmed the 30-second gate is time
since the last successful probe, not a delay between failed probes. Both
paths can request a probe at each eligible beacon after the gate; only
the completed hardware misses count in Nim. The six captured frames in
the failed retry group correspond to one probe completion, and the next
probe's ACK reset the miss budget. That local-loss path cannot explain
the earlier trace, which showed a peer disconnect and no local loss.

## Known Network Selection

The all-core manager used to gate boot on a scan match for the primary
SSID, even after choosing the fallback, and used the primary SSID again
on every reconnect. Both conditions could prevent joining a configured,
available fallback when the two SSIDs were distinct. This was a manager
policy issue above the station firmware's join request, not evidence for
the earlier Frog loss with identical primary and fallback SSIDs.

Boot now matches both configured names and their channel constraints.
It respects the fallback-delay setting and still uses a visible primary
when the fallback is absent. Reconnect prefers the last joined profile;
it can use the other known profile if only that profile was observed. A
failed or empty scan does not switch profiles. Scan diagnostics still print
at most eight match rows, but that limit no longer ends the search.

The host checks cover the selection matrix and a distinct fallback beyond
the diagnostic limit. The distinct-fallback all-core build used an absent
primary, the bench network as fallback after one scan, and one forced
reconnect after 12 seconds. It cross-linked and its 836,256-byte wrapper
passed the bounded flash dry run (erase end `0xDD000`, LP `0xE0000`).

The same image was then verified through an M0-only UART-anchor write.
On Ox64, the retain-last-profile path completed the one forced reconnect.
The device reported six scan results, successful disconnect and join
commands, a completed join, and the same DHCP address. It recorded two
successful station registrations and 65,621 hardware blocks with zero
fallback or timeouts. Wired HTTP was healthy both before and after the
forced step; individual requests also timed out, including at the end of
the 64-sample window. A follow-up request succeeded without a firmware
restart. The run does not attribute those HTTP gaps to association loss.
See `build/hw-validation-allcore-wifi-fallback-reconnect-build/logs/fallback-reconnect.*`.
The normal hardware-backed image was restored and all four heartbeats
resumed; D0 and LP flash and Mac Wi-Fi settings were left unchanged.

## Stale Scan Cache Hint

Radare2 on pinned `sm_task.o:sm_connect_req_handler+0x1be..+0x1fe` shows
that a wildcard BSSID on a requested channel takes the firmware scan path.
The merged Nim station manager could bypass that path after a rejected
foreground scan: pre-admission failure skipped the physical cache reset,
and the next join promoted an older matching entry to an explicit BSSID.

The manager now retires the hint at every scan attempt, requires a
successful firmware confirmation before using newly collected entries,
and consumes the hint on the next admitted join. Rejection leaves the
observations and in-flight connection untouched. A caller-supplied BSSID
is unchanged. The host regression exercised busy/recovery/submit rejection,
no confirmation, failed confirmation, empty completion, and one successful
use. Removing the initial retirement reproduced the stale pinned join.
The scan-cache and event-future suites passed 41 tests. The guarded
hardware-backed image cross-linked and passed the bounded flash dry run
(834,848 bytes, erase end `0xDC000`). The cache change was not in the
forced-reconnect device run above. The normal image with this change was
subsequently tested below.

## HTTP Client Lifecycle And Reachability

Radare2 and the linked accept path showed that the all-core HTTP manager
registered accept, receive and sent callbacks, but not `tcp_err`. The
pinned lwIP header documents that fatal errors deliver the callback after
the PCB is freed. The manager now releases only its own client slot in
that callback. Its explicit close and abort paths still disarm the callback
before calling lwIP. Checked, release and ASan host tests cover reclaimed
and reused slots, including pending data and WebSocket state, without
touching the dead PCB.

The older normal image answered all 45 paired wired ICMP and HTTP probes.
The 834,912-byte image with both the cache and client-slot fixes was flashed
through the bounded UART anchor, M0 only (erase end `0xDC000`, LP starts
at `0xE0000`). It joined Frog, obtained DHCP, and served `/wasm/cores` with
four advancing heartbeats. The detached-boot snapshot had one successful
scan-cache lookup, one station registration, 32,816 hardware blocks with
no fallback or timeouts, and zero deauth, connection-loss or disconnect
processing counts.

On the updated image, the first 45-pair window had 44 ICMP replies and 43
HTTP successes. The filtered wired handshake window then had 60/60 ICMP
successes and 56/60 HTTP successes. One failed request saw a SYN-ACK only
about 2.9 seconds after the probe began, past the host's 750 ms connect
limit. The other three completed TCP connection establishment but had no
HTTP first byte before the one-second request limit. A subsequent full TCP
header capture had 45/45 successes for both protocols and did not reproduce
the later stalls. Thus the slot leak is a verified bug, but its fix did not
eliminate the observed timeouts and the traces do not identify their cause.
No injected TCP fault was run on the physical device. The updated manager
was left running. Captures and summaries are under
`build/hw-validation-allcore-http-and-scan-lifecycle/logs/`.

## Correlated TCP Path Trace

The temporary all-core diagnostic adds `-d:bl808WifiDiagTcpPath=1` to
the hardware-backed manager build. It stores up to 1,024 timestamped
28-byte records in PSRAM. RX handoff/rejection, TX output/rejection, MAC
completion, HTTP accept/pool-full and HTTP receive are separate stages.
The records contain only TCP header metadata or callback counters, not
packet bodies. Radare2 and the linked call sites confirmed that TX
completion is sampled from `bl_tx_cfm` before the retry/release decision.

After the wire probe window, read `nimfw_tcp_path_head` and
`nimfw_tcp_path_ring` using the running M0 ELF and the hardware harness.
The analyzer accepts the little-endian head followed by all physical ring
slots, and rotates them when the head exceeds 1,024. The wired input is
classic Ethernet PCAP; a 54-byte snapshot is sufficient for the observed
Ethernet/IPv4 minimum TCP headers. The analyzer matches packet headers,
not wall-clock timestamps, and treats missing matches as inconclusive.

```sh
.venv/bin/python tools/analyze_wifi_tcp_path.py headers.pcap device-trace.bin
```

The 835,744-byte trace image was written to M0 only through the bounded
UART anchor (erase end `0xDD000`, LP at `0xE0000`). With JTAG detached,
55 paired wired probes returned 55/55 pings and 53/55 HTTP responses.
Both failures had matching device-ring evidence. The snapshot retained
1,024 of 1,038 events, with one successful station registration and zero
deauth, connection-loss and disconnect-processing counts.

- Handshake timeout: a SYN reached lwIP, and TX output queued the SYN-ACK
  960 us later. Four host submissions completed with `0x80010701`
  (hardware DONE, retry limit and no success bit). A TCP retransmission
  about 2.54 seconds later completed with success and appeared on the
  wire after the client's deadline.
- Response timeout: the complete 86-byte request reached the HTTP
  callback. TX output queued a 1,020-byte TCP reply 1,636 us later, and
  four completions reported `0x80010701`. No reply data appeared on the
  wire; later ACK-only/FIN traffic for the same connection did appear.

This locates both measured failures in the outbound MAC completion path,
not HTTP parsing or a full station disconnect. It does not explain why
those transmissions exhausted retries. Compare the actual submitted rate,
power and retry policies for good and missed transmissions at the next
bench gate; the current trace does not collect those words. Artifacts:
`build/hw-validation-allcore-tcp-path-trace/logs/wired-tcp/`.

After the capture, the normal M0 image was restored. Two wired reads of
`/wasm/cores` confirmed advancing M0, D0, LP and enclave heartbeats.
D0 and LP flash and the Mac's Wi-Fi settings were unchanged.

### Submitted TCP rate and power settings

The same trace flag now adds a separate 384-entry policy ring. Each row
holds the absolute TCP event ordinal, four rate words, the rate policy,
retry-limit and ACK control fields, the raw hardware completion word, and
four programmed power words. The main event's metadata carries the
repush ordinal and a policy-present bit. Only hardware completions from
the current IPC wrapper can produce a policy row. This does not read a
mutable station policy or record actual RF output.

Read `nimfw_tcp_path_policy_head` and `nimfw_tcp_path_policy_ring` while
reading the main ring from the same halted target. The policy snapshot
starts with the 32-bit head followed by all 384 physical 52-byte rows.
Pass it as `--policy-snapshot device-policies.bin`. The analyzer keeps
old snapshots usable and ignores overwritten or software-retired rows.

Radare2 confirms that pinned `txl_cntrl.o:txl_payload_handle_backup`
copies ACK/retry controls and points the THD at the inline policy at
`+0xee..+0x102`. Nim snapshots that same owned copy before the host callback
can repush or release it. The pinned `rc.o:rc_update_counters+0xd6..+0xf4`
can close a new trial based on an older frame's completion. The native
regression retains the submitted-rate check: an older exhausted frame
charges its own rates without closing the new trial; exhausting the
matching trial does advance it.

In the detached Ox64 run, 47/48 wired pings and 47/48 HTTP requests
succeeded. They missed on different probes. All 306 hardware completions
matched a policy row; 242 succeeded and 64 exhausted retries. Every raw
completion agreed with the published one apart from publication bit 0.
The firmware recorded one successful station registration and no
connection-loss, deauth or disconnect-processing events.

For the HTTP timeout, the request reached the callback and TX output
queued the 1,022-byte TCP reply 1,617 us later. Repushes 0 through 3 all
returned `0x80010701` with unchanged rate words
`80000006/80000004/80000005/80000400` and programmed power words
`48/48/48/50` (hex). With this exact policy and data length, five other
hardware submissions succeeded and these four exhausted retries.
A retry of the same TCP data sequence later received a hardware ACK with
a different leading rate, about 2.09 s after the original reply was queued.
The client had already timed out at 1.25 s; the capture did not observe
that late packet on the wire.

The repeated host repush did not select a different rate in the failed
window. Identical settings worked on other data frames, so this is not
evidence of a universally invalid rate or power value. A controlled
comparison with a lower negotiated fallback in the reachable second
slot, keeping channel and workload the same, would test whether changing
the policy on exhaustion improves delivery. Raw data:
`build/hw-validation-allcore-tcp-policy-trace/logs/wired-tcp/`.

The normal M0 image was restored and verified with two wired manager
reads showing all four heartbeats advancing. D0 and LP flash and the
Mac's Wi-Fi settings were unchanged.

### Retry feedback and second-slot comparison

The pinned `me_utils.o:me_tx_cfm_singleton+0x08..+0x18` computes the
attempt count from the status retry count plus one. On the retry-limit
branch that same number is passed as failures, with no requirement that
eight attempts were used. The native singleton feedback no longer drops
these shorter completions. It still requires the owned submitted policy,
normal ACK mode, the supported four-attempt slot policy and an
unambiguous hardware status. The regression checks all eight lengths,
including that a four-attempt exhaustion cannot finish a slot-two trial.
The all-core hardware-backed image cross-links with the new accounting.
This change is separate from the eight-attempt stalls in the Ox64 trace.

With both `bl808WifiDiagTcpPath` and `bl808WifiDiagTcpFallbackAb`, the
bench compares only eligible station HTTP data replies. The low bit of
the observed peer port XOR its values shifted by four and eight selects
the arm. The treatment copies the already negotiated 1 Mbps entry and
its own power from slot four to slot two of the inline policy. The
primary, other slots, ACK and retry controls, frame bytes and station
policy are unchanged. AP traffic, fixed-rate policy, active trials and
non-data replies are excluded. A choice event records the original
slot-two word, including for the control arm. Use the device policy
ring to verify the values attached to the actual completions.

The 837,728-byte diagnostic wrapper was verified through the UART anchor,
with an exclusive erase end of `0xDD000` below LP at `0xE0000`. The
diagnostic was built before the short-retry accounting change to keep the
two comparisons separate. Four detached rounds of 36 wired pings and
HTTP requests completed 136 pings and 131 validated HTTP replies. The
analyzer verified 182/182 eligible policy choices and agreement between
the 191 data completion status pairs. Each round fit in the retained
window of both rings.

| Outcome | Existing policy | 1 Mb/s in slot two |
| --- | ---: | ---: |
| First eligible data submissions exhausting retries | 10/69 | 12/61 |
| Valid HTTP replies among probes with a reported port | 68/71 | 63/66 |

The Mac did not use the requested curl source ports, so the readback
uses the actual port. The counts are descriptive: both arms share
adaptive rate state and their starting rate mix was not identical. The
comparison did not show a benefit from promoting 1 Mbps on data replies
and did not justify changing production rate selection.

The seven probes with no reported port had timed out during TCP connect.
The wired SYN was matched to an RX handoff and SYN-ACK submission for
each. The first SYN-ACK was queued 743 to 975 us after RX handoff.
Six first saw a successful hardware completion 2.73 to 3.24 s
after RX handoff, past the 750 ms client deadline; one had no successful
completion in the retained window. The software recorded no deauth,
connection-loss or disconnect-processing events in any round. The data
fallback did not apply to these SYN-ACKs.

Replay the saved runs with `tools/analyze_wifi_tcp_fallback.py` and the
four `build/hw-validation-allcore-tcp-fallback-ab/logs/wired-tcp-*`
directories. This checks descriptor settings and completion outcomes,
not the actual on-air rate, delivered power, or the reason a frame was
not acknowledged.

The prior normal M0 image was restored with two verified HTTP reads
showing all four heartbeats advancing. Neither D0 nor LP flash was
written. The short-retry accounting change remains build- and host-tested
only; it was not part of the diagnostic or restored image.

### MAC doorbell, completion and independent air capture

`bl808WifiDiagTcpDmaTiming` with `bl808WifiDiagTcpPath` adds two records
without growing either ring. Stage 10 timestamps the write to the MAC TX
doorbell at `0x24B08180`; its detail records the pre-MAC sequence control,
AC, new-head versus append, and QoS TID. Stage 11 timestamps the accepted
hardware completion word before transferring the descriptor to host
confirmation. Neither is an on-air timestamp. Radare2 locates the AC0
start write in pinned `txl_cntrl.o:txl_payload_handle_backup+0x2a4` and the
primary completion read in `txl_transmit_trigger+0x9a`.

The 837,344-byte M0-only diagnostic erased no farther than `0xDD000`. Two
JTAG-detached runs of 24 wired probes each returned 47 valid HTTP responses
and 47 pings, without a recorded station disconnect. The DMA audit matched
117 complete SYN-ACK/data submissions with no orphan or ambiguous keys.
Failed first SYN-ACKs reached the doorbell in 2.37 to 3.98 ms and failed
first data replies in 2.61 to 4.27 ms. These ranges overlap successful
submissions. For the HTTP timeout, the 1,020-byte reply reached the
doorbell after 3.86 ms. All four submissions completed with
`0x80010700` after 9.42 to 29.67 ms from their doorbells and reached the
host confirmation in another 0.84 to 0.99 ms. The timed-out reply did
not spend its client deadline in the Nim queue or confirmation path.

The separate Mac monitor recorded 2,923 channel-11 headers, including 619
Frog beacons and 385 ACK headers addressed to the Ox64. Using MAC
addresses, QoS TID and sequence number, it retained 92 of 95 successful
submissions and 14 of 22 retry-limit submissions from the two timed
probe windows. The SYN-ACK for the timeout was observed, but none of the
four data submissions (TID 0, sequences `0x09c..0x09f`) matched an air
record. Nearby sequences did match. The missing frames could have been
missed or undecodable at the monitor; they do not prove radio silence or
identify what the AP received. A nearby ACK in a monitor trace is only
a candidate because it has no transmitting address or sequence number.
The Mac was returned to its saved network on channel 36 in station mode.

The same disassembly audit found a separate difference. After setting the
THD's policy fields, the reference goes straight to queue accounting.
Nim ran the old DHCP-labeled raw snapshot and breakpoint hook on ordinary
IPv4 replies before writing the MAC head. The heavy snapshot now requires
`bl808WifiDiagDhcpTxFinalSnapshot`, enabled by `m0_wifi_lwip_smoke` only.
The snapshot fix was not in this diagnostic run. It leaves the ownership,
THD writes and MAC head/start order intact and is not evidence of the
cause of retry exhaustion.

Raw artifacts are under
`build/hw-validation-allcore-tcp-dma-timing/logs/`. Replay the two
`wired-tcp-*` directories with `tools/analyze_wifi_tcp_dma.py` and
the separate `air-ch11.pcap` with `tools/analyze_wifi_tcp_air.py`.
The normal M0 image was restored and all four heartbeats advanced on
wired HTTP; D0 and LP flash were not written. The rebuilt normal ELF
contains no snapshot breakpoint call in `txl_payload_handle_backup`.
The opted-in legacy manifest passed its UART-anchor dry run.

### Large reply DMA layout

Radare2 on the pinned `txl_buffer.o:txl_buffer_update_thd+0x4c..+0x98`
shows inclusive span ends, the header-to-payload link and a null-terminated
last payload entry. Pinned `txl_cntrl.o:txl_cntrl_push+0x0a..+0x26`
sets the MAC length to payload plus prepared header plus link trailer
plus four FCS bytes. Nim uses the same arithmetic and 32-bit link fields.
For the 1,020-byte TCP data reply, the corresponding IPv4 span is 1,060
bytes and the QoS MAC length is 1,114 bytes (42 header, 8 trailer, 4 FCS).
A host regression builds that chain with the real Nim builder and
checks each independent shape flag against a deliberately wrong field.

The saved channel-11 capture agreed with the expected size for all 106
matched SYN-ACK/data submissions, including 14 retry-limit submissions.
The check uses the original PCAP record length, not the 128-byte capture
limit, and adjusts for [radiotap alignment and FCS flags](https://radiotap.org/fields/Flags).
The four submissions for the earlier timeout were not seen by the monitor
and are not covered by this comparison.

`bl808WifiDiagTcpDmaShape` adds stage 12 alongside the doorbell record.
It checks the pre-handoff singleton hardware head and policy pointer,
advertised length, header and payload spans, chain terminator, IPv4
SNAP and excess IPv4 bytes. Its result is the MAC length in the low
16 bits and a problem mask in the high 16. The audit joins a shape only
to the immediately preceding doorbell for the same packet and timestamp.
Use `tools/analyze_wifi_tcp_dma.py --require-shape` for this profile.
This validates the submitted fields, not the bytes subsequently fetched
by DMA or received by the AP.

The host-path comparison found a separate byte-preservation bug. The
pinned host TX path copies lwIP's pbuf chain into the IPC slot unchanged.
The Nim port-80 diagnostic rescanned a contiguous TCP segment three times
and rewrote its checksum, but skipped the same work for a split segment.
Both local lwIP profiles already generate TCP checksums. The native
diagnostic now only reads headers and leaves the bytes untouched, as
required to preserve the checksum generated by the sending TCP stack
([RFC 9293](https://www.rfc-editor.org/rfc/rfc9293.html)). The focused
regression passes the same valid 1,500-byte IPv4 packet through
`bl_output` and `txPush` as one or two pbufs. Both produce identical IPC
payloads, including a valid `0x0000` TCP checksum. The removed private
checksum diagnostics had no in-tree consumer. UDP and DHCP are unchanged.
This difference is not evidence for the MAC retry-limit failures.

The 836,864-byte shape diagnostic includes the byte-preservation fix and
the prior opt-in snapshot change. M0-only flash ended at `0xDD000`.
Three detached rounds returned 57/60 valid HTTP replies and 58/60 pings,
with no station disconnect recorded. The audit verifies all 170 scoped
submissions (both successful and retry-limit completions) and all 170
pre-handoff shape records. Two data timeouts exhausted four submissions
each with no shape flags: the first carried 1,019 TCP bytes in a 1,113-byte
MAC frame and the second carried 1,022 TCP bytes in a 1,116-byte MAC
frame. The other timeout was during TCP connect; its wired SYN matched
the firmware RX event and four exhausted SYN-ACK submissions before a
later successful hardware completion. That flow has no reported client
port and is outside the 170-submission audit count.

No pre-handoff shape error was detected in these timeout samples. The
checksum fix is independent and the retry-limit problem remains open.
The capture directories are
`build/hw-validation-allcore-tcp-dma-shape/logs/wired-tcp-*`.

The normal 833,312-byte image was then written to M0 only, with exclusive
erase end `0xDC000`. It contains the TCP byte-preservation and opt-in
snapshot changes, with no TCP trace linked in. Wired HTTP verified
advancing M0, D0, LP and enclave heartbeats both before and after the
hardware readback. The Mbed TLS backend reported state 2, 32,816 hardware
blocks, zero software blocks and zero timeouts. No Mac Wi-Fi settings or
D0/LP flash were changed in this run.

### TX completion during MAC recovery

The pinned IRQ table calls `txl_transmit_trigger` at slot 53. Its reset
handler keeps CPU interrupts disabled through the MAC and TX idle waits.
Nim bounds those waits, and the host service pump can call the TX trigger
with the MAC IRQ masked. Without an independent guard the poll could clear
a latched TX-ready bit or rearm the AC timer while recovery owns the queue.
The trigger now gates under its IRQ lock on both the TX reset flag and the
pending reset event. Host tests set each marker independently and also post
reset from status and confirmation callbacks.

Pinned `txl_cntrl.o:txl_transmit_trigger+0x9a/+0xb4` tests aligned DONE
words for both the primary wrapper and the successor at `wrapper+4`.
The old Nim build used four byte loads for the successor word; the new
all-core ELF uses `lw a0, 60(a3)` at `0x5806e2b8`. The vendor and Nim
use the same AC0 head and doorbell order with uncached DMA storage; neither
binary provides an explicit fence at that boundary. That comparison is not
a proof of bus ordering or peripheral visibility.

Pinned `hal_machw.o:hal_machw_init` at `0x08000d12..0x08000d3a` and
`0x08000dd0..0x08000e24` also takes a fresh register read to preserve the
bits outside each of three scaled timing fields (`0xE8`, `0xF4`, `0xF8`).
Nim now does the same; a fake MMIO test changes those bits between reads.

The 129 focused host cases passed. The all-core harness build and M0-only
anchor dry run passed; the 833,504-byte wrapped M0 image fits below LP,
with exclusive erase end `0xDC000`. None of these discrepancies explains
the prior retry-limit samples on its own.

#### Ox64 validation with JTAG detached

The UART anchor verified an M0-only write of that wrapper. D0, LP, and
Mac Wi-Fi were unchanged. The same 30 wired HTTP and ping probes ran
before replacement and after the candidate obtained its lease:

| Image | Valid `/wasm/cores` replies | Pings |
| --- | ---: | ---: |
| Prior byte-preserving build | 28/30 | 30/30 |
| MAC recovery candidate | 28/30 | 29/30 |

The first candidate boot completed the Frog join but missed the initial
readiness window waiting for DHCP. It subsequently leased
`192.168.1.114`. By then the host had queued three DISCOVER and six
REQUEST packets; lwIP had processed four incoming DHCP packets including
two offers. The final eight DHCP TX confirmations were seven
`0x80010701` retry-limit statuses followed by `0x80800001` success.
The normal confirmation ring does not identify which exchange owned
each attempt or what the AP received.

A second UART-anchor reboot without a persistent write reached the
HTTP listener in 9.312 s from the reboot request. This boot had one
DISCOVER, one REQUEST, two successful transmit confirmations and none
failed. Both boots reported zero hardware wait timeouts, connection-loss
indications and deauth indications in the sampled counters. The normal
station setup used the Mbed TLS hardware backend without fallback or
engine timeouts. The candidate remains installed.

This is a smoke test: recovery was not deliberately exercised, the two
boot timings do not establish a DHCP bound, and the HTTP loss did not
improve. Logs are in `build/hw-validation-allcore-mac-recovery-gate/logs/`:
`wired-smoke-{before,after}.json`, `candidate-startup.jtag-memory.log`,
`candidate-{post-probe,repeat}.json`, and `candidate-repeat-readiness.json`.

### DHCP transmit byte preservation

The pinned `bl_tx-short.o:bl_tx_push` copies the header and then each
pbuf segment with `memcpy` at `+0xf6` and `+0x122`; it does not replace
the UDP checksum. The BL808 lwIP smoke and HTTP builds already enable
`CHECKSUM_GEN_UDP`. The Nim transmit diagnostic used to overwrite that
field if the DHCP datagram fit in the first pbuf. It now only observes
the field and computes the expected value for comparison. The historical
repair counter is retained for bench capture compatibility but no longer
increments; before and after readings refer to the same unchanged field.

TX admission diagnostics now use the same bounded DHCP parser as RX and
TX completion. This locates the transaction ID and message type from the
IPv4 header size and ignores options outside the declared UDP length.
If a REQUEST spans pbufs, the trace can report its checksum field but uses
`0xFFFFFFFF` for the calculated and verified values if it cannot read the
entire UDP datagram. An RX outcome with no active DHCP client reports code
1 with zero metadata, not the previous client's state or transaction ID.

Radare2 also showed the previous TX diagnostic loading four source MAC
bytes with `lw` at Ethernet offset 6. The new RISC-V ELF loads the six
bytes with `lbu` and preserves their diagnostic packing. The host test
asserts the packed values. This does not establish a prior board trap.

The host regression drives `bl_output` through the TX queue and IPC copy
with both contiguous and split DHCP REQUESTs. It checks the entire frame,
including an omitted checksum, a deliberately incorrect checksum, and
variable-length IPv4 headers. It also tests trailing bytes that resemble
an option but sit outside UDP. This verifies ownership, byte preservation
and trace decoding, not the cause of the late lease or a change in radio
retry rates.

Both firmware targets built. The all-core correlation wrapper is
825,936 bytes; the M0-only dry run rounds the erase range to
`0x10000..0xDA000` (exclusive), below the Wi-Fi LP/D0 images. It overlaps
the resident USB anchor and its temporary app/peer images, so the dry run
does not authorize replacing that setup. No hardware was changed.

### Host TX progress under pool exhaustion

Pinned `bl_tx_try_flush` (`bl_tx-short.o`) consumes the station masks at
`+0x9c..+0xb6` before the descriptor/buffer lookups at `+0x114`, `+0x144`
and `+0x1b4`. On exhaustion the pinned algorithm can leave a station's
queue waiting for another trigger. Its `bl_tx_cfm` at `+0x114..+0x134`
sets a completion wake only for the station that owned the descriptor.
The Nim path inherited that behavior even though its pool is shared.

The host IPC shim now changes a resource stamp when a buffer or descriptor
actually returns to the pool. Flush retains a station bit when either
allocation fails and retries it after a resource return. An IPC reset
invalidates the parked bits, including when it reuses the same addresses.
The retry queue is selected ahead of fresh packets under the same lock
as allocation, rather than running two independent passes.

The host replay reproduces both faults: a second station stalls after a
completion for the first, and fresh traffic overtakes an older retry
when a descriptor returns between passes. The regressions also cover a
completion callback that reenters before its descriptor returns, buffer
exhaustion, repeated polls without returns, and IPC reset. This is host
progress evidence, not proof that pool exhaustion caused a Frog failure.

### Feedback after a rate trial completes

Pinned `me_tx_cfm_singleton+0x08..+0x16` converts a retry-limit completion
with seven retries into eight failed attempts. Pinned
`rc_update_counters+0x98..+0xd2` accounts attempts by rate slot before
checking trial state at `+0xd6..+0xf4`. In Nim the first completion could
move the trial to stage 3, causing a second in-flight frame from the same
trial to lose the attempts in its trial slot.

Nim now keeps this sample while the same trial chain remains installed
and its station, serial, sample epoch, policy and rate slot still match.
Only a frame completing the active trial can move it to stage 3. In the
host regression two `0x80010700` completions now produce eight failures
in each of the two slots, instead of eight and four. Old generations,
policy or rate changes, and a second station are checked separately.

The combined correlation build produced an 826,320-byte M0 wrapper
with exclusive erase end `0xDA000`. The M0-only write and the separate
JTAG-acknowledged RAM-anchor USB restore passed dry runs. The Wi-Fi write
would also erase the USB app and its temporary D0/LP images; the saved
app and both test peer binaries are needed to restore that setup.
No device write was made.

#### Ox64 candidate boots and USB restoration

The RAM recovery anchor passed ping, JEDEC `0x1860EF`, and reboot using
UART0 input with JTAG acknowledgments. The native USB anchor responded
again after that rehearsal. The verified M0-only candidate write then
used native USB; the regular Wi-Fi LP/D0 slots were not written.

| Candidate boot | Wired HTTP ready after reboot ACK | DHCP TX/RX | MAC retry counts (DISCOVER, REQUEST) |
| --- | ---: | --- | --- |
| Flash boot | Not timed | One DISCOVER/REQUEST, matching OFFER/ACK | 5, 6 |
| Reboot 1 | 8.764 s | One DISCOVER/REQUEST, matching OFFER/ACK | 5, 6 |
| Reboot 2 | 7.535 s | One DISCOVER/REQUEST, matching OFFER/ACK | 5, 1 |

All three boots joined Frog and published `192.168.1.114`. Every DHCP
submission was acknowledged by the MAC without host repush. Each boot
had a distinct XID, with both replies reaching the matching lwIP client.
The last two boots showed advancing M0, D0, LP and enclave heartbeats.
The last boot returned 30/30 valid `/wasm/cores` replies and 30/30 pings
over wired Ethernet, with JTAG detached during readiness and traffic.
One bounded halt/read/resume after each readiness check captured the
rings; neither ring wrapped. Transmit-pool starvation, hardware wait
timeouts and disconnects were not observed. This pass does not isolate
the earlier failure or prove that the fix eliminated it.

The saved USB wrapper was reinstalled using the JTAG-acknowledged RAM
anchor, then the saved USB app and both temporary peers were restored
over native USB. The native anchor probe and all five cooperative
all-core checks passed. The USB setup, not the Wi-Fi candidate, is now
installed. See `build/hw-validation-tx-resource-wake/` for the two wired
readiness reports, `boot*/dhcp-snapshot.json`, the wired probe report,
and the restoration logs.

#### What the cold transmit results show

Decode the saved rings without pairing replies to individual transmissions:

```sh
.venv/bin/python tools/analyze_wifi_dhcp_flow.py \
  build/hw-validation-tx-resource-wake/boot{1,2,3}/dhcp-snapshot.json
```

The trace reports four failed HT20 MCS7 short-GI attempts and a second
1 Mbps attempt acknowledged for each DISCOVER. In the first two boots,
REQUEST also used four HT attempts, then was acknowledged on its third
48 Mbps attempt. In the third boot, REQUEST started at 1 Mbps and was
acknowledged on its second attempt. No row reached the third or fourth
programmed rate slot in this profile. These are firmware retry counts,
not observations from the air. The decoder reports overwritten rows and
leaves unknown or conflicting policy samples undecoded. An XID groups
one DHCP exchange; it does not identify a radio attempt or prove a lease.

Radare2 shows the pinned `rc_init` and `rc_get_initial_rate_config`
selecting the same MCS7 short-GI primary for a common `0xff` MCS mask.
Native 1SS mode intentionally retains the negotiated third-slot MCS3
where pinned `me_update_buffer_control+0xe0..+0x116` can substitute MCS7.
That slot was not reached in these boots. The checked short-GI/preamble
bits, normal STA ACK control `0x2200`, and basic-rate programming also
match the pinned path. This neither checks transmitted signals nor
isolates ACK reception. The distinguishing evidence would be an air
capture of a failed uplink and any immediate ACK, matched to the
submitted descriptor and local completion. No rate policy was changed.

#### One cold boot paired with a monitor capture

The Mac's monitor was explicitly tuned to channel 11 before boot. A pilot
captured 18 records at 2462 MHz, including ten beacons from the selected
Frog radio. The final capture retained 341 headers, all at 2462 MHz, with
175 beacons from that radio. The Mac rejoined Frog on channel 36 afterward.

The new opt-in completion sidecar, `nimfw_dbg_dhcp_cfm_air_log`, tags the
prepared QoS MAC header by sequence control and TID. It validates the
hardware status and inline DMA header ownership before publishing. This
identifies a radio retry group without treating a DHCP XID as a frame ID.
The older saved snapshots remain decodable without this field.

In the cold boot the Ox64 took a lease at `192.168.1.114` and answered
wired HTTP. The matching TID 0 frames were DISCOVER sequence 2 and REQUEST
sequence 3. The firmware reported six attempts for DISCOVER, with success
in the 1 Mbps slot, and a first-attempt 1 Mbps REQUEST success. The monitor
retained one retry-marked DISCOVER and one REQUEST, both at 1 Mbps. It
retained no nearby ACK candidate for either, despite capturing ten other
ACKs addressed to the Ox64. This monitor missed some attempts and can miss
ACKs; the absence of a record does not tell us whether Frog heard the HT
attempts or replied. No rate behavior was changed by this diagnostic.

The initial native USB write failed after `0xB0000` verified bytes. The
mux reported a CDC write timeout and discarded its old PTYs. This does
not establish a CPU reset, a bad flash sector, or a radio fault. The USB
image was recovered. The same 826,704-byte candidate then fully verified
using physical UART input and JTAG acknowledgments, before the timed
monitor reboot. The saved USB anchor, app and temporary peers were
restored after this run; the regular Wi-Fi peer slots were not written.

Artifacts are under `build/hw-validation-dhcp-air-correlation/`.
Replay the one-boot match with:

```sh
.venv/bin/python tools/analyze_wifi_dhcp_flow.py \
  build/hw-validation-dhcp-air-correlation/boot/dhcp-snapshot.json \
  --air build/hw-validation-dhcp-air-correlation/cold-boot-ch11.pcap \
  --station b4:c2:e0:ac:96:f3 --ap 1c:36:bb:06:11:dc
```
