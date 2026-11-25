# BL808 Vendor Blobs

This file records the provenance for vendor archives that are used as hardware
validation references or temporary bridges while the native Nim paths are being
corrected.

## Stack Audit Status

The core-entry review corrected instruction parsing in `tools/audit_wifi_stack.py`:
raw objdump encoding columns had been treated as mnemonics, hiding call and
stack-pointer instructions. Earlier raw-byte audit results require revalidation.
The corrected audit completes 115 selected RF/delay/LO/configuration roots in
the HAL image and 149 in a separate build retaining low-power, BBA, CW and
RCAL entries, without overrides. It uses only stack-usage records with matching
compiled objects. The efuse chain uses at most 384 bytes, CW 128, and the
retained WL low-power initializer 672 within that scoped audit. Generic
`wl_init` and RF-core initialization still have three unresolved callback
calls; the retained BBA carrier-error path has two more. Their direct-chain
estimates are not stack bounds.
This does not establish whole-image or interrupt-nesting closure.

A fresh M0 WiFi HAL build with `-fstack-usage` produced
`build/wifi-stack-current/m0_firmware.elf` (SHA-256
`bf7e15fec80bb161acf30a00e30c2fa6f683e74204b42c2b020514aea1c8e33d`).
`build/wifi-stack-current/stack-audit.json` gives direct-chain estimates of
768 bytes for `wifiRfCoreInit` and 1,040 bytes for `txl_cfm_evt`, but marks both
incomplete. `wl_init` retains three configurable function-pointer calls;
the TX confirmation chain reaches indirect assertion logging. The three
formatter switch-table jumps are resolved in the ELF-hash-pinned
`build/wifi-stack-current/indirect-calls.json`, reducing the TX root from eight
unresolved sites to five. `g_bl_ops_funcs._log_write` is initialized to
`os_log_write` but remains mutable, so its five calls are not bound to that
initializer. These estimates are not stack bounds or flash-readiness evidence.

A later scan-only M0 build, `build/wifi-stack-next/m0_firmware.elf`
(SHA-256 `72e489298330c060b29c5d40cbd15933975ce26589073b9c616ecaeb3e45072d`),
uses the guarded no-callback WL startup path. Its
`build/wifi-stack-next/stack-audit.json` closes the selected
`wifiRfCoreInit` direct call chain at 752 bytes with no unresolved calls;
the callback-capable public `wl_init` is not retained in that image. This
image's `build/wifi-stack-next/stack-audit-tx.json` still marks
`txl_cfm_evt` incomplete: 976 bytes of direct chain and eight unresolved
indirect sites without bindings. The older formatter jump-table bindings
are pinned to a different ELF and cannot be reused without fresh address
evidence. Neither audit closes interrupt nesting, other build profiles, or
whole-image stack usage, and they are not flash-readiness proof.

A fresh scan-only M0 build from the current worktree is recorded under
`build/wifi-stack-audit-20261121/` (ELF SHA-256
`3db747aeeebe5e189fbcdfb17c73273071a91ae961dca678dc7241f0ba292ea1`).
Its unbound audit again closes `wifiRfCoreInit` at 752 bytes and leaves
`txl_cfm_evt` incomplete at 976 bytes with eight indirect sites. The three
formatter switch tables have 22, 7, and 7 entries in this ELF; every entry
is a decoded local instruction target. The ELF-hash-pinned
`indirect-calls.json` resolves those three sites, leaving five indirect
assertion-logging calls in `stack-audit-bound.json`. Their
`g_bl_ops_funcs` target is mutable, so the 976-byte direct-chain estimate is
not a stack bound. This image has not been flashed or hardware-tested.

A scan-only M0 rebuild after the internal-TX IRQ handoff change is under
`build/wifi-stack-audit-20261121-tx/` (ELF SHA-256
`c06be82ce9f3e71cbe559990d4ab372b71a2c060d34a77ab1dc86189211b7a7b`).
Its unbound audit again closes `wifiRfCoreInit` at 752 bytes and estimates
`txl_cfm_evt` at 976 bytes with eight unresolved indirect sites. The three
formatter switch tables contain 22, 7, and 7 entries in this exact ELF; all
19 distinct targets are decoded instruction starts inside the formatter.
The ELF-hash-pinned `indirect-calls.json` resolves those branches, leaving
five mutable assertion-log callback calls in `stack-audit-bound.json`.
Neither the 976-byte estimate nor this scan-only build proves TX-confirmation
stack closure, interrupt nesting, or hardware readiness.
If the log slot installed by `setupBlOps` remains unchanged, the separate
`indirect-calls-conditional.json` binds those five calls to
`bl808_nim_os_log_write` and `stack-audit-conditional.json` closes the selected
TX-confirmation chain at 1,024 bytes. The slot is writable BSS, so that result
is conditional and does not replace the unbound readiness result.

On that same ELF, an ISR-root audit with the conditional formatter/log
bindings estimates 656 bytes of direct chain for each WiFi MAC and IPC trap
trampoline, but leaves five and four indirect calls unresolved respectively.
They include `ipc_emb_notify`, the indexed `mac_irq` dispatch, and recovery
logging. The M0 vector wrapper saves a separate 160-byte frame on the same
stack; reserving it still does not make either ISR estimate a bound. A direct
audit of `trap_vector_entry` is likewise incomplete at its handler-pointer
call. This is evidence for the named build snapshot only, not the current
worktree or nested-interrupt stack closure.

## WiFi

- Local path: `src/bl808/libwifi_fw.a`
- Reference path: `tools/ref/libwifi_bl808.a`
- SDK source: `bouffalolab/bl_iot_sdk`
- Verified source commit: `b773b3f4bf6154125304a328c72bf2aa7168a715`
  (`[BL808] [APP] add bl808_demo_event support wifi`, 2023-04-21)
- Source path: `components/network/wifi/lib/libwifi.a`
- Git blob: `51aba70b5c76e5d2805072da1c5359068bf6ea83`
- SHA-256: `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7`
- The source archive at this commit and both local copies are byte-identical.
  This is a BL808 reference, not the later `wifi6` archive in `bouffalo_sdk`.

The [BL808 demo Makefile](https://github.com/bouffalolab/bl_iot_sdk/blob/b773b3f4bf6154125304a328c72bf2aa7168a715/customer_app/bl808/bl808_demo_event/Makefile)
selects this WiFi component together with `bl606p_phyrf`. Its PHY/RF archive
is `components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a`, Git
blob `a9935b475d2198000ae7b67d141f00767176a81a`. The BL808 standalone port
uses these as behavior references, not link inputs. The repository's
`src/bl808/librf_bl808.a` is BL616-derived and is a reference only for the
separate legacy RF profile, including coexistence and low-power work.

To verify an already-built standalone image against these pins, pass the
demo RF archive from the SDK checkout and the harness build location:

```sh
python3 tools/validate_rf_symbol_provenance.py \
  --bl808-demo-rf-archive "$BL808_DEMO_RF_ARCHIVE" \
  --hw-validation-test m0_wifi_nimfw_scan_hal_test \
  --hw-validation-work-dir build/hw-validation-bl808-demo-wifi
```

This checks the archive identities and retained Nim RF/PHY/MAC sections in
the image. It does not assert firmware-wide instruction or behavioral parity.

### Removed No-Op Exports

The pinned archive has no `vif_mgmt_add_to_list`,
`vif_mgmt_switch_channel`, or `ipc_emb_msg_handler` symbols. No in-tree
caller references these Nim-only exports. The first two silently discarded
VIF work; the third claimed to handle incoming IPC messages but was never
installed as a callback. Their no-op definitions and forward declarations
were removed. The focused VIF source-policy test and the NimFw boot-image
build pass; this removes misleading API surface, not a live vendor behavior.

The same archive and in-tree call-site check found seven more Nim-only,
unreferenced no-op exports: `td_recovery_ind`, `ps_traffic_null_1_recovery`,
`mm_send_csa_traffic_ind`, `mm_sta_timer_bcmc_timeout`,
`chan_survey_timer_end`, `chan_send_scanning_stop`, and
`scanu_dump_scanresult`. Their definitions and two forward declarations were
removed. Archive-backed return-only exports remain intact.

`bl_pti_reset` was another Nim-only, unreferenced export, but unlike those
no-ops it wrote a guessed PTA/MMIO reset sequence. None of the pinned BL808
WiFi, RF, or BLE archives defines the symbol, and no in-tree caller uses it.
The speculative reset body was removed; this does not remove the archive-backed
coexistence force controls.

`td_timer_evt` was likewise a Nim-only, unreferenced wrapper around
`td_timer_end`. The pinned archive has no `td_timer_evt` symbol, and
`td_reset` already installs `td_timer_end` as the timer callback. The wrapper
and its forward declaration were removed without changing that callback.

### MAC IE Search Bounds

Radare2 of the pinned `mac_ie.o` shows `mac_ie_find` at
`0x08000034..0x0800004f` checks an IE ID before its declared length, and
`mac_vsie_find` at `0x08000066..0x080000c3` compares OUI bytes before
checking the element length. A matching truncated element can therefore be
returned to callers in the vendor path. Nim retains complete-header,
declared-length, and buffer bounds checks before returning either pointer;
this is an intentional safety difference for untrusted management frames.
The vendor-IE overrun diagnostic is preserved when a declared length runs
past the supplied buffer. Focused IE-search, scan-admission, beacon, and
rate-extraction tests cover valid matches and malformed tails. The broader
scan and on-air behavior remain unverified.

### IPC Message Admission

Radare2 of pinned `ipc_emb.o:ipc_emb_msg_evt` shows two destination checks:
IDs above 10 reach the first assertion, while IDs 9 and 10 reach a second
assertion at `+0x11c..+0x120`. Nim rejects all IDs above 8 before allocation
because its assertion handler requests reset and returns; it must not then
dispatch an invalid message. At `+0xca..+0xd6`, the vendor increments the
shared message counter and stores only its low byte, so 255 wraps to zero.
Nim's existing `uint8` addition has the same behavior, confirmed by a new
boundary regression in checked, release, and ASan modes. This does not
validate host-to-device traffic.

### IPC Task Callback Availability

Radare2 of the pinned `ipc_emb.o` shows that `ipc_emb_notify` asserts when
`ipc_emb_env` is nil, then calls the operation at slot `0x4c`; `ipc_emb_wait`
calls slot `0x50` with the task handle and increments `ipc_emb_counter` only
after that call returns. The archive assumes those operation slots are present.
Nim now rejects a missing task handle or operation callback during init,
notify, and wait, requesting recovery instead of calling through nil. A
failed wait does not increment the counter. Focused native tests cover these
recovery branches and the normal callback path; this does not establish
on-device IPC timing.

### Kernel Event Bitmap Ownership

The pinned `ke_event.o` loads and stores the event bitmap at `ke_env+0` in
`ke_evt_set`, `ke_evt_clear`, and `ke_evt_schedule`. The Nim firmware kept a
second `keEvtField` word and mirrored only its own set/clear writes to
`ke_env`. That let the scheduler, idle checks, and C-side wait logic observe
different pending work if another owner updated `ke_env` directly. Nim now
uses `ke_env+0` for all event readers and writers and removes the duplicate
word. Focused native tests cover direct `ke_env` publication, priority
dispatch, reset preemption, RX and TX events, and beacon events. The scan-only
M0 profile builds; no hardware timing or interrupt-nesting behavior was
validated by these checks.

The pinned `ipc_emb.o` TX flow-off/on and TX IRQ bodies write the same
mask/event sequence as Nim. `ipc_emb_tx_evt` calls `txu_cntrl_push` before
marking the wrapper active and popping the host list. Nim deliberately
publishes active ownership and removes the node before that reentrant call;
the host-publication test requires this order so a synchronous completion
cannot recycle a still-listed wrapper. The message-event body agrees on the
ID/destination/source fields, counter byte, event write, and IRQ re-arm.
Nim rejects invalid destinations before allocation and bounds the payload
length. The archive allocates first and continues after its invalid-destination
assertions. Focused IPC flow/allocation tests pass; these checks do not
establish device-side DMA timing.

### Queue Comparator Link Ordering

In the pinned `ke_queue.o:ke_queue_extract`, the comparator call at `+0x1c`
precedes the first load of the current node's `next` link at `+0x1e`.
The matching branch reloads that link at `+0x2a`; the nonmatching branch
advances using the post-callback value. Nim previously captured `next` before
the comparator, so a callback that relinked the current node could extract or
visit the wrong element. Nim now reads the link after the callback. A focused
native test covers matching and nonmatching relinks in checked, ASan, and
firmware-like modes; the scan-only M0 WiFi image compiles. Existing in-tree
comparators do not intentionally relink nodes, and this static comparison does
not establish concurrent queue behavior or on-device execution.

### System Clock Gate Before Runtime Tables

The pinned `sysctrl.o:sysctrl_init` writes `0x8000000C` to MAC-PL `+0x68`,
then reads, ORs with `0x1FF00`, and writes MAC-PL `+0xE0`. Nim previously
called `wifi_fw_runtime_init` first; that call runs `PreMain` and populates
event handlers. The MMIO helpers are direct volatile loads/stores and need no
Nim runtime setup, so Nim now performs the vendor register sequence before
its required runtime and task-table initialization. An ordered-call test passes
in checked, ASan, and firmware-like native modes. The scan-only M0 image
builds, and linked radare2 disassembly confirms both MMIO writes precede the
two initialization calls. This checks ordering, not powered-device behavior.

### Supplicant WPS Mode Storage

In `supplicant_api.o`, both WPS status accessors relocate to `sm_env+0x2c`,
the same byte read by scan-result processing, STA key setup, association, and
EAPOL dispatch. Nim previously kept a separate `wpsStatus` byte, so the public
setter did not change those WPS-mode branches. The accessors now use
`SmEnvView.state` at offset 44 and the duplicate storage is removed. A focused
ABI test checks the shared byte in checked, firmware-like, and ASan modes; an
EAPOL test calls the exported setter before verifying WPA/WPS routing. The M0
NimFw boot image compiles, but no device was flashed for this change.

### Supplicant Application IE Storage

Radare2 of `supplicant_api.o:bl_wifi_set_appie_internal` shows IE kind 1
writing the pointer and length at `scanu_env+232/+236`, and kind 2 writing
them at `sm_env+48/+52`. These are the scan probe-request and STA association
IE fields read by the corresponding builders. Nim had instead written
AP beacon and probe-response globals, leaving both STA paths unchanged and
incorrectly changing AP output. The setter now uses the existing typed
`ScanuEnvObj` and `SmEnvView` fields; the focused ABI test checks storage,
length rejection, and unset behavior. Nil data with a nonzero length remains
rejected as a safety guard beyond the archive's length-only check.

The pinned `me_mgmtframe.o` beacon and probe-response builders end after the
standard security/HT/WMM IE paths and do not read AP application-IE globals.
Nim's former AP append and size-prediction branches have been removed. The AP
start request's `extraIes` path still appends host-provided beacon IEs; its
focused startup test verifies those bytes. Beacon/probe serialization and
bounded probe-response tests cover the remaining builders.

### AP Host Interface Lifecycle

The pinned SDK manager registers a separate AP interface before sending
`APM_START_REQ` and unregisters it after `APM_STOP_CFM`. Radare2 of the
matching `apm_task.o` shows the start handler reading request byte 51 at
`0x08000770` in the relocatable object and requiring firmware VIF type 2
at `0x08000786..0x0800078a`; the wrong-role status is 4. The old Nim
host manager skipped interface registration and sent the zero-initialized
AP slot's index. The command transport could succeed while firmware
rejected the STA VIF, so the old start/stop API smoke was not beacon proof.

The Nim manager now registers the AP's own lwIP netif at `192.168.11.1/24`
without replacing the STA default route. It derives a distinct AP address
using the last-byte bit allowed by `mm_hw_info_set`'s shared MAC mask.
Startup uses the assigned firmware VIF index and checks the status and
index in `APM_START_CFM`. A failed remove keeps the host binding for retry;
the interface is not advertised as ready after a confirmed stop. Host tests
cover differing host and firmware indices, rejection and absent start
confirmation, and rollback and restart. The scan smoke now also checks
that the AP netif is distinct and goes away after stop. Client association,
DHCP service, and a setup page are separate hardware milestones.

Pinned `apm_task.o:apm_start_req_handler` copies request byte 52 into
`apm_env+85`; `apm.o:apm_embedded_enabled` reads that byte on both the
wildcard and AP-VIF branches. Nim's receiver previously checked an
unrelated global, so a successful AP start did not enable receive-side
probe, authentication, or association dispatch. The Nim accessor now
reads the same state that startup and teardown update. Its focused host
test sends a normal first authentication request through the production
RX gate with the embedded flag both enabled and disabled.

On Ox64, `MM_ADD_IF_CFM` initially reported status 1 and the AP trace
stopped at the shared MAC comparison, before `APM_START_REQ`. The linked
HTTP image showed the manager writing `netif->hwaddr` at byte 50 while
`bl_main_if_add` read from legacy byte 58. The host accessor now uses the
lwIP C field when built against real lwIP, retaining the raw offset only
for the legacy layout. The lifecycle fixture checks the address actually
passed to the command in both layouts.

The manual `m0_wifi_ap_http_smoke` manifest enables a password-protected
bench-only AP, the pinned SDK DHCP server with a small pool, and a fixed
HTTP response at `192.168.11.1`. It does not collect or store credentials.
The host probe must separately verify the lease and the HTTP response;
the firmware's startup markers alone do not establish either one.

After interface registration succeeded on Ox64 (MM status 0, firmware
VIF 1), the next command returned `-ETIMEDOUT` at 262.725 ms. The WPA
registration callback alone accounted for 257.756 ms. At return,
`ME_SET_ACTIVE_REQ` was on the sent queue, never entered its handler,
and had not yet reached beacon submission. The MM-timer event was not
pending in the snapshot at command return.

This Wi-Fi image links the software Mbed TLS SHA-1 module, not Bouffalo's
optional hardware SHA-1 backend. The pinned generic HMAC reset and finish
paths recompress the two keyed pad blocks on each PBKDF2 iteration.
`wifi/wpa2_pmk.nim` reuses the two pad states within a single WPA2
derivation, following [RFC 2104 section 4](https://www.rfc-editor.org/rfc/rfc2104.html#section-4).
It uses the same SHA-1 compression, 4,096 iterations, and 32-byte PMK,
and clears its intermediate states before returning. The host test
compares the full PMK to Python's independent PBKDF2 implementation in
checked, release, and AddressSanitizer builds. The bench smoke records
both the WPA registration callback and full command timings and rejects
a command at or above the original 200 ms budget.

The optimized smoke image measured 119.294 ms inside WPA registration
and 127.488 ms for the complete AP-start command at the original timeout.
It also reached DHCP/HTTP readiness. The laptop's scan did not find the
bench SSID. JTAG read a beacon template with the visible SSID, an active
AP VIF, and a beacon pending count that changed from one to zero between
reads. That shows submit-path progress, but does not distinguish a
successful transmit from a flush.

The follow-up AP DMA probe separates an AC4 arm from a MAC writeback and
from a software flush. With periodic JTAG log polling, the 18 s snapshot
recorded 155 arms, 47 normal completions marked successful by the MAC,
and 107 flushes, 76 of which already had the hardware done bit. One was
still pending. After the failure snapshot and resume, with no periodic
JTAG polling, the next snapshot added 554 arms and 553 normal successful
completions. Do not use completion loss in a polling run as an on-air
failure rate. A targeted CoreWLAN scan still found no bench SSID. A
control on the same Mac found two results for the known upstream SSID
and two channel-11 scan entries. The 190-byte beacon template parsed
through its last IE with the expected SSID, channel 11, and CCMP/PSK
RSN information. The dumps are under `build/hw-validation-wifi-ap-http-beacon-dma/`
and `build/hw-validation-wifi-ap-http-beacon-bytes/`.

The same AP image was then replayed without recurring JTAG halts. A Mac
tuned to channel 11 captured 52 Ox64 beacons and 184 beacons from the
known upstream AP in eight seconds. A second capture retained only Ox64
beacons: 56 complete 194-byte MPDUs, including all four FCS bytes, passed
an independent CRC-32 check. Four shorter receives failed CRC and were
marked bad by the receiver. Valid beacons used 1 Mb/s, had advancing TSF
timestamps approximately 100 TU apart for consecutive frames, and
carried the expected SSID. The owned capture is under
`build/hw-validation-wifi-ap-air-capture/ox64-ch11-beacons.pcap`.

With the Mac back in station mode, a broad scan found the bench SSID,
though an SSID-targeted scan still returned no match. An explicit WPA2
join succeeded: DHCP assigned `192.168.11.20` from `192.168.11.1`, and
HTTP requests bound to the Mac's Wi-Fi interface returned 200 and
`Ox64 setup AP`. Ethernet remained the default route. This verifies the
AP data path, not targeted discovery or a credential provisioning and
persistence flow.

The original AP image was flashed again after removing the saved test
network from macOS. The operator confirmed that `Ox64-Setup-Bench`
appeared under menu-bar Wi-Fi > Other Networks without joining. The
earlier scan miss was not reproduced in that menu and its cause was
not established. The all-core station image does not start this AP.

In pinned `apm.o:apm_probe_req_handler`, the IE lookups at `+0x42` and
`+0x78` examine the SSID and DSSS Parameter Set only. The reply at
`+0x82..+0xa0` uses the requester at indication byte 42 without checking
the receiver and BSSID. The wildcard-VIF path at `+0xa4` only selects the
AP to consider; it does not substitute for those address checks. Nim
now checks both addresses against the single infrastructure AP or the
broadcast address, requires the SSID and Supported Rates elements, and
recognizes bounded, nested SSIDs in the optional SSID List. See IEEE
802.11-2012 Table 8-26 and sections 8.4.2.2, 8.4.2.3, 8.4.2.75,
10.1.4.1 and 10.1.4.3.2. The vendor's hidden-SSID policy and DSSS
channel check remain in place. The regression exercises the real APM
dispatcher and parser, including malformed lists and VIF retirement
during SSID comparison. This is not a diagnosis of the earlier menu miss.

The rebuilt `Ox64-Setup-Probe` image was tested on channel 11 after a
verified M0-only UART-anchor flash. AP startup took 127.646 ms, of which
119.445 ms was WPA registration. Three early directed/broadcast scan pairs
missed the AP despite the upstream control being found. A subsequent
16-second capture contained 121 CRC-valid Ox64 beacons and no captured
Ox64 Probe Responses. The capture was in monitor mode, not concurrent
with the Mac's directed scans. Later, three directed scans with hidden
results included and three ordinary directed/broadcast scan pairs all
found the AP. This confirms working discovery on the rebuilt image, not
the cause of the initial misses or an on-air test of the SSID List path.
The owned capture and JTAG readback are under
`build/hw-validation-wifi-ap-probe-eligibility/`.

### AP Discovery Frame Order

In the pinned `me_mgmtframe.o`, `me_build_beacon` and
`me_build_probe_rsp` emit Extended Supported Rates before the DSSS
Parameter Set and RSN before ERP. `apm_task.o:apm_start_req_handler+0x312`
appends the host extras to the finished Beacon; `apm.o:apm_send_mlme+0x110`
appends the saved copy to the finished Probe Response. All 121 valid
Beacons in the previous bench capture carried the resulting IE sequence
`0,1,50,3,5,48,42,45,61,221,7`.

The Nim embedded-AP builders now follow the relative order in IEEE
802.11-2012 section 8.3.3.1 and Tables 8-20 and 8-27 for the implemented
2.4 GHz discovery elements. The Country TLV goes after TIM in Beacons
and after DSSS in Probe Responses; ERP precedes Extended Supported Rates
and RSN. The existing TIM offset still points to the live TIM splice.
Other extras retain their relative order and bytes. A bounded TLV walk
rejects truncated/duplicate Country and bad triplet or padding lengths
(section 8.4.2.10). The immediate start-abort path clears the saved extras.
The focused host tests check exact element order, frame bounds, the
ownership checks around Probe Response publication, and FCS length
accounting. Requested Elements handling and arbitrary externally supplied
Beacon templates are outside this change.

The `Ox64-Setup-Order` image booted after a verified M0-only UART-anchor
flash. AP startup took 127.707 ms including 119.500 ms WPA registration.
All 83 independently CRC-validated Beacons in the channel-11 capture
had IE IDs `0,1,3,5,7,42,50,48,45,61,221`. The Country payload was
unchanged (`55 53 20 01 0b 14`). Five other captured frames failed the
CRC check, and no Probe Response was captured. The capture was not
concurrent with client scans. The Mac found the AP in all six broad
scans but in none of six ordinary directed scans or three additional
directed scans with `includeHidden`. Firmware counted 87 Probe Requests
in total; that counter does not identify their senders, APM admission,
or response TX. The order correction is verified for the on-air Beacon
but does not explain the directed-scan misses. Artifacts are under
`build/hw-validation-wifi-ap-ie-order/`.

The pinned `apm.o:apm_set_bss_param+0xe0..+0xe8` reads the RF band
from byte 16 of the start request and stores it in byte 5 of the MM
basic-rate request. Nim now sets that field explicitly. This does not
change the supported 2.4 GHz result. The AP-start confirmation's byte
2 is named for the channel-context index, as in the SDK header, not for
the RF band. A host test poisons the outgoing rate-band field before
the builder fills it and verifies the two fields independently.

### AP Probe Path Trace

`bl808WifiApDiscoveryDiag` exposes `nimfw_ap_probe_trace`, four rows of
17 words in unknown, wildcard, named, and other order. Each row records
admitted RXU ingress, APM entry and its terminal eligibility outcome,
response build and submission, and final TX completion. It matches the
local SSID without logging a client address or changing the TX callback.
TX completions use generation tags; an uncorrelated completion goes in
the unknown row rather than being attributed to a new frame. The
aggregate DSSS-gate counter does not carry the requested channel, but
`nimfw_ap_probe_dsss_trace` records it separately for named requests.
That history has a count and 32 three-word samples: sequence, four bytes
(reason, IE length, requested channel, configured channel), and two
halfwords (RX tuned MHz, AP configured MHz). RX MHz is a snapshot of the
receiver's software PHY state, not a measurement of the sender's RF.

Pinned `rxu_cntrl.o:rxu_mgt_frame_check+0xd0/+0x460/+0x492` preserves the
reported length for Probe Requests, as does Nim. Neither path strips an
FCS at this point. The pinned APM checks SSID and DSSS but need not parse
the whole tail after both checks succeed. Do not infer that the RX
length includes FCS or loosen Nim's bounded parser from this difference.
The pinned TX completion handler and Nim both use slot 53 and check
descriptor bit 31; success for the ACK-requesting management response is
bit 23. Queue submission is not proof of that completion.

The fresh `Ox64-Setup-Trace` image started the AP on channel 11 in
127.658 ms including 119.231 ms of WPA registration. Five ordinary
directed scans and three directed scans including hidden results all
found the AP. Across those two snapshot windows, 14 requests naming
the local SSID reached RXU and APM. Ten stopped at the DSSS gate; all
four remaining responses were submitted, completed, and marked ACKed
by the MAC. Five broad scans also found the AP, without an RXU probe
count change in that window. A separate monitor capture contained 128
CRC-valid, ordered Ox64 Beacons and no Probe Response. This proves the
live response path can succeed; it does not reproduce the earlier miss,
validate Probe Response TSF on air, or identify the ten requested
channel values. Artifacts are under `build/hw-validation-wifi-ap-probe-trace*`.

The pinned `apm.o:apm_probe_req_handler+0xc8..+0x108` reads the AP's
operating-channel descriptor and divides the in-range frequency by
five after subtracting the band base. It can round off-grid frequencies
and can match DSSS channel zero against an invalid channel conversion.
Nim now uses the exact channel-grid conversion, rejects invalid AP
configuration even when the request omits DSSS, and refuses to write a
Probe Response carrying channel zero. Normal comparisons still use the
configured AP channel, not the RX tune snapshot. Checked, release and
ASan tests cover off-grid and missing channel state, valid channels,
and rejecting an invalid response before writing any bytes.

After an M0-only UART-anchor flash, `Ox64-Setup-Channels` started in
127.580 ms (119.207 ms inside WPA registration). All eight targeted
and all five broad scans found it. Both capture windows retained all
13 named DSSS samples: three declared channel 8, three channel 9, four
channel 10, and three channel 11. All were one-octet DSSS elements; the
AP was configured for channel 11 and the receiver snapshot was 2462 MHz
in every sample. The three channel-11 requests all queued and completed;
two responses were ACKed and one was not. The ten valid declared-channel
mismatches explain those rejections without evidence of an incorrect
local configuration. They do not prove the sender's actual RF channel
or explain the earlier intermittent scan misses. JTAG artifacts are
under `build/hw-validation-wifi-ap-probe-channels*`.

### Management Security IE Bytes

Radare2 of `me_mgmtframe.o:me_add_ie_rsn` and `me_add_ie_wpa` confirms that
security modes 1 and 2 emit the 22-byte CCMP/PSK and 26-byte TKIP+CCMP/PSK
RSN IEs, while only mode 2 emits the 30-byte legacy WPA IE. Other modes
return zero without advancing the output pointer. Exact-byte host tests now
check those forms and the no-op modes in checked, release, and ASan builds.
The reference WPA writer advances by 30 bytes but leaves its final two
capability bytes unwritten; Nim explicitly zeros them to avoid publishing
stale buffer contents.

`apm_start_req_handler` previously admitted nonzero security modes above 2,
then registered a PSK authenticator even though both archive IE builders emit
no security IE for those modes. Nim now rejects those requests before AP state
or channel setup. The public application-IE wrapper rejects out-of-range VIF
indices for IE kind 0, and the underlying void setter also ignores invalid
indices and nonzero-length nil data instead of writing outside the VIF table
or publishing an inconsistent IE pointer. Focused AP-start and setter tests
cover rejected modes 3/255, accepted mode 2, the two VIF boundaries, and nil
data in checked, release or firmware-like, and ASan host builds. The full
NimFw M0 boot image links; this does not establish an over-the-air AP handshake.

### MM Timer Head Ownership

The pinned `mm_timer.o:mm_timer_hw_set` programs or disables the absolute timer
for the pointer it receives. Nim's scheduler releases IRQs before this call, so
an empty-list snapshot can become stale when a timer is inserted in that gap.
The local hardware-set helper now checks the supplied pointer against the
current queue head under its IRQ lock. A focused reentrant test shows the old
nil call disabled the IRQ after a new head had been armed; the head check keeps
the new deadline and unmask bit intact. This is a Nim-side ownership guard,
not behavior in the archive.

At `mm_timer_hw_set+0x1a..0x30`, the archive skips both unmask-register writes
when bit 7 is already set. Nim previously rewrote the unmask status register
on every non-nil call. It now writes the set and status registers only on the
masked-to-unmasked transition; a native MMIO trace checks the already-unmasked
branch in checked, release, and ASan modes.

The analogous `ke_timer.o:ke_timer_hw_set+0x4e..0x64` branch also skips its
unmask-status write when timer IRQ bit 8 is already set. Nim now does the same;
a focused native register trace covers masked enable, already-unmasked update,
and nil disable. This preserves the archive's MMIO write sequence.

`chan.o:chan_upd_ctxt_status+0x2c` uses a zero absolute deadline as a
no-timer sentinel. That also matches a real deadline at MAC-clock rollover.
Nim uses the resulting channel state to decide whether to arm;
`mm_timer_hw_set+0x06..0x0e` already distinguishes disabled by a nil pointer,
not by the timestamp. A deadline reached during MM timer programming is due
even when the second clock sample equals it. Scan and ROC request admission
reject durations that cannot fit the 16-bit dwell slot; nonzero durations
shorter than one 1024 us slot use one slot.

### RX Resume After MM Teardown

The pinned `ke_task.o` clears `rxl_cntrl_env.processingFlag` when MM enters
IDLE, but does not set the RX control event. The pinned `rxl_cntrl.o` clears
that event before returning when the processing flag is set. Thus a frame
already queued during teardown depends on a later RX interrupt for progress.
Nim now re-arms the RX event when MM enters IDLE with a nonempty RX queue,
including an already-IDLE state call. The flag clear, queue check, and event
publication occur with interrupts masked. This intentional liveness difference
does not alter frame admission or descriptor ownership.

### AP Power-Management Ordering

The `rxl_cntrl.o` AP branch applies the station sleep/wake transition before
reading a QoS TID for U-APSD trigger handling. Nim previously rejected
reserved TIDs 8-15 first, leaving the station's power-save state unchanged.
Nim now applies the PM transition before rejecting a reserved TID as a U-APSD
trigger. The trigger itself remains rejected, rather than indexing the
eight-entry TID-to-AC table with a reserved value. The focused RX power-save
test covers both transitions for all eight reserved TIDs.

### AP Beacon TIM Ownership

For AP beacons, radare2 of `me_mgmtframe.o:me_add_ie_tim` shows writes only
to TIM IE bytes 0 (ID), 1 (length), and 3 (DTIM period). Nim now leaves bytes
2, 4, and 5 in the template untouched. `mm_bcn_update` excludes that template
TIM range from its DMA descriptor chain and inserts the separate live TIM
descriptor. A focused test seeds the template's unwritten bytes with nonzero
values and checks that the live TIM pool retains its own count and bitmap.
`mm_bcn_init_vif` still zeros the live pool's empty partial-bitmap byte; the
vendor object does not initialize that byte, but advertising stale buffered
traffic would violate TIM semantics.

Radare2 of `mm_bcn.o:mm_tim_update_proceed` shows the TIM confirmation call
before the tail-call that frees the request. Nim now preserves that lifetime
order for both immediate updates and rejected stale requests. A focused test
checks that confirmation has already been published when the free callback
reenters allocation; the TIM lifetime and beacon-update suites pass in their
host modes, and the M0 Nim-firmware boot profile links the updated functions.

Radare2 of `vif_mgmt.o:vif_mgmt_set_ap_bcn_int` shows an unsigned `divu`
at `+0x66` for each active AP's beacon divisor. The MM request handler does
not reject a zero interval. On RV32, division by zero returns an all-ones
quotient, so the vendor stores `255` in each divisor byte; the Nim host path
previously produced a different value. The local implementation now handles
that case explicitly and keeps the normal low-byte truncation. A focused
two-AP native test covers both interval orderings, zero, and quotient 256 in
checked and firmware-like modes. This preserves the archived behavior; it
does not make zero a useful operational beacon interval. The integer-division
rule is specified in the [RISC-V M extension](https://docs.riscv.org/reference/isa/v20240411/unpriv/m-st-ext.html).

### Station Power-Save TIM Handling

Radare2 of pinned `ps.o:ps_check_beacon` shows that a set AID bit, active
VIF power-save flag, or buffered multicast flag calls `td_pack_tim_ind` before
setting VIF bit 6. With no buffered AID, all-AC U-APSD clears VIF bit 3;
other U-APSD configurations clear bit 2 instead. The non-WMM branch logs
`BCMC: Set` or `BCMC: BCN CLR` before changing VIF bit 1. Nim now preserves
these conditions and ordering for valid TIM IEs. It now rejects a TIM IE shorter
than four bytes before reading its bitmap-control byte or changing VIF state,
and rejects a null VIF or out-of-range station index. The vendor code has no
such guards.

Radare2 of `mm.o:mm_check_beacon` shows `mac_ie_find` followed by an immediate
DS channel-byte load without a DS payload-length check. Nim now admits the
complete beacon IE stream before MM beacon state changes, requiring a one-byte
DS payload and at least four TIM payload bytes. Invalid arguments, malformed
IEs, and off-channel beacons return `high(uint32)` instead of the valid
unchanged-beacon result `0`; `rxl_cntrl_evt` releases those frames before its
power-save, beacon-watchdog, TBTT, and upper-RX callbacks. The RX traffic
counter still runs before MM admission, as in the vendor ordering. Focused
native tests cover rejection and valid unchanged beacons in checked, release,
and ASan modes; this does not establish on-air behavior.

In pinned `mm.o:hal_machw_rx_duration`, `+0x6c` polls READY,
`+0x78` reads it again, and `+0xac` reads the duration from the
low halfword of a fresh register sample. The Nim path previously reused
the READY recheck as the result. The regression gives those reads
different values and checks the result through the beacon timing path.
The bounded timeout and rejection of reserved RX rate codes are unchanged.

`mm.o:mm_check_beacon+0x308..0x324` compares the unsigned inter-beacon gap
against the maximum, then rejoins the code that clears the STA probe counter
and updates its last beacon time. Nim previously ran those two updates only
for the first beacon. The regression covers successive accepted channel-9
beacons, equal gaps, and timestamp rollover.

`ps_check_frame` in the same object handles group-address and A-MSDU exits
before reading QoS control. Nim now does likewise, but continues to reject
reserved TIDs 8-15 on active unicast paths rather than aliasing them to the
vendor's low three bits. Focused TIM, RX power-save, and EDCA tests pass in
checked, release, and ASan modes; the M0 Nim Wi-Fi image builds. The review
also checked the confirmation handlers and selected rate-control helpers,
without establishing exhaustive equivalence or hardware readiness.

The vendor calls `td_pck_ps_ind` before a possible PS-Poll or VIF flag clear,
and calls the platform logger before a possible dynamic-PS transition. Nim
now rechecks VIF lifetime after the traffic callback and PS mode after the
logger, so synchronous teardown cannot operate on retired state. Focused
checked, release, and ASan tests inject teardown at both callback boundaries.
These guards intentionally differ from the unprotected vendor flow.

The same `ps.o` confirmation handlers call timer clear/set, the PM hook,
the platform logger, and PS-mode completion before later VIF accesses. Nim
now captures the VIF/reset generations and stops when those calls retire the
VIF or reset the firmware. Native confirmation tests inject retirement at
each callback boundary in checked, release, and ASan modes. The M0 Nim WiFi
profile compiles, but its minimal image may dead-strip these handlers; this
is not hardware validation.

In `ps.o:ps_set_mode`, the disable branch stores zero to `ps_env+52` (the
flags byte), not `ps_env+0`; the relocation addend is necessary to distinguish
them. The vendor loops in `ps_set_mode` and `ps_dpsm_update` branch back without
advancing past a non-STA VIF. Nim advances past it so a mixed STA/AP active
list cannot hang, and passes only the last visited STA to synchronous
completion. A skipped AP must not receive the STA power-save confirmation
state update. Mixed-list regressions cover both loops, VIF orders, and mode
directions.

The exported `ps_uapsd_set` and `ps_check_tbtt` hooks now reject a null VIF;
`ps_uapsd_set` also rejects AC values outside the four 802.11 access
categories. The MM EDCA caller already validates those values, but a direct
call with an invalid AC could previously arm the U-APSD timer without enabling
an AC. The vendor routines dereference the VIF and do not validate AC bounds.
Focused checked, release, and ASan tests cover the guards and valid timer path.

The vendor `ps_tx_null_timer_handle` zeros the pending-null count, completes
the PS transition, then calls `txl_cntrl_clear_ac(3)`. Nim preflights the halt
and now completes only after `txl_cntrl_clear_ac` succeeds. While flushing,
the pending count is zero so aborted null-frame callbacks cannot complete the
same transition; a failed clear restores the count and leaves completion
unpublished. Focused halt-lifecycle tests cover both halt and clear failures,
plus real PS confirmation callbacks invoked during the flush, in checked,
ASan, and firmware-style builds.

### Association Rate Admission

The pinned `me_mgmtframe.o:me_build_associate_req` calls the Supported Rates
writer without checking for an empty rate set. Nim now rejects an empty set
before publishing the station BSS configuration batch and again in the
association-request builder. A selected BSS with no Supported Rates IE, or
with a zero-length one, cannot produce a valid association request: IEEE
802.11-2012 section 8.4.2.3 defines the element's information field as
[1 to 8 octets](https://mrncciew.com/wp-content/uploads/2014/10/ieee-802-11-2012.pdf).
This is a protocol guard beyond vendor parity. Focused checked, release, and
ASan tests cover both rejection boundaries and the valid-rate startup path;
the Wi-Fi HAL build-only check passes. On-air behavior remains untested.

The same pinned association builder accepts a zero-length SSID and emits the
WMM vendor-specific IE before HT Capabilities when both are enabled. Nim now
rejects an empty association SSID and emits HT Capabilities before WMM. IEEE
802.11-2012 sections 8.4.2.2 and 8.3.3.5 reserve the zero-length wildcard
SSID for Probe Requests (and mesh Beacon/Probe Responses), and place
vendor-specific elements after the standard association elements in
[Table 8-22](https://mrncciew.com/wp-content/uploads/2014/10/ieee-802-11-2012.pdf).
The focused encoder tests cover the valid combinations and both rejected
empty fields; these are protocol-order corrections beyond vendor parity.

### Rate Neighbor Selection

In the pinned `rc.o`, the HT branch of `rc_set_next_mcs_index` skips the
legacy increment at offset `+0x58`; its increment at `+0x88` checks the
immediate successor's bitmap bit. Nim and the hand-transcribed test model
select that `+1` candidate. The local guard rejects candidates above MCS 7
before shifting the byte bitmap. The 12-profile, 65,536-input-per-profile
neighbor matrix and the downstream rate-sample test cover this behavior.
This does not establish all rate-control parity or on-device throughput
behavior.

In the pinned `rc.o:rc_check`, trial setup reads retry indices at stats
offsets `0x80`, `0x88`, and `0x90`; restoration copies the first two steps
and the backup at `0xa0`. It never reads the fourth retry index at `0x98`.
Nim's safety preflight had rejected both transitions when that unused slot
was invalid, and had also required the third slot during restoration. The
preflight now validates only the indices each state consumes. A pre-fix
sequence reproduced the rejected trial in checked, release, and ASan modes;
the corrected trial and counter tests pass (8 cases). The same archive's
counter halfword stores wrap at 16 bits; focused boundary checks pass without
a Nim change. These checks do not establish radio throughput behavior.

The retained `rc.o` MCS/NSS decoders, fixed-rate admission, EWMA update,
duration lookup, and throughput score agree with the Nim valid-input paths.
The pinned `me_task.o:me_rc_set_rate_req_handler` reads the six-byte request
without a length check. Nim now rejects a declared body shorter than six bytes
before reading its station index, fixed-rate word, or MCS word. The focused
fixed-rate test covers all shorter lengths in checked, release, and ASan modes;
this is a malformed-message guard, not a vendor behavior change on valid input.
The adjacent `me_traffic_ind_req_handler` updates station flag bit 2 when
`tx_avail` is nonzero and bit 0 otherwise. For PS state 15, the archive
allocates message ID 47 (`MM_TIM_UPDATE_REQ`), fills its four-byte AID,
set-flag, and VIF payload, sends it, then sends the basic ME confirmation to
the original requester. Nim now follows that routing and keeps the reply IDs
stable if the TIM send callback mutates the request. The focused test covers
flag combinations, sleeping/awake stations, allocation failure, and malformed
requests in checked, release, and ASan modes. No over-the-air TIM behavior is
established by this static check.
The pinned `me_task.o:me_config_req_handler` sends `ME_CONFIG_CFM` before
submitting the optional PS-mode command. Nim now publishes that confirmation
after reserving the MM reply but before forwarding the original request.
At confirmation time, Nim has copied HT support and capabilities but has not
yet updated NSS, HT-capability selection, default key, PS mode, or the
requester byte at environment offset 126. These writes now follow the
archive's ordering. The original request header is still intact through the
confirmation callback; it is forwarded to MM only afterward. A nested config
request is saved while the first transaction is reserved or a no-PS config is
in progress, even though the task state remains idle at that point. A failed
control reservation can be retried without a partial config commit or a
duplicate confirmation. The focused control test checks field timing,
ordering, reentrancy, and retry in checked, release, and ASan modes.
The adjacent `me_chan_config_req_handler` copies 86 request bytes into the ME
environment and replies to the original source. Nim now requires an 86-byte
declared body before copying; the archive does not check its length. A focused
test covers shorter declarations, nil input, the full copy, and reply routing.
The pinned `me_task.o:me_sta_add_req_handler` reads the ME station request
again after calling `mm_sta_add`; the Nim port can run allocation and queue
callbacks before and during that call. Nim now snapshots the 86 meaningful
bytes and message routing before confirmation allocation, then uses the copy
for supported rates, capabilities, AID, and power-save fields afterward.
For AP-owned requests it rechecks the pending generation after allocation;
a canceled request cannot overwrite a replacement association's pending slot
or register a station. Failure cleanup only removes an association that still
owns the request. These are Nim ownership guards, not behavior present in the
archive. Focused tests mutate the original request at both callback boundaries
and cancel or replace the AP association during allocation in checked,
release, and ASan modes. The adjacent
STBC/TX-policy test now supplies a valid one-rate RC fixture; its previous
zero-rate fixture returned before the IRQ-protected policy update it asserted.
Nim intentionally rejects malformed rate state where the archive would read
unchecked entries, alias an out-of-range shift, or divide by zero. The
finite duration table and probability arithmetic have focused host coverage;
this review does not close the larger scheduler behavior. The retained
`rc_update_retry_chain` searches from the sorted tail using a `stats+0x1b`
allowed-byte base, so its apparent `(count-rank-1)` slot addresses entry
`count-rank`; Nim's candidate index matches. The best/second/probability/lowest
slot order and probability tie branches match the object. Focused retry and
sort-plus-retry vectors pass in checked and release modes. The inlined sample
replacement in `rc_update_stats` was also compared with
`rc.o:rc_update_stats+0x110..+0x30e`:
the six candidates are random, alternate GI, and next/previous neighbors of
the best and second-best rates. The loop preserves retry-chain entries and
recently successful rates, consumes rejected candidates without advancing the
entry, and clears attempt/success counters on both paths. Nim follows those
branches. The focused update vectors pass in checked, release, and ASan modes;
they remain host-side evidence, not an on-device rate-control validation.

The rate-control LCG starts at one (`rc.o:.data.next`). The random picker
restricts preamble bit 10 to CCK for pure legacy stations, but retains that
bit for all nonzero rates in the HT-to-legacy fallback
(`rc_new_random_rate+0x8A..0xA4` versus `+0xDC..0xF0`). The Nim-only bounded
picker enumerates the same encodings when random draws collide. Tests check
the cold seed, both random paths, and exhaustion of the OFDM fallback.
The cold table reserves slot 0 and the last slot for the lowest and initial
rates even when equal (`rc_init+0x448..0x470`). Only the interior consumes
random draws. The Nim fill remains bounded; compaction preserves both endpoints.

### Pure Nim TX Policy

The default firmware copies the station's complete rate, retry, and RF power
policy into each host TX buffer, matching the vendor allocator. EAPOL has one
local exception: when the first two slots select the same HT modulation,
bandwidth and MCS, and the existing final slot is 1 Mbps CCK, the copy uses
that legacy rate and power pair for the first retry slot too. The primary
rate, retry budget, station policy, and non-EAPOL frames are unchanged.
EAPOL completions do not update the station's adaptive rate statistics,
which would otherwise attribute the per-frame fallback to the old slot.

For automatic rate control in the native BL808 STA configuration, the
initial and refreshed station policy also bring negotiated 1 Mbps into the
second tracked slot when both leading rates are unusable HT samples, or
when the measured 1 Mbps success probability is at least 50% and both
leading rates are below 50%. The primary rate, retry budget, and calibrated
per-rate power remain unchanged. This is a local policy change, not a
per-packet IPv4/ARP override. It does not change fixed rates, AP policy,
legacy-only stations, rotated chains, or active rate trials.

The periodic RC check also compares the resolved rate configuration in
each slot across its sample sort. The vendor `rc_update_stats` return
keeps its index-only behavior; the caller requests a DMA policy refresh
even when sorting changes the selected rate at an unchanged index.

`-d:bl808WifiBootstrapRetryWorkaround` opts into the earlier bench workaround:
fixed retry rates and power for EAPOL and all IPv4/ARP traffic. It is not limited
to DHCP or the period immediately after association. This is a diagnostic
override, not the vendor-parity configuration. The existing
`bl808WifiKeepEapolRcPrimary` and `bl808WifiForceEapolPrimaryLegacy` options only
modify this explicitly enabled workaround; the latter takes precedence.

`bl808WifiDiagEapolCck` is a bench-only control that uses the existing
negotiated 1 Mbps retry pair in all four EAPOL slots. It cannot be combined
with the bootstrap or long-GI diagnostic.

`bl808WifiDiagEapolLongGi` clears only the HT short-GI bit in copied EAPOL rate
words. It cannot be combined with the bootstrap retry workaround. The first
Ox64 flash and two reboot-only trials did not reach EAPOL; the last trial ACKed
auth and then exhausted association retries. The flag was never exercised in
those runs, so they provide no guard-interval comparison. Logs are under
`build/hw-validation-wifi-native-eapol-long-gi/`.

Authentication and association requests keep the internal-frame allocator's
rate policy and TPC-selected power by default. Their earlier fixed rate/power
and PHY-control workaround is available with
`-d:bl808WifiMgmtRetryWorkaround`. The `bl808WifiMgmtOfdmFirst`,
`bl808WifiMgmtLegacyFirst`, and `bl808WifiKeepMgmtRcPrimary` options only adjust
that explicit workaround, in that precedence order. The separate
`bl808WifiForceTxPwr20`, `bl808WifiForceTxPwr30`, and `bl808WifiForceTxPwr70`
diagnostic options still override management TX power independently.

The pinned `me_mgmtframe.o:me_build_associate_req` stores the IE start pointer
through its fifth argument before writing the first SSID IE (`+0x8e`), then
sets the sixth argument to the final IE span length (`+0x1a2`). Nim previously
returned the end pointer. The encoder now returns the IE start; the station
sender derives any append position from the validated total length. Focused
encoder and sender tests cover both association and reassociation bodies,
security-IE fallback, and invalid output metadata. This is static ABI parity,
not an on-device association result.

The same object copies a zero-QoS WMM Info IE template (`.rodata` at
`0x080013bc`). At `+0x106..+0x124`, it replaces the QoS byte with connection
offset 58 only when `ps_env`'s first word is nonzero and the signed VIF byte at
offset 452 is negative. Nim now applies both gates instead of always copying
the connection QoS byte. The focused encoder test covers all gate combinations.

### TX/RX Completion Differential Probe

`tools/check_wifi_tx_confirmation_oracle.py` compares the compiled Nim
`txl_cfm_push`, `txl_cfm_evt`, `txl_cfm_flush`, `txl_cfm_flush_desc`,
`txl_current_desc_get`, `txl_cntrl_inc_pck_cnt` and `rxl_current_desc_get` with
the pinned vendor instructions in QEMU. The relevant T-Head extensions are
enabled explicitly; vendor list primitives also execute from the archive.
Radare2 captures the symbol ranges, LLVM supplies complete T-Head decoding,
and hashes verify that symbol renaming/fixture bindings do not alter input
instruction sections.

Run against an existing traced M0 WiFi object:

```sh
python3 tools/check_wifi_tx_confirmation_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --work build/wifi-tx-confirmation-oracle
```

The matrix compares 17,280 paired cases over all ACs, incoming IRQ states,
zero-to-ten-node chains, host/internal and DMA ownership patterns, mixed
signed-status gates, forced completion statuses and accounting rollover. It
checks the head-THD status word independently of the hardware confirmation
word, queue contents, buffer clearing, event bits, packet counts, completion
call order and final IRQ state. TX/RX getter cases are included separately.
The current compiled routines agree on these observations; no additional
firmware change was justified by this comparison.

Cross-layer confirmation callbacks, event publication and diagnostics are
explicit models. No callback reentry, packet parsing, radio, MAC/DMA register
access, hardware timing or stack-closure claim follows from this probe. Local
critical-section placement may differ from the vendor; callback-time IRQ state
is intentionally not compared. The `--fixture-fault` modes are negative
controls that corrupt fixture observations, not firmware instructions. They
must report failure; `none` is the normal mode.

In `txl_cfm.o:txl_cfm_evt`, the vendor restores the incoming MIE state
immediately after `co_list_pop_front` (`+0x72..+0x88`), before
`me_tx_cfm_singleton`, `txu_cntrl_cfm`, and host publication. Nim keeps the
dequeued descriptor in a reentrant flush owner and holds IRQs disabled through
publication. This is a deliberate lifetime difference, not confirmation of
vendor-equivalent callback IRQ behavior; reducing that critical section needs
a separate ownership and interrupt-latency review.

The pinned `txl_cfm_evt` returns when its queue is empty and has no event
re-arm on that normal exit. Nim also leaves the event clear after a complete
drain, but re-arms it if processing exits with another confirmation queued.
The compiled RV32 oracle passes on the current scan-only object. A focused
native test interrupts a two-descriptor drain, observes the pending event and
remaining descriptor, then retries to completion. The source-policy check now
requires this conditional recovery path instead of rejecting all re-arms.

### RX Descriptor Recycling Probe

`tools/check_wifi_rx_descriptor_oracle.py` compares the normal compiled Nim
`rxl_hd_append`, `rxl_pd_append` and `rxl_frame_release` with the pinned vendor
instructions. It checks all bytes of the canonical header, payload and software
descriptor pools, both queue environments, the modeled register page and the
ordered DMA trigger writes. Each trigger also captures the descriptor bytes
at publication, so matching final memory cannot conceal late initialization.

```sh
python3 tools/check_wifi_rx_descriptor_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --work build/wifi-rx-descriptor-oracle
```

The 3,660 paired cases cover current/hardware-head matches, empty/nonempty
header queues, predecessor/no-predecessor payload chains, an unused nil chain
argument, selected boundary slots and combined frame release. The current code
matches the vendor, including 16-bit status/length clears and preserved upper
halfwords. This comparison did not justify another firmware edit.

The fixture uses QEMU-only Sv32 mapping and supervisor execution for these
unprivileged routines. Register reads use RAM; a read-only register page routes
SW/C.SW writes through an observer that preserves all integer registers. Separate
full/compressed-store checks use distinct values, verify readback and test both
supervisor interrupt-enable states. These are test mechanisms, not BL808
requirements or firmware changes. No M-mode interrupt behavior is established.

Seven `--fixture-fault` controls must fail: header/payload halfword corruption,
header-current/payload-tail changes, trigger reordering, publication-snapshot
corruption and observer register corruption. They alter fixture observations or
context, not the selected firmware instruction bytes. Parser tests also reject
partial, duplicate, inconsistent and nonzero-exit success reports.

The comparison does not cover Nim-private lifetime metadata, callback reentry,
packet admission, physical cache/bus ordering, DMA fences, radio behavior or
stack closure. Publication snapshots establish guest instruction ordering only;
they do not establish visibility to a real DMA engine or readiness to flash.

### RX Header Contract Probe

`tools/check_wifi_rx_header_oracle.py` executes the compiled Nim and original
vendor MAC-header helpers for all 65,536 frame-control bit patterns. This is a
contract comparison, not an assertion that every bit pattern is a valid frame.
The results agree for 17,408 inputs. The other inputs fall into five explicit
classes: management encodings with both DS bits, control frames, reserved frame
types, non-QoS data with Order set, and QoS subtypes other than `0x88`.
The vendor helper has a generic 24/30-byte base, adds QoS only for `0x88`, and
adds four bytes whenever Order is set. Nim retains its frame-type-specific
handling; these differences alone do not justify copying the vendor formula.

```sh
python3 tools/check_wifi_rx_header_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --work build/wifi-rx-header-oracle
```

The same probe compares 9,216 paired WEP/unrecognized-status cases, including
header offsets, alignment, flag noise, seeded context bytes and both incoming
M-mode interrupt-enable states. It checks return values, all 96 context bytes,
unchanged packet bytes and final interrupt state. WEP advances the offset by
four; unrecognized status leaves the context unchanged. All tested cases agree.
Four fixture-observation controls (`length`, `classification`, `context`,
`packet`) must fail without changing the selected firmware instructions.

Radare2 captures bounded symbol ranges, and LLVM supplies supplementary T-Head
decoding. The original vendor TKIP/CCMP paths still contain two undecoded packed
instructions at protected-handler offsets `0x6c` and `0xe2`; those paths are
not executed or emulated by this probe. Native tests separately exercise the
real Nim TKIP/CCMP decoder, dispatcher callers and QoS-field reader across
three/four-address and Order-bit layouts. Passing those tests does not establish
direct vendor execution parity, complete frame admission, radio behavior or
readiness to flash. This batch did not establish a new firmware defect.

### Protected RX Decoder Differential Probe

`tools/check_wifi_rx_protected_oracle.py` closes the restricted probe's TKIP/CCMP
execution gap. It runs the complete original protected-header routine alongside
the compiled Nim decoder using the official
[XuanTie QEMU fork](https://github.com/XUANTIE-RV/qemu/tree/0258f62b9436e72a8d6710f924ff09b6e54d4abf)
with CPU `e907fdp`. The installed mainline QEMU is not replaced. A local RV32-only
build is available under `build/wifi-xuantie-qemu-build/`; its source commit is
`0258f62b9436e72a8d6710f924ff09b6e54d4abf`. Unused FUSE/plugin features were
disabled for macOS host compatibility, without simulator source changes.

```sh
python3 tools/check_wifi_rx_protected_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --work build/wifi-rx-protected-oracle
```

The original `wexti` encodings at vendor offsets `0x6c` and `0xe2` execute in
the simulator, not through fixture emulation. Before decoder cases, 128 checks
exercise those exact encodings with both source-register pairs and varied
64-bit inputs. LLVM still leaves these two instructions undecoded; the pinned
XuanTie decoder/translator and helper implement their extraction semantics.

All 188,416 paired decoder cases and 2,072,705 total assertions pass. The matrix
covers both ciphers, all in-range STA/VIF/key selectors, group/unicast paths,
six header offsets, four alignments, seeded contexts, both incoming MIE states,
flag noise and all values of each security-header byte. Checks include PN
ordering, key pointer, all 96 context bytes, packet preservation and unchanged
key tables. No firmware routine is modeled or weakened for this comparison;
only diagnostic output, C memory helpers and the Nim error flag are fixtures.

Six observation controls (`instruction`, `pn`, `key`, `flags`, `context`,
`packet`) must fail. An additional mainline-QEMU control must stop at the exact
unsupported `wexti` opcode, and must not produce a passing decoder report.
This establishes scoped decoder parity, not key installation, replay decisions,
malformed frame admission, protocol compliance, hardware timing or readiness to
flash. No additional firmware change was justified by this comparison.

### Replay Bitmap Forward Jumps

The replay helper deliberately differs from the vendor when a valid 48-bit PN
advances by a large amount. The vendor extracts only 32 bits of `PN >> 5`, so
block indices alias after `2^37` packet numbers. A stale bit can then reject a
fresh forward PN, or an unseen packet exactly 32 behind a subsequent forward
PN. This is a bitmap-eviction issue, not a reason to weaken duplicate checks.

`replay_counter_validate` now keeps the full 64-bit block indices for eviction
comparisons, while still selecting a bitmap bank with the low bit. The window
width, duplicate rejection, strict-PN path and key/context layouts are unchanged.
The fix applies to data replay, its read-only preview and windowed management
counters. Management counters remain separate from data and TX counters.

```sh
python3 -m pytest tools/test_wifi_replay.py \
  tools/test_wifi_replay_forward_jumps.py tools/test_wifi_rx_mgt_counter.py
```

All 36 focused tests pass. The twelve new forward-jump/seen-set variants first
failed at runtime with the original helper. The corrected normal M0 object also
passes 22,848 ordinary vendor comparisons and 756 intentional wide-jump
differences in the pinned XuanTie runtime, including all eight data TIDs and
preview immutability. The unchanged old object passes the ordinary comparisons
but fails the first wide-jump assertion. No vendor instruction is patched.

Only `.text.replay_counter_validate` changed among the WiFi object's 1,602
instruction sections. It remains a zero-byte-stack leaf with no calls. The
normal M0 build and RF/PHY provenance check pass; this does not establish whole
stack closure, interrupt nesting, hardware behavior or readiness to flash.

The installed-key handoff is covered separately by
`tools/test_wifi_vif_keys.py::test_installed_key_forward_jumps`. Its four native
build modes exercise both VIFs, all four data-key slots, TKIP/CCMP, every data
TID, and seeded counters followed by large forward jumps and late arrivals.
Full VIF comparisons preserve unrelated replay, key and TX state; duplicates
and packets outside the window remain rejected. All four variants fail at
runtime when only the old replay helper is substituted.

A follow-up RV32 probe runs the actual station/VIF installation code and
original vendor instructions: 15,776 installation comparisons, 960 ordinary RX
sequences and 1,344 intentionally corrected wide-jump sequences pass 1,774,753
assertions. The old normal M0 object passes installation and ordinary RX, then
fails the first seeded wide jump. Station installation intentionally matches
the vendor's zeroed receive counters rather than consuming the request's PN;
VIF installation retains its direct/windowed seeding distinction. No further
key-installation source change was justified. This probe holds the submitted
RX queue empty; it does not establish key replacement with in-flight traffic,
DMA visibility, radio behavior or readiness to flash.

### TX SNAP Protocol Preservation

The vendor frame builder always emits the RFC1042 OUI for Ethernet-II data.
The Nim TX writer inherited this behavior, although its RX path preserves
RFC1042 AARP/IPX as native LLC instead of recovering their Ethernet types.
TX now selects bridge-tunnel OUI `00:00:F8` for AARP (`0x80F3`) and IPX
(`0x8137`) only. Other type/length values and all MAC/security/SNAP lengths
are unchanged. This matches the distinction in
[Linux TX](https://github.com/torvalds/linux/blob/v6.12/net/mac80211/tx.c#L2713)
and [RX conversion](https://github.com/torvalds/linux/blob/v6.12/net/wireless/util.c#L514).

```sh
python3 -m pytest tools/test_wifi_tx_snap_encapsulation.py \
  tools/test_wifi_tx_sequence.py tools/test_wifi_tx_snap_boundary.py
python3 -m pytest tools/test_wifi_rx_decapsulation.py \
  -k rx_dispatch_decapsulation_and_security
```

All 22 focused native tests pass. Twelve new variants first failed at runtime
with the old writer. They cover every 16-bit type/length value, byte order,
header guards, security-header reservations, QoS/no-QoS, VIF modes and actual
TX-writer-to-RX-dispatcher EtherType recovery.

The normal compiled M0 code also passes 115,712 paired RV32 cases and 1,995,781
assertions against original vendor instructions. The 14,338 AARP/IPX cases
require exactly the intended OUI-byte difference; the remaining 101,374 cases
agree. The unchanged previous image fails on the first AARP case. Only the
internal frame builder's instruction section changes among 1,602 WiFi sections;
its 144-byte compiler frame and the 16-byte exported wrapper frame are unchanged.
The M0 build and RF/PHY provenance check pass. This does not establish queued
TX ownership, DMA visibility, radio behavior or readiness to flash.

### TKIP MIC Streaming

`tools/test_wifi_tx_mic_stream.py` connects the actual TX tail routine to the
actual Michael implementation, rather than substituting fixed MIC bytes. Its
four native build modes cover every two-way split of selected payloads through
2,352 bytes, four alignments, repeated tail construction, RFC1042/bridge-tunnel
SNAP input and no-SNAP LLC input. Independent answers are anchored to the six
published vectors already recorded in `tools/test_wifi_michael.py`. Explicit
zero-length updates preserve every context byte, including with a null input.

The older RX MIC-indication fixture now includes the production metadata
snapshot and ownership guards. It checks allocator-driven frame/key changes,
allocation failure and metadata preservation instead of omitting those paths.
All 29 focused tests pass:

```sh
python3 -m pytest tools/test_wifi_tx_mic_stream.py \
  tools/test_wifi_tx_mic_tail.py tools/test_wifi_michael.py
```

A follow-up probe runs the compiled Nim routines and original vendor
instructions on RV32. All 450,413 assertions pass across 92 paired known-answer
streaming cases, four explicit zero-length cases and 11,904 TX-tail cases.
MIC, chain, payload-guard and descriptor observation controls are all rejected.
No firmware instruction is patched or emulated.

The vendor's `me_mic_calc` still loads a word when its length is zero; its
RV32 shift-by-32 mask retains that word in pending state. Nim already treats
this as a no-op. The probe explicitly requires this difference and the resulting
vendor MIC mismatch in 2,976 no-SNAP TX cases, rather than labeling them parity.
The other 8,928 TX cases agree on MIC bytes. Both appenders consume identical
Nim-built header inputs, so this is not a new vendor-header comparison.
No production change is justified by this batch. It does not establish radio
behavior, DMA/cache visibility, queued TX ownership or readiness to flash.

### RX MIC and Replay Integration

`tools/test_wifi_rx_mic_stream.py` connects the actual protected-header decoder,
Michael functions, noncommitting replay preview, replay update and RX dispatcher.
It tests strict/windowed counters, invalid then valid frames with the same PN,
duplicate PNs, late arrivals, sequence-cache isolation and unchanged TX/key state.
The 280 history profiles cover RFC1042, bridge-tunnel and native LLC payloads,
EAPOL, QoS/non-QoS/WDS/HT headers, rollover values and every MIC split across
the 1,736-byte DMA-buffer boundary. Foreign control-port destinations and short
MIC spans are rejected without consuming counters or sequence state.

```sh
python3 -m pytest tools/test_wifi_rx_mic_stream.py
python3 -m pytest tools/test_wifi_rx_decapsulation.py \
  -k 'eapol_integrity_and_scatter_delivery or rx_control_port'
```

All 16 focused tests pass. Four test-only changes to key direction, replay-preview
side effects, MIC gating or the buffer walk fail at runtime. These are native
integration checks: key-table routing, current-session checks and DMA/upper-layer
callbacks remain fixtures. They are not a full RV32 RX-dispatcher comparison.

Fresh numeric-range radare2 and full-section LLVM captures retain the inspected
vendor ordering: sequence write at `+0x47c`, replay-helper call at `+0x502`, and
the later MIC path at `+0x5b4..+0x6aa`. Nim keeps its intentional deferred commit
and verifies protected EAPOL before delivery. The initial TKIP TSC-zero cases
retain the documented compatibility exception in
[Linux TKIP receive logic](https://github.com/torvalds/linux/blob/v6.12/net/mac80211/tkip.c#L244);
this does not establish a CCMP PN policy. No production change was justified by
this batch, and no hardware-readiness claim follows from these checks.

### CCMP Initial Receive PN

The RX replay check and its read-only preview now reject PN zero for CCMP
(`cipherType == 2`) before changing counters. The vendor's generic replay helper
accepts zero against an empty counter; copying that behavior into CCMP admitted
a frame that should be discarded. This is an intentional vendor difference.
The receive-counter initialization and comparison rule is described in
[UNH-IOL's CCMP conformance test 1.2.4](https://www.iol.unh.edu/sites/default/files/testsuites/wireless/mac/802.11_STA_WPA2_MAC_Conformance_Test_Suite_v2.4.pdf#page=18),
and the corresponding comparison is present in
[Linux CCMP receive logic](https://github.com/torvalds/linux/blob/v6.12/net/mac80211/wpa.c#L557).
TKIP's initial-zero compatibility behavior and the generic replay helper remain
unchanged. Key installation, receive-PN seeding and the separate management
counter keep their existing layouts and lifecycle.

```sh
python3 -m pytest tools/test_wifi_rx_ccmp_pn.py \
  tools/test_wifi_rx_mgt_counter.py tools/test_wifi_replay.py \
  tools/test_wifi_replay_forward_jumps.py tools/test_wifi_rx_mic_stream.py
```

All 56 focused tests pass in the selected build modes. The new checks cover
installed-key admission, data/management counter isolation, preview side effects,
nonzero PNs with a zero low word, TKIP compatibility, and protected data/EAPOL
delivery. Eight CCMP test cases fail at runtime before the fix; four TKIP and
generic-counter checks pass both before and after it.

The separate RV32 probe executes the compiled Nim admission/preview routines
and unchanged vendor routines for 4,096 paired cases, with 36,871 assertions.
It records 112 intentional PN-zero differences and agreement elsewhere in this
matrix. The pre-fix object fails the first CCMP case after 2,048 TKIP cases.
Only the two intended function instruction sections changed among 1,602, with
their stack frames unchanged. This checks counter admission, not the complete
RX dispatcher, hardware decryption, DMA visibility or readiness to flash.

### Protected Header Admission

The associated RX dispatcher now requires ExtIV for TKIP and CCMP before key
selection, MIC/replay processing or delivery. The check follows the existing
length guard, so a truncated security header is never read. WEP is unchanged;
reserved CCMP header bits remain ignored. This corrects the inherited admission
behavior without changing the raw protected-header decoder's vendor contract.
[UNH-IOL test 1.2.2](https://www.iol.unh.edu/sites/default/files/testsuites/wireless/mac/802.11_STA_WPA2_MAC_Conformance_Test_Suite_v2.4.pdf#page=15)
specifies the CCMP ExtIV and reserved-bit behavior.
[Linux TKIP receive logic](https://github.com/torvalds/linux/blob/v6.12/net/mac80211/tkip.c#L237)
also rejects a missing ExtIV.

```sh
python3 -m pytest tools/test_wifi_rx_extiv.py \
  tools/test_wifi_rx_protected_header.py tools/test_wifi_rx_decapsulation.py \
  tools/test_wifi_rx_mic_stream.py tools/test_wifi_rx_ccmp_pn.py
```

All 88 focused RX tests pass. The 28 new cases cover key-ID octets, reserved
bits, WDS/QoS/HT offsets, protected management frames, data/EAPOL paths, WEP and
truncated headers with exact-sized allocations under ASan. Twenty ExtIV cases
fail at runtime before the fix; the eight truncation/WEP cases already pass.
Current-session predicates, hardware decryption results and upper callbacks
remain fixtures in these native integration tests.

A separate RV32 probe executes the normal compiled dispatcher and its MAC-header
helpers up to a modeled decoder call: 198,656 cases and 2,185,216 assertions.
The extracted instruction sections and their relocation targets are checked
against the normal object. Ownership/logging are modeled, the decoder records
entry and returns zero, and any unexpected callee fails the probe. This is not
a whole-RX differential comparison. The pre-fix object fails the first missing-
ExtIV TKIP case after 65,536 WEP cases. The unchanged raw decoder separately
passes all 188,416 original-vendor comparison cases.

Only the dispatcher's instruction section changes among 1,602 exact-named WiFi
sections, with its 144-byte stack frame unchanged. No hardware run establishes
how the MAC reports malformed headers, and these checks do not establish radio
conformance, DMA visibility or readiness to flash.

### Compiled RX Pipeline

`tools/check_wifi_rx_pipeline_oracle.py` executes the normal RV32 dispatcher
through protected-header decoding, actual station/VIF key lookup, Michael MIC,
replay preview/commit, decapsulation, scatter copy and upload-list insertion.
It retains 25 original WiFi instruction sections for STA or 26 for AP, verifies
their bytes and relocation inventories, and links the original system
comparison helper. AP additionally executes the actual Nim EAPOL wrapper and
compares its supported inputs with the unchanged 52-byte vendor wrapper.
Retaining a function does not imply coverage of every branch within it.

```sh
python3 tools/check_wifi_rx_pipeline_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --system-object build/nimcache_m0/@psystem.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --work build/wifi-rx-pipeline
python3 tools/check_wifi_rx_pipeline_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --system-object build/nimcache_m0/@psystem.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --role ap --work build/wifi-rx-ap-pipeline
python3 -m pytest tools/test_wifi_rx_pipeline_oracle.py
```

The 490 profiles cover TKIP/CCMP, strict/windowed counters, data TIDs 0/3/7,
both VIFs and all station/key IDs, station/group key routing, QoS/non-QoS/WDS/HT,
RFC1042/bridge-tunnel/native LLC, data/EAPOL, every MIC split across the
1,736-byte buffer boundary, and MSDUs through 2,304 bytes. Each history checks
invalid-then-valid frames, duplicate PNs with new MAC sequence numbers, forward
and late arrivals; EAPOL profiles also reject foreign destinations, including
TKIP frames carrying valid Michael MIC test vectors. Expected MICs use the
independent reference checked against the
six published known-answer vectors, not either implementation under comparison.

All 388,864 cases and 5,174,400 assertions pass. Observations include the entire
RX environment, key/sequence tables, packet storage/guards, chain nodes, software
and MPDU descriptors, MIC-failure messages, temporary allocation guards, queue
publication, EAPOL bytes and MIE preservation. Four test-only controls for key
direction, chain repetition, counter state and packet guards fail their
designated checks.

The AP corpus has 560 profiles and passes 449,792 RX cases with 6,890,688
assertions. Uplink frames use the source station's pairwise key even when the
MSDU destination is multicast. Address extraction and uploaded destination
metadata cover unicast hits/misses and multicast, retaining the RX environment
between frames to check stale state. The hardware search result is modeled;
the caller correctly consumes a software station index, without subtracting
the hardware-table bias a second time.

Included in the AP RX count are 5,376 plaintext EAPOL cases on a secured BSS
without an installed key. Control-port states and local/foreign destinations
are checked without consuming key counters. Another 2,240 direct Nim wrapper
guard cases and 448 vendor wrapper comparisons verify callback arguments,
payload, ignored callback return values and MIE preservation. Only ready and
nil-host-context inputs are sent to the vendor wrapper; Nim's additional
station, buffer and callback guards are checked independently. Six AP controls
include the four STA controls plus destination metadata and callback context
errors. All 60 result-parser tests and nine native destination regressions
(checked, release and AddressSanitizer modes) pass.

The default MSDU corpus checks current-session, non-reentrant STA/AP ingress with a
single-entry upload queue drained by the fixture between frames.
Session/key-current predicates, DMA completion, logging, allocation/message
transport, scheduler notification and host callbacks are modeled. Hardware
decryption/ICV success is supplied as input; CCMP cryptography is not executed.
AP over-air forwarding, hardware address-table search and cross-VIF isolation,
management ingress, actual key installation, callback-time session
changes, DMA/cache visibility and radio behavior are not established by this
corpus. A-MSDU checks are separate below.

Fresh radare2/LLVM vendor captures retain the previously identified early
sequence/PN commit and EAPOL-before-Michael ordering; Nim deliberately retains
its deferred commit and integrity checks. This is an independent compiled-Nim
pipeline check, not full-vendor RX execution or equivalence. No further firmware
change was justified, and no hardware-readiness claim follows from this batch.

### Compiled A-MSDU Admission

The pipeline probe's `--corpus amsdu` option executes the normal compiled
aggregate validator and dispatcher, including protected-header parsing, actual
pairwise key lookup, replay/sequence commit, header stripping and queue
publication. Original object sections/relocations are checked before normal
linker relaxation; linked function sizes may differ. Each role has 336 profiles
and 172,032 RX cases. STA passes
2,294,208 assertions; AP passes 2,638,272 assertions. The ordinary-MSDU STA/AP
baselines and their ten controls also pass after the fixture extension.

```sh
python3 tools/check_wifi_rx_pipeline_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --system-object build/nimcache_m0/@psystem.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --corpus amsdu --role ap --work build/wifi-rx-ap-amsdu
```

Use `--role sta` with a separate work directory for the station corpus.
Profiles cover QoS/HT/4-address headers, both VIFs, all station/key IDs,
unicast/multicast inner destinations, one to three subframes, and frame lengths
through 7,002 bytes across five 1,736-byte buffers. Each history checks CCMP
PN zero, missing ExtIV, duplicates, forward and late arrivals under strict and
windowed replay modes. Of these, 43,008 admission cases per role check
closed/control-only/open ports, truncated or invalid later subframes, address
policy, final padding, WEP/TKIP rejection and secured/open plaintext behavior.
Rejected aggregates leave replay and sequence state unchanged; accepted
aggregates preserve their subframe bytes and upload the aggregate status bit.

Seven test-only controls for replay state, packet guards, aggregate status and
AP destination metadata fail their designated checks. All 88 parser tests
pass. Sixteen focused native tests cover aggregate admission, control-port
policy, scatter copying and host deaggregation. Host tests now include three
subframes through 6,958 aggregate bytes on multi-node pbuf chains, in checked,
release and AddressSanitizer modes, with exact output bytes and no outstanding
fixture allocations.

The vendor's QoS aggregate branch at `rxu_cntrl_frame_handle+0x77a` jumps to
`+0x7fa`, sets status bit 0, and proceeds to upload without rewriting the
aggregate as a single Ethernet frame. Nim agrees with this strip/status
contract. Fresh radare2/LLVM captures are static evidence, not execution of
the full vendor dispatcher. Nim's per-subframe checks are reviewed against
[IEEE 802.11-2012's aggregate addressing rules](https://www.ieee802.org/11/email/stds-802-11-editors/pdfPRTmOzMSD_.pdf)
and the [Linux aggregate RX path](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/b2d03cabe2b2e150ff5a381731ea0355459be09f/net/mac80211/rx.c).

The same session, DMA-completion, address-search, host-callback and scheduling
models apply. Host deaggregation is checked separately in native fixtures,
not as a joined target-to-lwIP execution. No negotiated aggregate-size limit,
block-ack/reorder behavior, callback-time session changes, AP forwarding,
DMA/cache visibility, CCMP cryptography or physical radio behavior is proved.
No further production change was justified by this batch.

### ADDBA Receive Window

The BAM receive handler now treats a zero Buffer Size request as unspecified
and selects the existing 12-buffer receiver limit. It no longer sends a
successful ADDBA response with a zero receive window. This intentionally differs
from the pinned vendor's `min(requested, 12)` behavior for zero requests only;
supported EDCA TIDs retain the same nonzero clamp, TID/policy bits, A-MSDU exclusion,
dialog token and timeout behavior.

IEEE 802.11-2012 section 8.4.1.14, printed page 452, distinguishes an
unspecified request from a successful response, whose buffer count must be
positive. The [Linux ADDBA receive implementation](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/7846b12fe0b5feab5446d892f41b5140c1419109/net/mac80211/agg-rx.c)
likewise resolves an unspecified count before limiting it to hardware capacity.
Fresh radare2/LLVM captures confirm that the original vendor does not perform
that normalization. This is a protocol correction, not a vendor-parity claim.

The same vendor BAM handler accepts a zero ADDBA dialog token and always
negotiates immediate BA, even when the request advertises delayed BA. The Nim
handler now drops a zero-token request before enabling BAM or sending a
response: [IEEE 802.11-2012 section 8.5.5.2](https://mrncciew.com/wp-content/uploads/2014/10/ieee-802-11-2012.pdf)
requires a nonzero request token. It declines delayed-policy requests because
this receiver has no delayed-BA responder. Section 9.21.2 allows recipients to
change policy for non-HT agreements but does not make the policy generally
advisory for HT agreements. The request-parameter matrix covers both policy
bits and the zero-token rejection.

```sh
python3 -m pytest tools/test_wifi_ba_window.py \
  tools/test_wifi_block_ack.py tools/test_wifi_ba_response_owner.py
```

The new regressions failed at runtime on the prior implementation in checked,
release and AddressSanitizer modes. All 27 focused tests now pass, including
exhaustive 16-bit request parameter coverage and response ownership across
diagnostic callbacks. The normal M0 compile passes. Only
`rxu_mgt_ind_handler_bam` changes among 1,602 WiFi instruction sections
(806 to 824 object bytes); its static stack frame changes from 96 to 112 bytes.
The normal image remains 510,722 text, 2,372 data and 177,640 BSS bytes.

This does not establish hardware reordering, Block Ack timing, originator
agreements, DELBA handling or on-air interoperability. No full suite or
hardware run was used for this change.

### EDCA Traffic Identifiers

The data path now consistently distinguishes wire TIDs 0..7, supported by
EDCA, from TIDs 8..15, which require HCCA/HEMM traffic-stream handling that
this implementation does not provide. They are not universally invalid
802.11 identifiers. IEEE 802.11-2012 section 8.2.4.5.2, Table 8-5 on printed
page 390, defines that distinction. The pinned
[Linux ADDBA receiver](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/7846b12fe0b5feab5446d892f41b5140c1419109/net/mac80211/agg-rx.c)
also declines unsupported traffic-stream identifiers.

Fresh radare2 and LLVM captures from the same SDK archive show three-bit
masking in vendor RX and power-save processing, unchecked TX QoS identifiers,
and unconditional success for these ADDBA identifiers. The Nim changes are
intentional capability checks, not claims of identical vendor behavior:

- Associated RX reads all four TID bits and stops unsupported EDCA input
  before replay, sequence, key or upload processing. Nonassociated raw capture
  preserves the full four-bit identifier instead of aliasing it.
- Host TX and direct frame building reject unsupported identifiers. The
  builder also stops if a diagnostic callback changes its captured TID.
- STA/AP receive power-save processing rejects those identifiers before
  changing power-save state, and QoS-null construction rejects them before
  allocating a frame.
- ADDBA replies use Request Declined (37) for unsupported identifiers and do
  not enable the hardware ACK bit. Supported identifiers retain the existing
  window normalization and owner checks.

The ninth ABI sequence slot and internal power-save selector 8 remain
unchanged; they are not authorization to emit wire TID 8.

```sh
python3 -m pytest tools/test_wifi_edca_tid.py tools/test_wifi_tx_tid.py \
  tools/test_wifi_tx_sequence.py tools/test_wifi_block_ack.py \
  tools/test_wifi_ba_response_owner.py tools/test_wifi_ba_window.py
```

That focused selection passes 71 tests. Adjacent RX, power-save, frame-build
and callback checks pass 80 tests; the three positive lower-preparation tests
also pass. The new negative checks produced 27 runtime assertion failures
before the correction, across checked, release and AddressSanitizer modes.
An older power-save fixture was repaired separately: missing generation
models and an incorrect expected VIF index reproduced on the prior source;
the fixture now also provides complete QoS header storage. Its descriptor
generation model is fixed, not a recycling test.

The normal M0 build passes, with text/data/BSS of 510,914/2,372/177,640 bytes.
Seven of 1,602 normalized WiFi instruction sections change. Generated numeric
Nim suffixes are normalized and overloaded names are paired by section order;
this compares object instruction bytes, not all relocations or linked behavior.
The AP power-save static stack frame grows from 80 to 112 bytes; the other
six changed routines retain their prior stack sizes.

Current compiled RV32 STA/AP ordinary and aggregate RX corpora also pass:
1,182,720 cases and 16,997,568 assertions. These are positive regression
inputs, not a compiled negative-TID corpus or full vendor equivalence.
Session/key-current, DMA completion, allocation, host callbacks and scheduler
boundaries remain modeled. No full suite, hardware run, radio timing or
on-air interoperability validation was performed. Evidence is recorded under
`build/wifi-tid-contract*`; the broader firmware review remains active.

### RX Captured-Frame Continuation

Upper RX now checks the captured descriptor generation and header binding,
not only whether the slot's current station is valid, before committing data
or management replay/sequence state. A slot recaptured for a new frame can
have a valid station while no longer belonging to the interrupted call.
The same captured-frame check follows protected-header key validation, the
late data diagnostic, and both TKIP key checks, before MIC-length changes
or further processing can affect a replacement frame.

`tools/test_wifi_rx_continuation.py` executes the production upper dispatcher
and station/key/generation helpers with modeled descriptor storage, crypto,
transport and diagnostic boundaries. It replaces a slot with another valid
capture, removes its header binding, or changes its station/VIF epoch.
Interruption is modeled immediately before MIE is cleared; diagnostics are
hooked for equivalent suspension tests, not claimed to recycle slots normally.
Checks cover STA/AP data, management, plaintext/CCMP/TKIP metadata, EAPOL,
three/four-address QoS and HT-control forms, incoming IRQ state, and builds
with and without connection tracing.

```sh
python3 -m pytest tools/test_wifi_rx_continuation.py
```

All 32 new tests pass in checked, release, AddressSanitizer and firmware-like
native modes. The same current tests produce 20 runtime assertion failures
and 12 passing controls against the frozen prior source. An initial fixture
extraction compile failure is retained separately and is not counted as a
firmware reproduction. Adjacent RX tests pass 123 cases and the six selected
RX TID/raw-capture tests also pass: 161 selected tests, without a full suite.

Fresh radare2/LLVM captures retain the pinned vendor RX and BAM ranges plus
both normal Nim RX dispatcher versions. The vendor has no equivalent Nim
generation bookkeeping; the checks are intentional ownership corrections,
not vendor behavior. Block Ack policy/teardown review remains incomplete;
this batch does not add an originator, delayed-BA or reorder implementation.

At this checkpoint the normal M0 build passes with text/data/BSS of
511,042/2,372/177,640 bytes, a 128-byte linked text increase. Only the RX
dispatcher changes among 1,602 normalized WiFi instruction sections, from
6,474 to 6,676 object bytes. Generated numeric suffixes are normalized and
overloads paired by section order; this is not whole-object relocation/data
equivalence. The dispatcher's static stack frame grows from 144 to 160 bytes.

The four current compiled RX regression corpora pass 1,182,720 cases and
16,997,568 assertions across ordinary/aggregate STA/AP input. Their session,
key-current and DMA/host boundaries remain models; they are not target-executed
slot-replacement tests or a physical-interrupt/on-air validation. No hardware
run, commit or push was performed. Evidence is retained under
`build/wifi-rx-continuation-contract*`; the broader review remains active.

### RX Key-Check Handoff

Three remaining upper-RX handoffs now validate the key before rechecking the
captured frame: scatter EAPOL copying, final EAPOL delivery, and MIC-failure
notification publication. `rxKeyCurrent` enters its own IRQ-protected section
and validates the slot's current identity. A fresh valid capture can therefore
pass that key check without being the interrupted call's original frame.
Checking `frameCurrent()` last rejects that replacement before copying or
publication, while retaining cleanup of private buffers and notifications.

```sh
python3 -m pytest tools/test_wifi_rx_handoff_generation.py
```

All 32 new tests pass, including contiguous/scattered payload boundaries,
STA/AP routes, tracing enabled/disabled, IRQ-state preservation, allocation
failure and private-resource cleanup. The pre-change source produces 24
runtime failures and eight passing controls across checked, release,
AddressSanitizer and firmware-like native modes. The fixture executes the
production dispatcher, generation/key helpers and counted production copy
routine; crypto, callbacks, notification storage and interrupt arrival are
models. A fixture canary-literal compile error is retained separately and
is not counted as a firmware reproduction.

Another 98 selected continuation, key, MIC, EAPOL and decapsulation tests pass,
for 130 selected tests total. Fresh radare2/LLVM captures retain both Nim
dispatcher versions and the pinned 2,178-byte vendor root. The vendor EAPOL
calls at +0x55a/+0x574 and MIC notification at +0x6ba..+0x700 have no matching
Nim generation checks; this remains an intentional ownership correction,
not exact vendor equivalence.

The normal M0 build passes. Only the dispatcher changes among 1,602 WiFi
instruction sections, from 6,676 to 6,696 object bytes; no symbol normalization
is needed for this comparison. Text/data/BSS remain 511,042/2,372/177,640 bytes,
and the dispatcher's static stack frame decreases from 160 to 144 bytes.

The current compiled ordinary-data STA/AP corpora pass 838,656 cases and
12,065,088 assertions, covering EAPOL and TKIP MIC outcomes. Aggregate corpora
were not rerun because they do not enter these changed handoff branches.
Target probe session/key-current, DMA and host boundaries remain modeled;
this is not physical-interrupt or on-air validation. No full suite, hardware
run, commit or push was performed. Evidence is retained under
`build/wifi-rx-handoff-contract*`; the broader firmware review remains active.

### RX Management Indication Copy

The management producer now uses the existing bounded DMA-chain copy helper
instead of treating received payload buffers as contiguous memory. Whole-frame
indications retain their MAC header but omit the intervening security header;
body-only indications continue to omit both headers. This makes decrypted
deauthentication/disassociation reasons available at the fixed offsets used
by the STA/AP consumers. The original RX buffers remain unchanged. Failed
copies free the private indication without publishing it.

Unbound reassociation requests now select the matching AP VIF under the same
Addr1/Addr3 BSSID and VIF-type checks as association/authentication requests.
The AP consumer already handles reassociation. This is a capability correction,
not exact vendor parity: the pinned vendor's initial VIF-selection branch
also omits reassociation.

```sh
python3 -m pytest tools/test_wifi_mgt_indication_copy.py \
  tools/test_wifi_mgt_request_routing.py tools/test_wifi_mgt_indication_oracle.py
python3 tools/check_wifi_mgt_indication_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --system-object build/nimcache_m0/@psystem.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --work build/wifi-mgt-indication-oracle
```

The focused tests yield 18 runtime failures and 13 passing controls against
the pre-change implementation; all 31 now pass. Another 64 selected tests
cover management admission, frame ownership, message lifetime, RSSI, and AP
receive lengths/dispatch. All 27 observation-parser tests pass, for 122 selected
native tests total. Checked, release, AddressSanitizer and firmware-like modes
cover the new copying cases; the routing tests use their existing three modes.

The new probe executes the normal compiled RV32 producer, MAC-header helper
and segmented-copy helper with actual descriptor offsets. All 3,036 cases and
30,228 assertions pass. Cases cover two VIF slots, three station indices, both
incoming MIE states, STA/AP destinations, protected/body-only/whole-frame
copies, nonadjacent DMA buffers, buffer-boundary lengths and broken-chain
cleanup. Four deliberately incorrect observation controls are rejected. The
old object fails at case 145 when a 1,737-byte frame first crosses the DMA
boundary. Retained instruction bytes and relocations are verified unchanged
during probe binding. MFP acceptance, session predicates, channel/PHY results,
allocation, publication/free and raw upload are models. Broken-chain inputs
exercise copy failure directly; normal lower admission would reject them.
This does not execute cryptographic verification, real interrupts or radio I/O.

Fresh radare2 numeric-range captures and supplementary LLVM decoding retain
both Nim versions and the original 1,350-byte vendor producer. The vendor
header adjustment at +0x460..+0x48e and copy loop at +0x50e..+0x518 also
treat payload as contiguous and conditionally omit the entire header. The
segmented and protected whole-frame handling
are intentional corrections rather than complete vendor equivalence.

The normal M0 build passes at text/data/BSS = 511,238/2,372/177,640 bytes.
Only the management producer changes among 1,602 WiFi instruction sections,
from 3,736 to 3,932 object bytes. Nine generated numeric-suffix renames are
byte-identical; this is not whole-object data/relocation equivalence. The
producer's static stack frame grows from 112 to 128 bytes. Ordinary/aggregate
data-RX corpora are not rerun because their instruction sections are unchanged
and they do not enter this management-copy branch. Evidence is retained under
`build/wifi-mgt-indication-contract*`. No full suite, hardware run, commit or
push was performed; complete firmware readiness remains unproven.

### Station Deletion Timeout Recovery

The pinned MM/STA objects establish the normal order: retire the station,
remove its keys and MAC address, drain postponed TX, then acknowledge the MM
delete request. The Nim hardware waits can report failure after a command was
submitted. Previously, `mm_sta_del` left the slot retired on a key/address
timeout while `mm_sta_del_req_handler` still forwarded `MM_STA_DEL_CFM`.
Repeated calls could not reacquire that retired slot.

Nim now retains the retirement identity and key snapshot per slot, retries
failed hardware steps from an MM timer, and keeps the request in the saved
queue until hardware deletion and postponed-TX cleanup complete. AP sleeper
accounting and broadcast power-save release run once. A failed final drain
keeps the slot quarantined across the extra station-epoch increment; queued
delete requests are invalidated only when the slot enters the free pool.
These timeout/reentrancy guards intentionally extend the vendor happy path.
An `mm_sta_add` address-write failure, stale callback, or failed WEP key write
now attaches the unpublished station to the same retry owner before attempting
its hardware delete. It leaves the VIF's published station index, keys, and
AP sleeper accounting unchanged and cannot claim an SM delete request.
The native lifetime fixture covers a
failed delete followed by timer-driven completion for STA and AP VIFs.
The station-lifetime, TX-drain, dispatch, teardown, cleanup, and MM-timer
fixtures pass, and the M0 WiFi HAL image builds. No device run was performed.

### Station Management Peer Admission

Bounded radare2 captures of `sm.o` show that `sm_auth_handler` (580 bytes) and
`sm_assoc_rsp_handler` (432 bytes) act on the received status/body without
comparing the AP address to the pending join target. `sm_deauth_handler` checks
the BSSID and destination but not the transmitter; the SM task can restart
authentication on deauth/disassoc before reaching that handler. RX routing can
resolve a station VIF from the destination or a prebound station, but neither
route binds the frame to the selected AP. The Nim producer now requires station
auth, (re)association, deauth, and disassoc frames to carry the configured
unicast BSSID as transmitter and BSSID. Auth/(re)assoc must address the VIF;
deauth/disassoc may use a group destination. It falls back to `currentBssid`
only when the configured BSSID is unset. AP-mode traffic is unchanged.
The peer gate now precedes MFP processing, the station's `nonQosSeqCtrl`
commit, and message allocation. Before those ordering changes, a wrong-peer
auth, assoc, deauth, or disassoc frame was dropped but still advanced the
duplicate cache; an authenticated wrong-peer group deauth also consumed its
BIP replay counter. Focused pre-fix cases reproduced both defects. Rejected
station-peer frames are no longer raw-uploaded, even with promiscuous upload
enabled; accepted frames keep the existing MFP and upload paths. The sequence
write remains IRQ-protected. In the pinned `rxu_cntrl.o`, MFP is called at
`rxu_mgt_frame_check+0x88` before the VIF lookup at `+0xde`; this earlier peer
gate is an intentional safety difference, not vendor parity.

The same gate now covers station-mode Block Ack and SA Query Actions, requiring
the selected AP as transmitter/BSSID and the local unicast destination. A
focused pre-fix case showed wrong-peer Actions reaching dispatch and advancing
`nonQosSeqCtrl`; AP-mode Actions remain on their existing path. The producer
also resolves the existing station-to-VIF fallback before MFP. The normal
associated RX path already supplies the VIF, but an unset environment VIF
previously caused a valid protected group deauth to be rejected before its
IGTK could be selected. A BIP regression reproduced this pre-fix failure.
Both changes intentionally precede the vendor's late VIF lookup.

The station duplicate-sequence commit also moved from before subtype dispatch
to after a complete indication copy, immediately before `ke_msg_send`. An
unsupported Action or allocation failure previously advanced `nonQosSeqCtrl`
without delivering a message, suppressing a later retry of the same sequence.
The pre-fix regression reproduced both paths; the enqueue callback now checks
that an accepted frame is committed before it becomes visible to consumers.

Bound station-mode beacons now pass the same AP source/BSSID gate before
`me_beacon_check` can alter channel or power state. Unbound scan beacons are
not peer-gated. AP-mode RX beacons no longer invoke that maintenance helper;
the AP's own beacon-template update still calls it directly. A focused pre-fix
case showed a wrong-peer bound beacon reaching maintenance, and the new matrix
also checks broadcast beacons from the selected AP. These are safety
corrections beyond the vendor producer's station-index routing.

The focused `tools/test_wifi_mgt_receive.py` fixture passes 46 cases across
checked, release, and AddressSanitizer modes, including mismatched addresses,
unset/group targets, stale `currentBssid`, broadcast disconnects, Action peer
admission, BIP fallback, and AP paths.
The M0 `m0_wifi_nimfw_boot_test` image builds with `bl808kernel` and
`bl808WifiNimFw`. This is a deliberate admission correction, not vendor
parity or on-air validation.

AP-mode deauth, disassoc, and Action indications now require the captured
station to be valid and owned by the selected AP VIF, with Addr1 and BSSID
equal to the AP MAC and Addr2 equal to the station MAC. This check runs before
MFP, raw upload, and duplicate-sequence publication. The pinned vendor RXU
producer sends Actions to BAM by station index without this peer check; its
AP deauth handler passes the received station MAC to deletion without checking
Addr1 or BSSID. Nim's direct AP handler checks the source only after dispatch. Native
management-receive cases cover valid AP traffic and mismatched destination,
source, BSSID, ownership, and validity with promiscuous upload enabled. The
focused 46-case matrix and integrated M0 Nim-firmware build pass; neither
establishes on-air behavior.

### Individual BA Peer Addresses

Radare2 of the pinned `sta_mgmt.o:sta_mgmt_register` shows a six-byte copy
from the request into the station entry without an individual-address check.
The pinned `bam.o:bam_send_air_action_frame` only calls the pairwise security
header builder when `mfp_protect_mgmt_frame` returns 1. A group-addressed
station entry instead selects group protection, which that ADDBA sender does
not implement. Nim now rejects zero and group station MACs before reserving a
registration slot, and the ADDBA sender checks both station and VIF MACs
before allocating a frame. These are admission corrections beyond the vendor
archive; they do not add a group-addressed BA response. Focused native tests
cover rejected registration without free-list mutation and rejected sends
from invalid retained entries.

The compiled RV32 management-copy oracle's station-management fixture now
installs the selected AP in the VIF BSSID fields and in the frame source/BSSID.
The same setup is used for its station Block Ack Action and bound beacon
samples after the peer gate exposed their previously unset BSSIDs.
With the normal M0 object, its 3,036 cases and 30,228 checks pass; length,
body, cleanup, and routing mutation controls are all rejected. The oracle
still models MFP and session binding, so it verifies the emitted producer's
valid-response path and DMA copying, not physical receive behavior.

### Management Indication Length Guards

Radare2 shows `sm_task.o:rxu_mgt_ind_handler` reading frame control at payload
offset 2 and SA Query category at 32 without checking the indication length.
The adjacent `sm.o` deauth and SA Query handlers read fixed fields through
offsets 57 and 35. `apm_task.o:rxu_mgt_ind_handler` also starts by reading
frame control at offset 2. Normal RX production bounds these messages, but
kernel dispatch and direct handler calls cannot rely on that producer alone.

The Nim SM dispatcher now validates both `paramLen` and the copied `frameLen`
before dispatch: six body bytes for auth/(re)assoc, a 26-byte whole frame for
deauth/disassoc, and four body bytes for SA Query. Direct deauth and SA Query
entry points enforce the same bounds. The AP dispatcher requires its nine-byte
indication prefix before reading the VIF index; its downstream handlers retain
their existing per-frame checks. This is an intentional guard beyond the
vendor bodies. The focused SM, SA Query, SM printf, AP dispatch and AP probe
tests pass (21 cases total), and the M0 Nim-firmware boot image builds. No
hardware or adversarial kernel-message execution is established by these checks.

### RX BIP Tail And Chaining

BIP receive now reads the terminal 18-byte MMIE directly instead of searching
all preceding body fields as IEs. Robust Action bodies can include non-IE
fields after the category/action bytes; the MMIE's position does not depend
on parsing those fields. Chained RX reads use `rxuCopyFrameBytes`, and the new
digest helper streams bounded chunks through the existing AES-CMAC code.
The received MIC is masked in local CMAC state without modifying RX storage.
The exported flat-buffer digest and receive ABIs remain unchanged.

The internal policy receives the caller's original RX generation. It uses
the existing IRQ-protected frame capture/current helpers before key use and
after each key-current check, including the replay commit. An otherwise
valid replacement descriptor must not consume replay state for an older call.
No heap allocation or new cipher implementation is introduced.

```sh
python3 -m pytest tools/test_wifi_bip_rx_chain.py tools/test_wifi_mfp_control.py \
  tools/test_wifi_bip_key_epoch.py tools/test_wifi_aes_cmac.py
```

All 24 new tests pass across checked, release, AddressSanitizer and firmware-
like native modes. They execute production AES/CMAC, the segmented reader and
the frame capture/current helpers, with independently computed cryptography
CMAC tags. Cases include both VIF/IGTK slots, both incoming IRQ states,
MMIE/MIC splits around the DMA boundary, unchanged RX bytes during digest
work, descriptor replacement, duplicates, bad MICs/MMIE fields, changed length
and missing buffers. Descriptor storage, key-current predicates and interrupt
arrival remain models. A pre-change 20-test baseline has 16 runtime assertion
failures and four passing controls, covering the four original concerns.

Another 133 selected tests pass, for 157 total. They cover existing BIP key
epochs, AES/CMAC vectors, management admission/ownership/copy/routing and the
compiled-probe parser. Fresh radare2/LLVM captures retain the 534-byte vendor
policy, its digest, and both normal Nim versions. The vendor also searches
with `mac_ie_find` and clears RX MIC bytes; the changes are intentional
correctness/ownership corrections, not exact vendor parity.

The normal M0 build passes at text/data/BSS = 512,006/2,372/177,640 bytes.
Three of the prior 1,602 WiFi instruction bodies change, with one new 424-byte
streaming helper. The policy's static stack frame grows from 112 to 256 bytes;
the streaming helper uses 400 bytes. Whole-call-stack headroom is not proved
by these per-function records. Generated system/support instruction bodies
are unchanged after numeric-name normalization and overload pairing.

The current compiled management producer passes its 3,036-case RV32 corpus,
including the new generation argument, but that probe models MFP acceptance.
It does not execute the new BIP calculation. At that checkpoint, normal-object
RV32 BIP execution remained pending; the following probe now covers it. Evidence is retained under
`build/wifi-mfp-chain-contract*`. No full suite, hardware run, commit or push
was performed; the broader firmware review remains active.

### RV32 BIP Receive Probe

`tools/check_wifi_bip_rx_oracle.py` executes the normal compiled BIP policy,
AES/CMAC, RX admission, descriptor binding, station capture, session/key
predicates, segmented reader and replay update under the pinned E907 emulator.
It uses the production descriptor/payload pools rather than replacement
pointer-lookup stubs. Thirty-one WiFi function sections and five normal libc
sections retain their original bytes/relocations during binding. The five
memory/64-bit-shift routines are also checked byte-for-byte in the linked
probe, so libgcc cannot silently replace the firmware's weak shift helpers.

```sh
python3 tools/check_wifi_bip_rx_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --system-object build/nimcache_m0/@psystem.nim.c.o \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --work build/wifi-bip-rx-oracle
python3 -m pytest tools/test_wifi_bip_rx_oracle.py
```

All 11,856 cases and 142,272 assertions pass. The 39 profiles combine
deauthentication and Radio Measurement Action bodies, 24/28-byte MAC headers,
and DMA/MMIE/MIC boundaries through 2,328 bytes. IPNs span several byte widths
through the 48-bit maximum. Each profile covers both IGTK/VIF slots, managed
station indices 0/4, both incoming MIE states, and nineteen acceptance/rejection
states. Descriptor indices 0/40, nonadjacent payload buffers and generation
wrap to zero vary by profile. Independent cryptography CMAC tags are calibrated
against a NIST known answer.

Controlled state changes during hash-work copies exercise descriptor recapture,
key replacement, selected/unrelated VIF epochs and replay advancement. The old
object trips the input-write observer at its first case; four deliberately
wrong observation controls are rejected at their designated checks. All 40
new parser tests and 27 adjacent parser tests pass. The shared extraction
refactor also retains the passing 3,036-case management-producer regression.

Memory observers wrap unchanged normal memcpy/memset implementations. Pool
contents and state changes are fixtures, not real DMA or interrupt arrival;
this is not full vendor execution or on-air validation. Fresh radare2 and LLVM
captures retain the normal functions and original vendor policy/digest.

Direct-call stack accounting gives 784 bytes from the BIP policy entry and
1,248 for its registered RX callback path from event dispatch. The current
linked image reserves 8,192 bytes. These figures exclude outer application
callers, traps/interrupts, reentry and other callback branches. The probe's
896-byte touched-canary footprint includes observer frames and is not an
exact minimum-SP measurement. Whole-program headroom remains unproven.

All 423 production WiFi inputs and the normal firmware image remain unchanged
in this probe batch. Evidence is retained under `build/wifi-bip-rv32-contract*`.
No full suite, hardware run, commit or push was performed; the broader review
remains active.

### RV32 BIP Transmit Probe

The compiled BIP TX append path has a separate RV32 execution probe at
`tools/check_wifi_bip_tx_oracle.py`. It binds the current normal
`mfp_add_mgmt_mic` and `mfp_compute_bip` sections, the normal AES-CMAC, frame
lease, station-epoch, key-selection and reservation helpers, and the real
descriptor/VIF/key/revision storage without changing their instruction bytes
or relocations. Fresh radare2 captures of both Nim entries
and the pinned vendor `mfp.o`/`mfp_bip.o` entries are retained with the result.
The vendor append routine has a group-key presence gate and directly writes
MMIE/IPN/MIC; Nim adds key metadata, frame-lease, revision and 48-bit IPN
checks. Its digest uses the same masked frame control and 18 address bytes.

```sh
.venv/bin/python tools/check_wifi_bip_tx_oracle.py \
  --wifi-object 'build/hw-validation/nimcache/m0_wifi_nimfw_boot_test/kernel/@pbl808@swifi_fw.nim.c.o' \
  --system-object 'build/hw-validation/nimcache/m0_wifi_nimfw_boot_test/kernel/@psystem.nim.c.o' \
  --qemu build/wifi-xuantie-qemu-build/qemu-system-riscv32 \
  --work build/wifi-bip-tx-current-audit
.venv/bin/python -m pytest -q tools/test_wifi_bip_tx_oracle.py
```

The probe passes 4,224 cases and 25,152 checks across two VIFs, both IGTK
slots, four starting IPNs (including the final usable one), six frame lengths
from 24 to 494 bytes, and both incoming interrupt-enable states. It compares
the complete 18-byte MMIE to independent `cryptography` AES-CMAC tags, checks
the 48-bit exhaustion return, and rejects six invalid key/selection states
plus five retired lease, changed epoch or in-progress key-update states.
An observer around the normal compiled CMAC finalizer's single 16-byte
`memcpy` changes selected key revision, frame generation, reset/VIF/station
epoch, group-key pointer or revision clock after MIC work and before the
append routine's final checks. Those states reject while retaining the
already reserved IPN and leaving the MMIE MIC zero. Unrelated VIF and key
changes accept and match the independent CMAC tag. The renamed firmware
`memcpy` keeps its original 28 linked instruction bytes; the observer also
checks the incoming interrupt-enable state.
The deliberately corrupted expected MIC fails at its designated third check;
all 21 result-parser tests pass. Evidence is under `build/wifi-bip-tx-current-*`.

The probe initializes production tables and executes 21 normal compiled WiFi
functions; it does not model the lease or key-binding predicates. Native BIP
TX tests cover source-level reentry/epoch behavior separately. The RV32
observer injects synchronous state changes at one digest-copy boundary; it
does not establish real asynchronous interrupt arrival, DMA publication order,
full vendor equivalence or on-air PMF. No production firmware or hardware was
changed by this probe.

### BIP Initial Replay Floor

Fresh IGTK installation now initializes the next-IPN representation to
`KDE IPN + 1`, including a KDE IPN of zero. Previously the vendor-derived
zero-value shortcut left the counter at zero, allowing a correctly tagged
counter-zero management frame once. IEEE 802.11-2012, 11.4.4.4 and 11.4.4.6,
requires initializing from the KDE and rejecting received IPNs at or below
that value. This is an intentional correction to the vendor behavior;
radare2 locates its zero shortcut at `vif_mgmt_add_key + 0x1b4`.

The pinned `vif_mgmt.o` also indexes VIF/key storage directly from the
arguments of `vif_mgmt_add_key` and `vif_mgmt_del_key`. The normal MAC command
path validates those indices, but the exported routines now independently
reject nil requests, VIF indices outside 0..1, and key slots outside 0..5.
These checks are an intentional no-op on malformed direct calls; the focused
VIF key suite checks unchanged storage in checked, ASan, and firmware-like
builds while retaining the valid-slot cases.

The supplicant supplies all six IPN bytes through
`bl_wifi_set_igtk_internal`; zero does not mean an absent counter. Data-key
initialization is unchanged. The existing same-key early return still
preserves live RX/TX counters and key revisions, including exhausted keys.

`tools/test_wifi_bip_key_install_rx.py` connects the production installer,
management-counter reset, segmented reader and AES/CMAC verification with
independent tags. Its 24 variants cover both VIFs and IGTK IDs, incoming
interrupt states, flat/chained frames, zero/nonzero/carry/maximum counters,
same-key reinstall, changed-key reset and bad MICs. Against the pre-fix source,
four variants fail the counter-zero receive decision and eight fail the
zero-floor state assertions; twelve controls pass. All 78 focused new and
adjacent tests pass after the correction.

The normal M0 build passes. Only `vif_mgmt_add_key` changes among 1,603 WiFi
instruction sections; image sizes and its 48-byte stack frame are unchanged.
An E907 probe passes 192 key-install sequences and 16,128 assertions using
normal compiled key/revision/reset helpers and original vendor instructions.
The pre-fix object fails its first zero-floor state check. The separate normal
BIP receive corpus still passes 11,856 cases and 142,272 assertions.

Evidence is retained under `build/wifi-key-replay-contract*`. Native tests
model descriptor storage and key-change notification; the key-install target
probe holds submitted RX empty and does not execute BIP MIC verification.
The separate target BIP corpus does not install keys. These checks do not
establish in-flight installation, real interrupt/DMA behavior, radio behavior
or readiness to flash. No full suite, hardware run, commit or push was used.

### Robust Action Key Setup

Two management-policy corrections distinguish robust Action frames from
handshake deauthentication/disassociation. With PMF negotiated and no IGTK
selected, RX now discards unicast robust Actions instead of bypassing the
policy. TX now requests pairwise protection for those Actions independently
of IGTK presence. The ADDBA sender's existing CCMP-header checks cancel the
response if the pairwise key is absent, unusable or exhausted; it no longer
falls back to an unprotected response. Handshake deauth/disassoc, non-PMF
peers, non-robust categories and group TX classification are unchanged.

IEEE 802.11-2012 11.5.16 distinguishes these key-establishment rules. The
[Linux receive policy](https://github.com/torvalds/linux/blob/v6.12/net/mac80211/rx.c#L2297-L2337)
also treats early robust Actions separately from handshake deauth/disassoc.
The pinned vendor's unconditional no-IGTK returns are retained in fresh
radare2/LLVM captures and intentionally differ from the corrected paths.

`tools/test_wifi_mfp_action_keys.py` adds twelve variants connecting the real
ADDBA builder, classifier, security-length/header code and PN reservation,
plus the real management producer and RX policy. The final fixture fails at
runtime against both saved pre-fix bodies in all twelve variants. All 93
selected new/adjacent native tests pass, including handshake and SA Query
exceptions and BIP integrity/lifetime checks.

A normal-object E907 policy matrix passes 22,400 cases/291,200 assertions,
with explicit expectations for the two vendor differences. Separate pre-fix
TX and RX probes fail their designated decision checks. The existing BIP
target corpus still passes 11,856 cases/142,272 assertions. The policy matrix
models table contents, not packet publication or crypto; native integration
retains modeled frame ownership and hardware state. The BIP corpus executes
the actual digest and RX identity helpers separately.

Only two of 1,603 normal WiFi instruction bodies change after pairing 27
numeric symbol renames: RX policy 1,652 to 1,700 bytes and TX classifier 142
to 172 bytes. Their static stack records remain 256 and 16 bytes. The normal
M0 build passes at text/data/BSS 512070/2372/177640. Evidence is retained under
`build/wifi-mfp-action-contract*`; this is not whole-firmware or hardware
readiness. No full suite, hardware run, commit or push was performed.

### Protected Management RX Formats

The RX dispatcher now checks management protection eligibility before decoding
or updating replay state. WEP is retained only for Authentication. Associated
CCMP management requires a PMF peer, an individually addressed robust frame,
and the pairwise-key path, not a data GTK. TKIP management, non-robust CCMP
categories and empty CCMP bodies are rejected. The unassociated WEP/subtype
check also precedes duplicate-cache writes, so an ineligible frame cannot
suppress a later retry. Data handling and valid shared-key Authentication
remain unchanged.

These are intentional protocol corrections to the vendor-derived common
decoder path. IEEE 802.11-2012 8.2.4.1.9, Table 8-38, 11.4.3.1 and 11.5.16
define the relevant frame/cipher rules. Group-addressed CCMP mesh management
is outside this non-mesh implementation. Fresh radare2/LLVM captures retain
the original vendor's associated decoder call at `+0x3fa`, management replay
call at `+0x442`, and unassociated WEP-only check at `+0x330..+0x33e`.

`tools/test_wifi_rx_mgmt_cipher.py` exercises real decoding and management
replay with modeled ownership/publication. Its final pre-fix fixture has
twenty runtime failures and four passing valid-protection controls. A separate
draft check reproduces duplicate-cache changes when the new unassociated
guard is placed too late. The selected regression run passes 203 tests:
115 compiled native variants and 88 result-parser checks. The management
sequence fixture was repaired to provide the descriptor/session guard used
by its copied commit block; its prior compile errors are not firmware findings.

A normal-object E907 matrix passes 69,120 management cases/414,720 assertions.
It executes 24 unchanged extracted WiFi sections, including actual replay
sidecar lookup and the normal Nim copy/zero helpers; normal linked memory
primitives retain their bytes. Four pre-fix controls independently reject
WEP forwarding, associated TKIP/CCMP counter updates and unassociated
duplicate-cache updates. Hardware decryption, descriptor/session ownership
and management publication are fixtures, not on-air validation.

The existing STA/AP data corpora pass 838,656 cases/12,065,088 assertions with
the new object. Only the dispatcher instruction body changes among 1,603
after pairing 46 numeric renames: 6,696 to 7,054 object bytes. Its static stack
frame grows from 144 to 160 bytes. The normal M0 image builds at
text/data/BSS 512390/2372/177640. The earlier selected BIP event-path accounting
would increase by these 16 bytes; whole-program headroom remains unproved.
Evidence is under `build/wifi-mgmt-cipher-contract*`. No full suite, hardware
run, commit or push was performed; broader firmware readiness remains open.

### RX Frame-Control Admission

Lower admission and the directly callable upper dispatcher reject nonzero
protocol versions and nonzero To DS/From DS fields on management/control
frames. The lower version check already existed; the direct-dispatch version
check and both non-data DS checks are new. Rejection precedes peer activity
in the lower event path and address, duplicate-cache, key and replay processing
in the upper path. Data DS combinations and `rxMacHeaderLen` are unchanged:
the latter classifies header lengths, not frame validity.

The archive-local `rxu_cntrl_machdr_len_get` in `rxu_cntrl.o` at object
offset `0x34` uses a 24/30-byte base from the DS bits, adds two bytes only
for QoS Data subtype `0x88`, and adds four whenever the Order bit is set.
The Nim `rxMacHeaderLen` deliberately uses control-frame 10/16-byte headers
and includes QoS fields for all QoS data subtypes, as required by the frame
layout; the direct RX wrapper calls that classifier. The focused header
oracle passes in checked, release, and AddressSanitizer modes. This is a
specification-based difference, not an archive-parity claim.

IEEE 802.11-2012 8.2.4.1.2 and Table 8-2 define these fields. This deliberately
corrects the inherited vendor address branch: fresh radare2/LLVM captures show
the blob testing DS fields at `rxu_cntrl_frame_handle+0x10c..+0x142`, then
reading Addr4 at `+0x144`, `+0x14c` and `+0x154`, before dispatch by frame type
at `+0x168`. This is not a claim of vendor on-air acceptance; hardware filtering
is outside the probe. Unsupported packed instructions elsewhere in the vendor
routine remain outside the executed comparison.

`tools/test_wifi_rx_frame_control.py` uses actual admission/dispatch bodies.
Its saved pre-fix run compiles all 32 variants, with twenty runtime failures
and twelve passing controls. An exactly sized 24-byte allocation reproduces
an AddressSanitizer six-byte read beyond the MPDU during Addr4 extraction.
Other cases expose peer processing, publication and header-state changes for
invalid fields. The selected final run passes 127 checks: 105 compiled native
variants and 22 header-oracle parser checks, not a full-suite run.

The normal-object E907 probe passes 3,866,624 cases/17,235,968 assertions. It
enumerates all 65,536 FC values at eight admission lengths and exercises invalid
version/non-data DS rejection directly, using both endpoint payload slots and
both incoming MIE states. Three saved-object controls independently fail lower
DS admission, upper DS admission and upper version admission. Session/descriptor
identity and completed storage are fixtures; actual payload-chain validation
executes. This does not prove full management-body parsing or physical DMA.

The preceding protected-management matrix remains green at 69,120 cases;
selected STA/AP data corpora remain green at 838,656 cases. Only two of 1,603
instruction bodies change after pairing 46 numeric renames: admission grows
from 520 to 538 object bytes and dispatch from 7,054 to 7,066. Static stack
usage is 64 bytes for admission (unchanged) and 144 for dispatch (previously
160); whole-program stack closure remains unproved. The normal M0 image
builds at text/data/BSS 512454/2372/177640. Evidence is under
`build/wifi-rx-fc-contract*`. No hardware run, commit or push was performed.

### RX Control Differential Probe

`tools/check_wifi_rx_control_oracle.py` compares the compiled `rxl_cntrl_evt`
with the original vendor routine in QEMU. The 6,336 paired cases cover empty
through ten-node queues, both processing-flag and incoming MIE states, both
VIF slots, unassociated/non-AP/station paths, data/QoS/control/probe/beacon
frames, both upper-RX and beacon results, and channel-context presence.

```sh
python3 tools/check_wifi_rx_control_oracle.py \
  --wifi-object build/nimcache_m0/@pbl808@swifi_fw.nim.c.o \
  --work build/wifi-rx-control-oracle
```

All 69,696 target assertions pass. The fixture compares station/VIF/header
bytes, software-descriptor metadata, remaining FIFO order, event bits and
ordered upper/free/beacon/traffic callbacks. Independent checks enforce the
four-frame budget, timestamp writes, release counts and final MIE state.
Nim's admission and frame-identity helpers execute; AP power-save is explicitly
excluded. Original vendor list-pop instructions also execute.

Upper RX, frame release, beacon/power callbacks and the platform timestamp are
models, not complete implementations exercised by this probe. Repeated event
sets are compared as idempotent bit updates, not as equal callback counts.
Popped-link clearing is intentionally excluded; remaining queue links are
checked independently. Four observation-error controls (`event`, `timestamp`,
`callback`, `queue`) must fail. No firmware instruction section changes during
fixture binding or symbol renaming. Radare2 captures both root ranges; LLVM
decodes the 67 retained function ranges. Read-only data sharing the probe's
`.text` section is not treated as function instructions.

The current routines agree within this normal non-AP scope. This does not
establish packet parsing, AP power-save, callback reentry, descriptor recycling,
physical DMA ordering, interrupt nesting, stack closure or readiness to flash.

### Station RX Configuration

Authentication and association frame construction preserve the installed MAC
registers and RX filter by default. VIF setup and scan start/finish own that
configuration; sending a frame does not restore scan-only receive flags.

`-d:bl808WifiAuthPromiscRx` enables the previous broad RX filter for these
builders. `-d:bl808WifiAuthHwWorkaround` enables the previous pre-authentication
MAC/address register reprogramming. Both are diagnostic overrides; enabling
both reproduces the former MAC/RX behavior.

### Power Table Adapter

The WiFi SDK's `trpc_update_power` and `trpc_power_get` interfaces use a packed
24-byte table (three 8-byte rate groups). The newer RF backend stores those
groups in 10-byte rows. The Nim adapter packs/unpacks these groups without
changing RF padding or the remaining rate families. RF channel-width config
reloads use a separate internal operation, not the WiFi table-pointer API.
The outer 38-byte WiFi table adds 14 channel offsets after the rate groups.

In the selected `phy_trpc.c.o:trpc_update_power`, radare2 shows one `wl_cfg`
pointer load at entry; every source row is derived from that saved pointer.
The Nim RF reload now captures it once for the whole operation. A focused
handoff test changes the global after the first row and verifies that all five
rows still come from the original configuration, while the existing adapter
matrix checks actual byte copies. The retained M0 Wi-Fi HAL function also has
one `wl_cfg` load at entry and reuses the saved register across all five row
copies. The build-only path passes;
this does not establish live RF power or on-device retune behavior.

The pinned `wl_api.c.o:wl_wlan_power_cfg_get` compares classes 0/1 and 4 as
full words, but masks the subtraction for classes 2/3 and 5/6/7 to a byte.
Thus 258/259 and 261..263 use the same groups as 2/3 and 5..7; byte-zero
and byte-four aliases remain invalid. Nim now matches this dispatch while
retaining the per-group index bounds. A focused native matrix checks accepted
calls and invalid-branch selection with a sentinel in place of the vendor's
infinite-loop trap; it does not execute that trap or measure RF power.

### Platform Zero-Return ABI

In `bl.o:bl_sleep_schedule`, a nonzero `wifi_hosal_pm_state_run()` result
branches at object offset `+0x10` to clear the nap state at `+0x12` before
the normal sleep/wake transition path. The local pending-work guard previously
ran first, so queued work could emit wake events even while the PM bypass was
active. Nim now keeps the guard but gives the archive's PM bypass priority;
the focused sleep-state test covers both PM results with queued work. This is
host scheduling parity, not an on-device sleep transition test.

Radare2 of the pinned `bl.o` shows that `ble_rf_ops` clears `a0` after either
RF on/off call, and `rfc_channel_ops` clears `a0` after `rf_init` and
`sm_set_channel_coex_connected`. Both exported Nim functions now return zero
instead of `void`; the PM adapter discards those values and retains its own
zero-result callback contract. The same object returns zero from all
`coex_pta_force_autocontrol_set` modes, `bl_pm_ops_register`, and the two-byte
`bl_nap_call`; those Nim exports now have explicit return values too. The PM
registration export also takes no argument, matching its C callers and its
vendor body, which never reads incoming `a0`. Focused
native tests check these paths and PM startup. The M0 WiFi image compiles,
and its retained Coex and PM-registration functions end in a zero return.
`bl_nap_call` is not retained in that image. This is an ABI and call-sequence
check, not a radio coexistence runtime check.

### Coexistence Transition Accounting

Radare2 of the pinned `arch_main.o` shows `coex_wifi_pta_forece_enable`
updates `pds_slept_time` for a prior state of zero and `pds_woken_time` for a
prior state of one. It does not update a combined counter. The unused Nim-only
`coexPtaAccum` state was removed; the focused tests still cover both counters,
timestamp wraparound, log timing, and the RF on/sleep/off sequence. The same
object confirms the PTI force bit extraction at bit 27 and the startup order
through `mpif_clk_init`.

`arch_main.o` calls `mpif_clk_init`, which the WiFi archive does not define.
The pinned SDK's BL808 `bl808_demo_event` Makefile explicitly links
`bl606p_phyrf`; its `phy.o` defines a two-byte `ret`-only `mpif_clk_init`.
The Nim and support-C no-ops therefore match that original BL808 demo
pairing, not merely an unrelated platform. The selected newer BL808 RF
archive defines no such hook, so the pairing does not establish MPIF clock
setup for this backend or replace a board-level clock check.

Channel-power offsets have a similar unresolved ownership gap. WiFi's
`bl_tpc_update_power_table_channel_offset` scales 14 offsets and calls
`phy_powroffset_set`, but none of the pinned BL808 archives define that hook;
both local BL808 implementations currently discard its input. The BL602 PHY
copies those 14 bytes into private storage and later consumes them from
`trpc_update_vs_channel`, which is also absent from the BL808 RF archive.
The BL606P PHY linked by the pinned SDK's BL808 demo defines a two-byte
`ret`-only `phy_powroffset_set`, as does the M1s BL808 SDK bundle's copy.
Thus the no-op matches the original demo pairing, but neither it nor the
selected newer RF archive establishes a register mapping for dynamic offsets.
The static TX power tests establish the call and scaling, not application of
dynamic channel offsets to transmitted power.
The public Nim full-table update, channel-offset update, and readback wrappers
also return without side effects for a null table pointer. The pinned WiFi
objects dereference that pointer; this is a local safety guard, covered by the
focused TPC adapter tests in checked, ASan, and firmware-like host modes.

The pinned BL808 RF archive does expose `rf_pri_input_channel_pwr_comp`, but
it copies 14 signed bytes into a separate 14-halfword RF table. Radare2 of
`rf_pri_set_channel_pwr_comp` shows that each valid channel selection reloads
that table from `wl_cfg` bytes 161..174 before applying RF compensation.
Aliasing `phy_powroffset_set` to the RF input function would therefore lose
the update on the next channel change and does not establish the intended
TRPC channel-offset behavior. The hook remains unresolved.
The current in-tree startup paths pass zero channel offsets, and no in-tree
production caller of either full-table updater was found. This narrows the
live zero-offset profile but does not establish how nonzero host-provided
offsets should affect transmitted power in another configuration.

### PHY Interrupt Ownership

The pinned `mac_irq` uses the full handler index from `0x24910040` for its
indexed table load; it does not mask the index to six bits. Nim previously
aliased out-of-range values to a valid ISR (for example 74 to modem slot 10).
It now rejects indices outside the 64-entry table and returns after reporting
an empty or invalid slot. This is a deliberate fail-closed behavior where the
vendor would read beyond the table or call a null pointer after its assertion.
The object relocation confirms that valid dispatch tail-calls `ipc_emb_notify`.
Focused native tests cover both invalid paths and valid modem/RC dispatch;
they do not exercise a real MAC interrupt.

A radare2 relocation comparison now checks the complete 64-slot
`intc_irq_handlers` table against the compiled Nim initialization, including
all 28 populated entries and the nil slots. The vendor `intc_init` enable
sequence also matches Nim's 19 IRQ numbers. This is dispatch-table and call
sequence evidence, not proof of interrupt delivery on hardware.

The selected RF backend's `phy_mdm_isr` is a no-op. `phy_rc_isr` reads the
modem status at `0x24C0B41C` and acknowledges it at `0x24C0B420`. Channel
setup retains its separate pulse at `0x24C00888`; the modem interrupt must
not acknowledge RC status or initiate a channel-change pulse.

The older SDK PHY differs: its modem handler logs only, while its RC handler
also has a legacy pulse. Those older RC side effects are not transferred to
the selected backend's modem handler.

### PHY Capability Fields

The selected RF backend reads modem-version bit 22 for VHT and bit 21 for HE.
VHT is also available when the bandwidth field at bits 25:24 is nonzero.
The bandwidth test uses a second volatile version-register read, skipped
when the first read reports bit 22. It does not reuse the first sample.
LDPC TX/RX use bits 26/27, beamformee/beamformer use bits 28/29, and MU-MIMO
RX/TX use bits 30/31. Bandwidth bits must not stand in for LDPC support.
Station TX policy enables LDPC only when both the local TX capability and the
peer's HT LDPC capability are present.

`phy_get_antenna_set` uses the TX-chain count at bits 7:4, not the RX count at
bits 3:0, and returns the low byte of the resulting chain mask.
`phy_set_group_id_info` reads an 8-byte membership bitmap and 16-byte user
position array as little-endian byte sequences without requiring word alignment.

### PHY Readback And Initial TX Power

Radare2 of `crm_bl616.c.o:crm_init` shows an RF clock-mux read, mask
`0xF7FFFFFF`, and insert `0x08000000` at CRM `0x24940010`. Nim previously used
`0xF8000000` as the keep mask, clearing the lower 27 bits before PHY startup.
It now preserves the existing word while setting bit 27. A focused native
trace checks the init store, adjacent modem-reset pulse and delay order, and
both bandwidth clock selections across varied starting words. This register
sequence correction does not by itself establish clock timing on the board.

Radare2 of `phy.c.o` shows PHY assertion calls pass the failed expression in
`a0` and the literal `module` in `a1`. The local `phy_set_aid` and
`validatePhyInitFieldFits` calls had those arguments reversed; the initial
clock assertion used abbreviated strings. They now retain the vendor
expression/module pair. A focused host test checks the AID and narrowed-field
assert arguments as well as the two-sample clock diagnostic. The current
assert wrapper records diagnostics and then hard-stops by default, matching
the RF archive. Returning from selected diagnostic lines requires the
`bl808WifiDebugContinuePhyAssert` build define. This corrects diagnostic ABI
data rather than normal RF register behavior.

The same `phy_init+0x16..+0x32` reads `HDMVERSION` at `0x24C0003C` twice for
its clock/version check; other PHY capability queries read `HDMCONFIG` at
`0x24C00000`. Nim had used the latter for both, producing `clk=0x10E` from
the saved `0x0C822111` configuration word. The initialization check now
samples the version register twice. A focused test presents different words
at both addresses and checks that the configuration register is not read.
The old UART log predates this fix and does not show the board's version word.

At `phy_init+0x176..+0x1B0`, the object updates `HDMCONFIG`-derived bits
of `0x24C00820` without an intervening write to `0x24C00800`; Nim had an
extra repeat of its earlier `0x800` field update. At `+0x304..+0x314`,
the object clears `0x24C00824[16]` with mask `0xFFFEFFFF` before inserting
version bit 31. Nim cleared bit 17 instead, erasing the preceding
version-bit-21 setting. The port now keeps both bits independent and the
object's two-write `0x800` sequence. A focused trace covers all four bit
combinations and the register-store count.

At `phy_init+0x2EE..+0x300`, the object also preserves the existing
`0x24C00870` word while setting bit 24. Nim had omitted that write and
instead performed five unrelated modem stores at offsets `0x930`, `0x3BC`,
`0x414`, `0xC40`, and `0xC44`; those stores are absent from this object path.
The same preserve-and-set mask appears in the pinned 20 MHz
`mdm_set_channel` branch. Nim's broader mask had cleared high control bits
there. Both paths now use `0xFEFFFFFF` as the keep mask; focused traces
check the init store order and the channel branch across varied words.

The pinned `phy_init+0x8A4..+0x938` has eleven post-AGC stores before
`rc2_config_rxgain`: the `C864` power-detect word, `B390` gain bits,
`C834` ADC power input selector, `B304` threshold, three `C814` receive-path
fields, and two updates each to `C040` and `C044`. Nim previously ended its
AGC core phase at `B414`, omitting those normal-mode stores. The restored
tail keeps the object order and masks; a randomized MMIO trace checks the
resulting writes. Low-power initialization has a separate, different tail.

The normal AGC event register at `0x24C0B384` previously received
`0x1800` in its combiner field where `phy_init+0x722` inserts `0x800`.
The low-power `0x24C0B388` operand field previously received `0xA8000`
where `lp_phy_init+0x644` inserts `0x4000`. Both values now match their
mode-specific objects; focused traces cover the surrounding writes.

The pinned `phy.c.o:phy_set_channel` early-return check compares the first
channel word, PHY flags, primary frequency, and both center frequencies
(`center_freq2` at object offsets `+0xee..+0xf6`). It does not
compare the descriptor's TX-power byte. Nim follows both decisions: a
secondary-center-only change refreshes the stored descriptor, while a
TX-power-only change is a no-op. The focused PHY descriptor transition test
covers both cases.

At `phy_init+0x9b6..+0x9fc`, the archive reads all nine configuration words
before writing the channel sentinel, then copies the words and finally writes
the center-frequency sentinel. Nim now preserves that snapshot and write
order, including the two packed 32-bit sentinel stores. A focused overlapping
input/output test catches interleaved reads and writes; the M0 Wi-Fi HAL
build-only path compiles. This is memory-publication parity, not evidence of
radio bringup on hardware.

The selected RF channel getter samples both aligned channel words before either
output store. The backing storage is explicitly word aligned, avoiding byte
loads through its packed halfword view. Its index argument remains unused.
Radare2 shows `phy_update_power_table` separately loads the channel-type byte
at `phy_env+37` before tail-calling `trpc_update_power`. Nim now uses a byte
load instead of reading the containing 16-bit field; a focused test checks the
access width and all 256 channel-type values.
The gain-index helper clamps
signed input to -10 through 22 and writes back only when clamping; valid input
is not rewritten. The output always receives the resulting low byte.

The writable 50-byte `txpwr_vs_rate_table` starts with value 20, not 19, at
indices 24 and 44 (MCS 4 in rows 2 and 4). These are initialization defaults;
later configuration and table updates retain their existing ownership. This
comparison uses `phy.c.o` and `phy_trpc.c.o` from the separately documented RF
backend, not the older WiFi archive as evidence for a newer ABI. The compact
WiFi table adapter is reviewed separately below. Native contract tests and linked-image
checks do not establish over-the-air behavior or readiness to flash.

### TPC Channel-offset Callbacks

Radare2 and T-Head-aware LLVM disassembly of the pinned `tpc.o` show that
`bl_pwr_find` loads the first power byte unsigned but subsequent candidates
signed. A high-bit first byte therefore keeps index zero even if a later
positive byte is larger as a signed value. The Nim helper now preserves that
selection for normal eight-entry groups while retaining its local termination
guard for counts above 255. `tpc_update_tx_power` compares signed candidates
against the zero-extended stored winner, matching the archive.

The WiFi `bl_tpc_power_table_get` zeroes bytes 24 through 37 after reading the
24 rate bytes. Both WiFi table-update entry points scale channel offsets for
`phy_powroffset_set` but do not persist those input bytes in a WiFi-side
readback cache. The Nim adapter no longer adds those stores. A focused native
test checks the resulting table and callback behavior in checked, release,
and ASan modes; physical transmit-power behavior is not established.

The pinned WiFi channel-offset updater narrows each scaled offset to a signed
byte before passing it through C varargs. Its two messages contain real CRLF
bytes. The printer slot is read again for each of the 14 channel messages and
for completion, so a callback replacement is observed on the next message.
The Nim adapter retains its nil-printer guard. Its final PHY hook remains a no-op, matching the pinned SDK helper;
the selected newer RF archive has no equivalent export. This path is not
evidence that configured channel offsets alter physical transmit power.

### WL Memory Binding

`wl_cfg_get` and `wl_env_get` bind WL configuration, calibration storage and
environment pointers without rebinding `rf_calib_data`. The RF initializer
performs that separate binding through `rf_pri_init_calib_mem`. Configuration
lookup returns the current config pointer after initialization, rather than
its originally supplied buffer. Local nil guards for both lookups and LP init
clear WL bindings only; the vendor does not define these nil-input paths.

The normal Nim profile clears parameter/capcode callbacks before `wl_init`.
Exported callers may install others, so the generic callback bound remains
open. `tools/check_wifi_rf_memory_binding.py` checks the retained RV32
environment getter and explicit calibration binder using radare2 ESIL. It
does not emulate hardware or configuration initialization; radare2 6.2.6's
compressed-jump ESIL limitation prevents treating those paths as verified.

### Freestanding Console Formatting

The pure Nim backend renders integer, string, character and pointer formats
without libc or heap allocation. The C bridge only traverses `va_list` and
provides the stdio entry points. `snprintf` now writes bounded, terminated
output and returns the untruncated length; `sprintf` uses the same renderer
with caller-owned capacity, and `printf` returns the rendered count. Count
overflow returns -1. These count/truncation rules follow
[printf(3)](https://man7.org/linux/man-pages/man3/printf.3.html).

The supported subset includes `d/i/u/o/x/X/p/s/c/%%`, integer length modifiers
`hh/h/l/ll/j/z/t`, flags, width and precision, including `*` arguments.
Signed minima are formatted without signed negation overflow. Unsupported
conversions, including floating point, wide characters, `%n` and positional
extensions, return -1; this is not a full libc implementation. Null strings
render as `(null)` and null pointers as `0x0`, which are local policies.
UART newline translation and the legacy C WiFi/BLE adapters are unchanged.

`tools/test_wifi_console_format.py` exercises the actual adapter rather than
host-libc substitutes, including configuration dumps and assertion traces.
`tools/run_wifi_console_format_probe.py` links the compiled M0 support object
into a QEMU RV32 probe for variadic ABI checks without touching hardware.
Neither check models UART timing or establishes physical radio behavior.
Scoped stack bounds require four ELF-hash-pinned intra-function jump-table
declarations, not callback target assumptions. The buffer-formatting paths
estimate 416 bytes and `printf` 448 bytes in the checked M0 build. Assertion
logging and generic RF callbacks remain incomplete; these are not whole-image
or interrupt-stack bounds.

### MAC Timing Diagnostics

The pinned `hal_machw.o:hal_machw_timing_info` prints two headers before
reading timing registers, then reloads the field-printer slot for each value.
Its E4 middle field extracts bits 17:8; Nim previously included bits 23:18
and used several incorrect field names. The dump now uses the archive's
register order, field widths and format strings. The focused host test covers
all 24 fields, printer replacement, and register addresses in checked, ASan,
and firmware-like modes. The M0 NimFw image builds, but the linker discards
this diagnostic from the boot ELF; no hardware output has been validated.

The pinned SDK's BL808 demo links `bl606p_phyrf`, whose
`phy_get_mac_freq` returns 40 MHz. The WiFi `hal_machw_init` also writes 40
to its MAC-clock field. The newer selected RF archive's `crm_get_mac_freq`
returns 60 MHz, but forwarding that value through the WiFi PHY shim caused
MAC delays to be rescaled for 60 while advertising 40. Both NimFw and the
legacy C adapter now return 40 for the WiFi-facing PHY query; the RF CRM
helper remains 60. The focused MAC timing test runs the real Nim shim and
initializer in checked, ASan, and firmware-like modes. The supported NimFw
M0 image builds and its object emits a 40-MHz return. The repo rejects a
vendor-WiFi build, so the legacy C adapter has only source-level coverage.

### CFG Requests And VIF Statistics

The pure Nim configuration path uses the pinned archive's 13 typed records:
eight MM, three SCAN and two SM entries. Values refer to the live owning
environments, not an ID-indexed scratch array. Matching compares all three
32-bit selectors and forwards the record plus both opaque arguments to its
three-argument setter. General get/set return the vendor's zero result.
The record exposes its set/get/notify pointers at offsets 16/20/24 on RV32.

SET is operation 0, GET/RESET are no-ops 1/2, and DUMP is 3. The firmware
decodes the inline scalar once, logs through the printf operation, dispatches
the value and returns the zero-status confirmation to the original requester.
The TLV helpers implement the pinned SDK's four-byte Boolean and UINT32
formats, including short-buffer defaults and negative error codes; the other
SDK types remain unsupported. Short/inconsistent SET payloads cannot update
configuration. Zero-initialized Boolean diagnostic padding and snapshots of
command/reply metadata across callbacks are local safety policies.

The scan environment now names passive/active durations at vendor offsets
12/16. The selection branch and registry pointers change together, preserving
the blob's passive-flag behavior while allowing each configured dwell time
to affect its intended scan mode. Configuration dumps walk the same typed
records and use the vendor's field formats and callback-slot reloads.

`vif_mgmt_statistic_dump` reads the active list at environment offset 8,
reports beacon timeout/receive/TBTT counters, and preserves full pointer and
unsigned counter widths. AP/STA/unknown labels and time scaling match the
blob. A bounded, interrupt-protected snapshot before output is a local policy;
the blob itself walks live records. Output callbacks run after restoring the
prior interrupt state and are reloaded between calls.

`tools/test_wifi_cfg_path.py` and `tools/test_wifi_vif_statistics.py` exercise
these contracts without hardware. CFG handler/kernel callback bounds and
physical scan behavior remain separate validation requirements.

### Support Timing

The reviewed `wifi_main` sequence already uses the vendor's two 100-microsecond
delay calls around the clock toggle and is unchanged. The SDK's external delay
implementation uses core/cache-dependent busy-loop timing; the Nim support
layer uses the existing microsecond timer with an approximate loop fallback.
These are separate platform implementations, not instruction-parity claims.

Timer reads retain volatile high/low/high sampling but stop after eight failed
attempts. The last coherent timestamp is cached under the M0 interrupt lock;
time getters retain that value when sampling fails, and delays receive an
explicit failure result. The new `nim_wifi_dbg_mtime_read_failures` counter
reports this condition. This bounds software retries, not an individual stalled
bus transaction. The cached value does not invent elapsed time.

Delay caps and fallback budgets widen before arithmetic, and large fallback
budgets are split without truncating the requested loop count. Zero delay is a
no-op. The signed deadline comparison explicitly preserves modulo-64-bit
arithmetic, including in checked builds. Fallback loop calibration is unchanged
and still needs physical validation.

Adapter sleeps retain cooperative polling and use wide microsecond durations,
avoiding RV32 signed-long overflow when converting seconds. Completed delay
quanta also consume the request if the timer stops progressing; valid elapsed
time includes polling work. Nonpositive millisecond sleeps return immediately.
Both sleep entry points return the pinned adapter's `pdTRUE` (`1`) status.
The tick getter explicitly wraps its millisecond value to 32 bits.

`tools/test_wifi_support_timing.py` covers rollover, incoherent/stalled clocks,
large budgets, sleep conversion and IRQ state with a modeled 32-bit long ABI.
RV32 probes use RAM clock registers and a polling fixture, not a physical timer.
These local progress and recovery rules do not establish calibrated delays,
complete callback bounds or hardware readiness.

### Adapter Wait And Queue Contracts

The pinned SDK implements these operations in its external `bl_os_hal.c` and
FreeRTOS sources, not inside `libwifi_bl808.a`. The blob's `ipc_emb_wait`
indirect call at adapter offset `0x50` is the separate task-wait operation;
reviewing that call does not establish event, semaphore or queue behavior.

Event waits return full bit snapshots on success and timeout. A send delivers
the same pre-clear snapshot to all matching active waits, then clears the union
of their clear-on-exit masks. The synchronous send returns the remaining bits.
Queues copy their configured fixed item size, ignore the adapter's `length`
and `prio` arguments as the SDK does, and return `0` on success or `1` on failure.
Bounded read/write positions and a separate count preserve FIFO order without
32-bit monotonic-cursor rollover. Zero-size signaling items are supported;
zero-depth queues and allocations exceeding the RV32 size range are rejected.

Cooperative waits use the SDK's 1000-Hz tick units and the existing delay
progress fallback. Zero-time requests never poll. Requests made with M0
interrupts masked may complete immediately, but never poll or block. Object
state and queue copies are protected by the M0 interrupt lock. Deletion marks
an in-use object for deferred cleanup, so polling callbacks cannot free storage
that the active wait will revisit. Completed event deliveries retain their
snapshot; deletion cancels other waits. Handles are invalid after final deletion.

Semaphores retain the SDK's binary capacity. The local adapter honors the
documented initialization and timeout arguments, normalizing nonzero initial
values to one. This is an intentional difference from the pinned C adapter,
which ignores initialization and uses an infinite task-context take timeout.

`tools/test_wifi_adapter_waits.py` covers these contracts with modeled clocks,
IRQ state and callbacks. RV32 unit probes execute compiled adapter sections
with explicit allocator, polling and RAM-clock fixtures. These checks do not
establish RTOS task scheduling, `FromISR` deferred event status, multicore
synchronization, calibrated timing, callback/IRQ stack closure or hardware
readiness. Multitask and mutex scheduling remain outside that batch. Timeout
objects and task notifications are reviewed separately below.

The Nim bare-metal mutex adapter now allocates distinct handles instead of
returning one sentinel for every mutex. A wrong-handle unlock cannot release
another lock's interrupt mask; deletion while locked defers freeing until the
last unlock, and lock acquisition preserves an already-masked IRQ state.
Focused host cases exercise nested handles, invalid operations, deletion, and
allocation failure. This does not add task scheduling or make the mutex a
multicore synchronization primitive.

The pinned SDK's `components/os/bl_os_adapter/bl_os_adapter/bl_os_hal.c`
returns the current task handle from workqueue creation, and both submit
variants notify that handle while ignoring the worker, argument, and delay.
The Nim single-context adapter now uses its task notification for this path;
an unknown handle reports failure instead of silently succeeding. The same SDK
adapter creates `void (*)(void *)` timers with separate one-shot and periodic
start slots. Nim now retains callbacks and arguments, dispatches due timers
from the backend poll when IRQs are enabled, and defers freeing a timer deleted
inside its callback. Periodic dispatch skips missed intervals, and rotation
prevents a full 16-callback poll budget from starving later timers. An in-flight
guard prevents a callback that polls or restarts its timer from reentering
itself before it returns. Timer delete preserves the SDK's `1`-on-success
convention. Positive sub-millisecond
requests are clamped to one 1000-Hz tick locally; invalid intervals or an
unreadable M0 clock fail start instead of reporting success.
`tools/test_wifi_adapter_timers.py` exercises these behaviors with modeled
clock, IRQ and allocator state in checked, release, ASan and firmware-like
modes. This is cooperative poll behavior, not an RTOS timer service or
on-device timing validation.

The same pinned `bl_os_hal.c` leaves `_event_register` as a no-op but routes
`_event_notify` through `aos_post_event(EV_WIFI, event, value)`. The previous
Nim adapter and AOS facade both returned success without delivering that
event. The Nim path now queues up to 64 events, strips the AOS urgent flag,
and dispatches to up to 16 registered filters from the backend poll. The
event record uses the SDK's time/type/code/value/extra layout; registration
and first-match unregistration follow `components/stage/yloop`'s filter API.
The pinned `local_event.c:aos_post_event` zero-initializes the time field and
the event device copies it unchanged; Nim now leaves it zero too.
Callbacks receive a snapshot of the filter list and run outside the IRQ mask;
nested polls cannot reenter the dispatcher. A full queue reports failure
instead of silently dropping a successful post. The pinned event device's
successful `aos_post_event` result is the event record byte count (16 on
RV32), not zero; the local OS `_event_notify` returns that value. Filter
registration and delayed-action errors use the pinned negative `EINVAL` and
`ENOMEM` results, with a local clock-read failure reported as `-EIO`.

The exported `aos_post_delayed_action` no longer reports success without
scheduling. A 32-entry deadline queue runs due actions from the backend poll,
and `aos_cancel_delayed_action` removes the first callback/argument match,
optionally constrained by delay, matching the pinned yloop contract. An
action with a negative delay retains its signed offset, so it precedes a
zero-delay action posted at the same time, as in the pinned `yloop.c`.
The modular deadline comparison preserves that order at tick zero. An
unreadable M0 clock or full queue reports failure. These paths are covered by
`tools/test_wifi_aos_events.py` and `tools/test_wifi_aos_delayed_actions.py`
in checked, release, ASan and firmware-like host modes. The event service
remains cooperative: delivery requires backend polling, and no real RTOS task
creation or on-device scheduling behavior is established.

The pinned adapter delegates `_task_create` to FreeRTOS `xTaskCreate`, whose
success status is `pdPASS` (`1`). The Nim cooperative backend has no task
scheduler and now returns the allocation-style failure status (`-1`) without
writing a task handle or invoking the entry. The pinned WiFi archive has no
direct `g_bl_ops_funcs+0x3c` relocation, and the inspected base-relative
`0x3c` loads belong to other structures; this does not prove the slot is
unreachable through every linked integration path. Task creation remains a
known unsupported capability, not a successful no-op.

### Timeout Objects And Task Notifications

The pinned `td.o` radare2 ranges corroborate the Nim traffic-detection
path: `td_start` checks the active byte at offset 42 before reading MAC time;
`td_reset` clears one 44-byte slot and installs `td_timer_end` at offset 4;
packet indications increment the offset 24/28 or 32/36 counters. In
`td_timer_end`, the offset-43 gate precedes threshold evaluation, the
offset-41 flags are updated after the optional status callback, and a
nonzero callback result suppresses the next timer arm. The three focused TD
test modules pass 30 cases. This verifies the inspected static control flow
and native behavior, not target timer scheduling or radio traffic.

Timeout creation now allocates an owned timestamp object, including at tick
zero; callers release it through the ordinary adapter free operation. Timeout
checks subtract elapsed milliseconds, not the number of calls. The saved
timestamp advances on a nonexpired finite check, an expired budget becomes
zero, and the forever sentinel remains unchanged. Full-width uptime prevents
32-bit tick wrap or multiple tick revolutions from hiding elapsed time. This
matches the pinned FreeRTOS non-aborted timeout path; there is no task-abort
state in the cooperative adapter. Allocation failure returns nil, and checks
of nil handles or budget pointers report expiration rather than dereferencing
them. A stalled clock does not itself consume ticks in these nonblocking queries.

The current-task and notification-create callbacks return the same stable,
non-owned handle for the single cooperative M0 execution context. Normal and
ISR notify callbacks increment its 32-bit count under the interrupt lock.
Task wait clears all pending notifications, as the SDK's `ulTaskNotifyTake`
with clear-on-exit does, and otherwise uses the shared cooperative wait budget.
As in the SDK, the take operates on the current context rather than its handle
parameter. The ISR callback returns zero because this adapter has no preemptive
priority scheduler or context-switch request; this is not emulation of the
SDK's higher-priority-task-woken flag. Task creation/deletion and ISR yield do
not gain RTOS scheduling behavior from this change.

Radare2 and LLVM confirm that the blob's IPC initialization captures the task
handle at operation `0x44`, notify uses `0x4c`, and wait uses `0x50` with an
all-ones tick argument. The IPC wait callback is now correctly typed as `void`
with a 32-bit unsigned timeout. The handle is distinct from the 20-byte IPC
state structure. The pure-Nim `wifi_main_poll_once` service remains explicitly
nonblocking; only the requested blocking service/wait paths use these waits.

`tools/test_wifi_task_timeouts.py` covers ownership, elapsed-time boundaries,
tick wrap, coalesced notifications and the IRQ/IPC bridge. Target-code probes
execute the compiled timeout/notification and IPC callback paths with allocator,
polling, assertion and RAM-clock fixtures. These are not full-system boots,
physical timer validation, multicore synchronization or proof that arbitrary
polling callback recursion fits the available stack.

### Notification Callback Contracts

The MM configuration notifier uses the typed configuration record, two opaque
pointer arguments and an operation byte, and returns zero. Its platform log
call uses `mm.c`, line 1826, the entry name and the vendor's operation format.
The vendor's `notfied` spelling is retained. This replaces the unrelated source
strings and fixed-argument logger cast used previously.

All six notifier-chain entry points and six nap wrappers return the vendor's
zero status. Callback return bits remain ignored, priorities remain descending
and traversal still reloads the next link after each callback. Normal calls
restore the incoming interrupt state on Nim exception paths too; this is a local
cleanup rule, not a behavior inferred from the C blob. Critical variants do not
change interrupt state. Missing log hooks remain optional.

Radare2 of `notifier.o` shows the normal register, unregister and call entries
use `g_bl_ops_funcs` slots 20 and 24 to enter and leave the platform critical
section. Nim now uses those callbacks when both are installed, falling back to
direct CSR save/restore before the callback table is ready. The focused native
test checks both paths and balances entry/exit on every normal return.

The pinned `notifier_chain_unregsiter` calls its IRQ-restore callback only when
the requested node is absent. Its found-node branch unlinks and returns with
interrupts disabled. Nim deliberately restores the saved state on both paths;
the focused test covers removal and a subsequent missing-node call with
interrupts initially enabled and disabled. The vendor call loop also samples
the head before masking interrupts, while Nim samples it after masking, avoiding
a concurrent head change during entry.

The vendor insertion path does not detect a node already on the chain;
registering it twice makes a self-link. Nim now treats duplicate registration
as a no-op, preserving the zero-result API and the current list order even if
the node's priority was modified. Normal registration still brackets that
check with IRQ save/restore; the from-critical variant leaves IRQ state alone.

`tools/test_wifi_element_notify.py` and `tools/test_wifi_notifier_next.py` cover
the callback ABI, result values, traversal and cleanup. Compiled RV32 unit checks
exercise the exported C entry points with non-throwing callbacks. The current
`m0_wifi_nimfw_hal_test` build compiles but dead-strips the notifier entries;
these checks do not establish an active target path or hardware readiness.

### TX Snapshot Boundaries

`sm.o:sm_auth_send` and `me_mgmtframe.o:me_build_authenticate` produce the
reviewed 24-byte authentication header, three halfword body fields, optional
128-byte challenge IE, and AC 3 normal frame submission. No valid-input
frame-byte or length mismatch was found. Initial authentication allocates
through `txl_frame_get`, which copies the global frame rate template with
rate word `0x400`; `rc_get_initial_rate_config`,
`rc_get_lowest_rate_config`, and `rc_update_retry_chain` do not select that
initial management rate. The normal `txl_transmit_trigger` head/secondary
status gates, confirmation route, and timer rearm match `txl_cntrl.o`, with
33 focused trigger-owner cases passing. The saved no-ACK UART trace predates
these reviews and does not prove current on-device behavior.

The pinned `txu_cntrl_frame_build` builds MAC/security/SNAP headers backwards
from its second argument. Payload addresses and lengths are separate descriptor
arrays at offsets 52/68; the end of the inline header is not a payload pointer.
The builder's address mapping, sequence handling, SNAP boundary and untouched
Duration/ID match the reviewed vendor path. Unlike the vendor's unchecked
builder, the Nim path rejects invalid VIF indices and header reservations
before writing SNAP or MAC bytes. An encrypted descriptor without a current
packet-number reservation is not considered current. A descriptor whose
security-header or MIC/ICV tail length differs from the selected key is
rejected before any header write. Unkeyed descriptors do not require a
packet-number reservation.

The Nim-only IPv4 diagnostic previously sampled descriptor padding as payload
and could read beyond the header allocation. It now gathers up to 32 payload
bytes from the descriptor spans, bounded by each span, the declared frame length
and snapshot capacity. It shares the DMA builder's chain validation and does
not sample payload from inconsistent chains. Its exported length is the number
of bytes captured; unused snapshot bytes are cleared. The payload word comes from that prefix,
zero-padded for short payloads, and an absent security header reports zero
instead of the following SNAP bytes. These are diagnostic corrections, not a
change to transmitted packet bytes or a vendor diagnostic-parity claim.

`tools/test_wifi_tx_diagnostic_bounds.py` exercises exact header allocations,
separate/fragmented payloads, short frames and stale snapshot tails. Compiled
RV32 unit probes model security-header output and logging, not radio/DMA
execution. Hardware behavior and complete callback bounds remain open.

In the pinned `txl_frame.o`, `txl_frame_push` clears hardware-descriptor
offsets 8, 12, and 64, masks control-word bits with `0xFF87FFFF`, and sets
ACK policy bit 9 only for unicast non-control frames (`+0x402..+0x450`).
`txl_frame_push_force` instead sets that bit for any unicast frame
(`+0x484..+0x4ac`). The focused frame-preparation test checks both branches
for control/data and unicast/group addresses in checked, release, and ASan
modes. These host checks do not establish actual MAC acknowledgments.

The pinned `sm.o` auth and association builders set descriptor byte 49
(`staInfoIdx`) but do not set byte 46 (`staIdx`). The latter is a TX header
selector: the backup path reassigns sequence control when it is `0xFF`.
Nim no longer writes the station index into byte 46 for those two management
frames and resets that byte on internal-frame allocation, preventing a prior
lease's selector from changing a freshly built sequence number. Focused
allocation, auth-frame, backup, and internal-preparation tests pass. The reset
is a local reuse guard, not an instruction-for-instruction vendor behavior.

The pinned `txl_cntrl.o` checks channel admission, AP power-save admission,
and then publishes the fake-transfer link and pending queue before invoking
the payload drain. Its `txl_int_fake_transfer` link stores and the adjacent
`chan.o:chan_is_on_channel` and `apm.o:apm_tx_int_ps_check` gates match the
reviewed Nim branches. The archive restores IRQ state before packet-count
accounting and payload drain in the two internal push functions. Nim keeps
publication and counting in one critical section so completion cannot
overtake accounting, then restores the caller's IRQ state before those drains;
the drain acquires its own IRQ lock. Pre-publication preparation and the
postponed path still hold a wider outer scope than the archive. The ordinary
`txl_cntrl_push` is different: its archive calls the drain while MIE is still
masked, before pending-list publication, and Nim retains its IRQ mask through
the drain while publishing ownership first. Focused ownership, reset, and
drain tests cover both enabled and already-masked callers, and a build-only
M0 WiFi HAL image compiles. This remains static scheduling evidence, not an
over-the-air ACK or flash-readiness claim.

Radare2 and T-Head-aware disassembly of `txl_cntrl.o:txl_payload_handle_backup`
confirm the five AC head registers, DMA-status fields, start/resume trigger
masks, timeout constants, and hardware-descriptor link stores used by Nim.
The modeled backup and trigger-owner suites pass 35 focused cases. In
`txl_transmit_trigger`, the archive selects from TX-status bits 10:6 and
tests the head descriptor's signed word at offset 64; the secondary-ready
gate reads offset 60. Nim uses those same fields. Its exported
`nimfw_dbg_txtrig_acready` records the last raw TX-status sample, not an
accumulated ready-bit count. A zero in the older saved UART log therefore
cannot establish that the AC was never ready; that log also records 30 frame
confirmations. The saved run predates the current source and cannot validate
the present radio or establish why MAC acknowledgments failed.

In `txl_cfm.o:txl_cfm_evt`, MIE is restored immediately after
`co_list_pop_front`, before `me_tx_cfm_singleton`, `txu_cntrl_cfm`, and
`ipc_emb_txcfm`. Nim restores the caller's IRQ state after installing an
active flush owner and snapshotting diagnostics, but before those callbacks.
The owner guard lets a nested reset or flush retire the detached completion
without a second delivery; IPC publication takes its own IRQ lock. Focused
completion, reentry, host-owner, and publication tests cover enabled and
already-masked callers plus nested retirement. The short interval between
the vendor's restore and Nim's restore remains a scheduling difference, not
an interrupt-latency or on-device correctness claim.

The pinned `txl_cfm.o`, `txl_cntrl.o`, and `txl_frame.o` assertion relocations
resolve to the condition text and `"module"` file string, not the C filename
in both argument slots. At `txl_cfm_evt+0x4a`, the condition is
`ke_evt_get() & evt_bit` (line 346); the invalid-AC branch of
`txl_cntrl_halt_ac` uses `0` (line 1792), and `txl_transmit_trigger` uses
`access_category < NX_TXQ_CNT` (line 2156). Both frame-push paths use
`(thd->datastartptr & 0x01) == 0` (lines 316 and 367). Nim now passes those
diagnostics to its returning assertion handler. Its post-assert recovery and
ownership checks remain local behavior, not an emulation of the vendor's
fatal assertion path.

### RF Power Replay

The selected RF backend packs live WLAN/BZ power rows before replaying the
matching calibration records. Low-power compensation uses the vendor's coarse
row selection and residual adjustment, including its asymmetric rounding and
saturation. Calibration selection follows the live WLAN index table rather
than its default values.

Runtime low-power compensation replays only WLAN fields; BZ target-power
changes replay only BZ fields. Both preserve live unowned register bits and
publish power fields before calibration fields in vendor store order. Saved
records, including zero-valued records, supply calibration fields on every
board and crystal configuration. Explicit calibration restore publishes only
calibration fields for both domains; initialization's follow-up publishes only
power fields. The legacy whole-bank publication path is not used.

`rf_pri_set_channel_pwr_comp` in the pinned `rf_pri.c.o` reloads `wl_cfg`
after its low-power replay call, before reading the signed temperature byte at
offset `0xbd`. Nim now does the same, so a configuration handoff during replay
does not use the old temperature baseline. The focused channel-compensation
test covers rebinding and nil storage at this boundary. After the measurement
call, the vendor captures the computed halfword, clears the measurement-pass
flag, and only then publishes the applied-compensation halfword; Nim now
preserves that order before the final temperature update. Nim retains its
1..14 channel-index guard; the archive's low-byte admission also accepts
aliases that lead to out-of-bounds reads in the called low-power helper.

Initialization does not insert legacy static/gain-bank writes between the
vendor stages. Those writes changed fixed RF/PLL defaults and overlapped
restored WLAN calibration. The RX preparation step preserves RF90 while
applying the vendor's two RX-mode masks.

There is no WB03/40 MHz fixed-baseline substitution in the shared table
writer. `bl808WifiRfWb03ReplayCompleteTxPowerCal` remains accepted for build
compatibility but no longer gates replay. Nil storage and invalid selected
indices remain guarded. Power fields use the selected runtime rows, including
low-power compensation. These corrections do not establish full calibration
parity or physical radio readiness.

Radare2 of `librf_bl808.a:rf_pri.c.o` confirms that
`rf_pri_restore_cal_reg` calls `rf_pri_txcal_w2reg` and then
`rf_pri_bz_txcal_w2reg` before its four RXCAL stores. The TXCAL writer reads
the saved parameter-2 halfword at calibration offset `0x6a`, retains its low
11 bits in the first power-table word, and packs parameter 3, 0, and 1 into
the second word. The Nim replay uses those fields and the same call order.
The `rf_pri_txcal_search_core` disassembly also samples the center first,
then the left candidate and conditionally the right candidate at each halved
step, as the focused TXCAL search tests model. This comparison does not prove
that the earlier RF measurement and gain-setup stages produce vendor-equivalent
saved records on WB03 hardware. The current `*_complete` diagnostics check
storage and selected indices, not measured-record parity.

### RF Initialization And Restore

RF configuration preserves caller-owned rate bytes and does not insert fixed
WB03 values into channel-compensation storage. The standalone platform profile
sets its own rate defaults explicitly on the requested configuration object.
Private device flags start at the vendor BL616 default; explicit unknown
device input clears all three flags and is not repaired by RF initialization.
The platform's configured-board selection remains a separate adapter step.

Configuration byte `0xC4` is chip version, not gain compensation. Zero selects
version 1 in both efuse initialization and the public chip-version setter.
Crystal-cap trimming publishes the separate BZ/BT corrections (-7 or -3)
and WLAN correction (-4 or 0). The chip byte does not directly replace WLAN
temperature compensation; the BZ temperature calls can publish their shared
temperature accumulator.
The public RCAL setter compares the full argument words against sentinel 128
before masking physical fields, and publishes the same three corrections.

Efuse initialization applies chip version, selects BZ target power from signed
configuration byte `0x9C`, and captures the BZ production-temperature baseline
from signed byte `0xBD` before returning to 35 C. It reloads configuration
after these calls for DFE trimming, then writes the two WLAN correction fields.
Nil configuration after a call returns locally; the vendor assumes valid
storage. This sequence alone does not establish full BZ interpolation parity.

The private initializer binds calibration storage from `wl_cal` before efuse,
crystal selection, fixed defaults and PLL programming. The caller's cold flag
alone chooses full calibration for nonzero values or saved-register restore
for zero. Saved data is not scanned for nonzero values to choose that branch.

Explicit restore applies every owned ROSCAL, RCCAL, RF70, WLAN/BZ TXCAL and
RXCAL field even when the saved values are all zero or only one record is
populated. It preserves unrelated bits and follows vendor store order. Nil
calibration storage remains a local no-op guard, not a request to recalibrate.

Initialization stops RX DFE before calibration/restore, publishes only power
fields afterward, and then applies the vendor's separate synthesizer, DFE-path
and RX-mode writes. The additional WB03 RF90/RF88/RFA4 latch writes and fixed
RF600 patch are removed, as is the initializer's late RFC-entry baseline call.
The completed calibration or restored values are not replaced by those patches.
Existing diagnostic stage markers remain available.

The channel-programming and scan/TX reviews remove the remaining fixed RF
workaround calls from those paths. These checks establish
the scoped initializer/restore behavior under modeled stage dependencies,
not full RF lifecycle parity or physical radio validation.

### Channel Programming

Radare2 of `rf_pri.c.o:rf_pri_set_channel_pwr_comp+0x0..0x12` shows a
byte store of the requested channel before an 8-bit range check. The Nim
entry deliberately rejects full-width values outside 1..14; it now also
clears the saved current-channel byte on rejection. Previously 257 was
rejected but left channel 1 published, allowing a later temperature update
to apply compensation for a channel that had not been programmed. A focused
native test covers valid channels, out-of-range values with valid low-byte
aliases, and the subsequent temperature path. This is a local fail-closed
guard, not vendor behavior for malformed indices.

The modem channel helper programs the inverse-carrier divider at modem 84C
and the full low-16-bit center/primary ratio at 8EC as separate values. Its
sideband selectors and bandwidth-specific modem/AGC profiles follow the
selected RF object's individual stores and masks. Returning-assert tests
retain raw field values and model RISC-V division behavior for zero divisors;
they do not change the firmware's assertion policy.

PHY channel setup has no extra RFC-entry fixed baseline or modem 888 pulse.
Initial channel programming also does not add a rate-power load after the
RF call; rate initialization occurs earlier in the vendor PHY sequence.
The vendor reads the previous channel type after `rfc_config_channel` and
before caching the new descriptor, then reloads rate power only when those
types differ. Nim now reads at that point too; a focused callback-order test
distinguishes it from an early snapshot. Descriptor caching still precedes
the type-change power update.

The pinned WiFi `sm.o:sm_set_channel_coex_connected` at object offset
`0x218e` passes two SM halfword frequencies and four zero arguments to its
older `phy_set_channel` call. The selected BL808 RF `phy.c.o` instead takes a
10-byte descriptor pointer in `a0` and returns immediately when `a1` is
nonzero (`phy_set_channel+0x0`). Nim's `phySetChannel` bridge constructs that
descriptor and passes a zero force argument. The linked M0 image calls the
bridge, and a focused checked/release/ASan test checks every descriptor field
and force value. This establishes the ABI handoff, not an on-device retune.

The Nim-only STA TX RF reclaim helper now bounds-checks the connection VIF
and requires an active STA mode before using it. A stale connection index
pointing at an AP or inactive VIF falls through to the active-STA lookup. When
SM already supplies primary and center frequencies, it borrows channel type,
band, second center and power from the connection VIF only if that context
names the same frequencies. This avoids
retuning a matching 40 MHz channel as 20 MHz while keeping stale context
metadata out of a different SM channel. The same frequency-match rule applies
when the VIF's frequency pair supplies the channel; an empty context cannot
hide a valid pair or block a later active STA VIF. Focused checked, release
and ASan tests cover these selections. Without matching context metadata, a
primary frequency in the supported 5005..5825 MHz 5 GHz range now supplies
band 1 instead of the previous 2.4 GHz default. The M0 WiFi image builds. This
restore helper is Nim-only, so the vendor PHY disassembly establishes the
channel descriptor contract rather than direct helper parity. The archived UART
authentication failure predates this change; hardware effect is unverified.

The same reclaim path previously called `phy_init(nil)`, which clears the nine
configuration words copied from the MM start request. It now snapshots those
words before RF reinitialization and passes them back to `phy_init`. The focused
reclaim test covers both the live `bl_send_start` shape (word zero is 1 and the
rest are zero) and arbitrary nonzero words, even when its RF-init stub clears
PHY storage. Checked, release, and ASan modes pass, and the M0 WiFi image builds.
This preserves the vendor MM-start config contract across a Nim-only restore,
but its on-device effect is unverified.

Monitor enable is a different initialization path. Radare2 of the pinned
`mm_task.o:mm_monitor_enable_req_handler` shows a 64-byte stack buffer zeroed
before `phy_init`, followed by a fixed 2437 MHz channel, `mm_active`, and a
success confirmation. The Nim monitor handler retains that explicit zero
configuration; preserving the prior MM-start words there would not match the
vendor flow. The adjacent monitor-channel handler retunes without `phy_init`.

RFC channel programming retains the five vendor delays and its consecutive
strobe set/clear stores. It does not add notch-register writes. Channel-power
index arithmetic preserves the vendor's low-halfword range test, signed
division and byte-sized result. These ABI details include wrapped inputs;
they do not establish hardware support for arbitrary frequencies.

The pinned `rf_pri.c.o:rf_pri_set_channel_pwr_comp` stores the low byte of
its argument before checking `(channelIndex - 1) & 0xff` against 13. The Nim
entry instead rejects values outside 1..14 and clears the saved index, so a
direct invalid call cannot leave an index that later selects a compensation
table entry. This is an intentional safety difference: supported channels
produce valid indices, but `rfc_config_channel` can derive 15 for a
nonstandard 2483 MHz input. Radare2 and
T-Head-aware LLVM disassembly of the adjacent WLAN/BZ temperature routines
also confirm the current signed-halfword temperature conversion, interpolation
branches, zero-divisor behavior, and BZ publication order. The focused RF
compensation tests pass; these are static checks, not radio results.

Both temperature routines load `wl_cfg` once before reading the room offset,
calibration enable, and interpolation tables. Nim previously reloaded that
global for each byte or halfword even though the callers had captured it.
They now pass the captured pointer through the shared table loader. A focused
handoff probe changes the global during the first halfword read and confirms
that WLAN and BZ each finish from the original configuration. The retained M0
HAL functions each load `wl_cfg` once, and the shared loader has no global
load. The affected RF tests and build-only path pass; concurrent table
publication and on-device power behavior remain unverified.

Private calibration channel programming preserves RFBC bits outside 23:20.
It repeats the paired strobes until both busy bits clear. The existing timeout
counter records stalled intervals without allowing an unfinished tune to
return as complete.

RF optimization changes RFD0 only for a known device with the 40 MHz flag.
The WB03 PLL branch requires the 26 MHz flag with the 40 MHz flag clear, and
runs before RF70 replay. Its ordinary PLL settings include bits 8 and 0 in
the respective control words. RF70 window selection preserves the vendor's
wrapped 16-bit range comparisons. The subsequent scan/power review removes
the fixed scan/TX patches and WB03 compensation bypass. Physical radio
behavior remains unvalidated.

The adjacent `rf_pri_bz_optimize` and `rf_pri_bz_optimize_restore` bodies
also require the 40 MHz flag, not the 38.4 MHz flag. Radare2 shows both
loading `.LANCHOR10`, which `rf_pri_input_xtalfreq` sets only on its 40 MHz
branch. For a known BL616/WB03/BL618M device, BZ optimize clears RF[0x10d0]
bit 2 at 2460 or 2480 MHz and sets it otherwise; restore sets it. A focused
native matrix covers all device-flag combinations, both crystal flags, and
the adjacent channel values. It does not validate physical BZ reception.

### Scan And Power Compensation

In the pinned `scan.o`, `scan_set_channel_request` submits its stack channel
request before reading `scan_env.chanInfoPtr` and recomputing the DS Parameter
Set channel byte from the selected channel entry. Nim keeps the post-submission
IE update but uses the channel values captured before the callback. The 5 GHz branch
accepts 5005 through 5825 MHz and maps 5005 to index 1; 5000 MHz leaves the
DS byte at zero. Focused callback and boundary tests cover the distinction.
The adjacent `scan_ie_download` uses `scan_env.paramPtr` for the initial IE
search length but its `param` argument for the final end-offset length after
the channel request; Nim preserves the two pointer sources and captures the
argument length before the callback.
DWARF places `scan_probe_req_ie.buf` at byte offset 36. The pinned `scan.o`
relocation for `mac_ie_find` names `scan_probe_req_ie + 24` in hexadecimal,
which is the same byte offset (`0x24` = 36), not descriptor metadata.
`scan_init` also stores that data address at object offset 24. Focused native
tests check the initialized self-pointer and use distinct request lengths to
confirm that IE lookup starts at the data buffer.
`scan_get_chan` has no formal parameter in the pinned archive's DWARF entry.
Its disassembly loads the current index from `scan_env+9` and uses a six-byte
channel stride, so Nim now selects `scan_env.channelIndex` instead of a caller
argument. The focused scan test checks both channel slots.
In `scan_task.o`, the periodic probe handler logs
`scan_probe_req_tx failed!\r\n` through the platform hook only when probe TX
returns nonzero. Nim now retains that return value and failure-only diagnostic;
the handler test covers idle, success, failure, and absent-hook paths.
The channel-start handler likewise logs its distinct
`scan_probe_req_tx f\r\n` message on nonzero TX status before obtaining the
duration and arming the timer. At channel end, the vendor clears timer ID
`0x407` (`SCAN_PROBE_TIMER`), not `0x402` (`SCAN_DONE_IND`); Nim now clears
the probe timer before advancing to the next channel.
At channel start, the pinned `scan_task.o` applies the RX filter, sends an
active probe, arms the half-duration timer, then sets the scan state to running.
Nim keeps that normal ordering but now checks the request pointer, epoch,
channel index, and pending state after filter/trace callouts and after probe
TX, logging, duration lookup, and timer setup. A request retired before timer
setup cannot arm one. The existing guarded timer mutation rolls back a timer
if ownership changes during allocation or publication, and a current
allocation failure retains the public timer API's assertion. A retired
request cannot move its replacement into running state.
Focused native tests exercise those callback boundaries; they do not establish
on-device timing or RF behavior.
The same pinned `scan_task.o` channel-end body frees the active request,
queues `SCAN_DONE_IND`, then sets the scan task idle. Nim's free path has
ownership hooks, so a synchronous replacement between those operations could
route the old completion to the new requester or reset its state. Nim now
checks the captured request epoch after diagnostics, detaches the completed
request, queues its completion to the captured requester while the task is
still running, and transitions to idle before freeing the old message.
It skips that idle transition if a send hook installed another request.
Focused native tests cover replacement at the diagnostic, send, and free
points, an in-place epoch change, and abort-flag retirement. This protects
Nim-side callback ordering; it is not a claim of vendor parity under
reentrancy or proof of on-device scan completion.
The pinned `scan_task.o` early-end handler checks only that the scan state is
non-idle before calling `scan_terminate_channel_request`. Nim now also
requires an owned request, because its completion path can detach a request
while the task still reports running during a synchronous send callback. The
channel-end handler also rechecks ownership and running state immediately
after clearing the probe timer; timer cleanup can call back into the runtime
before the old scan's RX filter is cleared. Focused checked, ASan, and
firmware-like tests cover detachment and replacement at these boundaries;
the M0 WiFi HAL image compiles, but no board was flashed in this pass.
The pinned `scan_task.o` cancel and abort handlers classify activity from
`ke_state_get(TASK_SCAN)`. Nim also has a pre-state-change owned request and
a detached-before-idle completion interval. The handlers now use the owned
request pointer for that decision: an early cancel/abort still marks the
current request, while a late one cannot mark a completed request and carry
its abort flag into the next scan. Admission clears that flag under the scan
lock. Focused tests cover both intervals and the active channel-running path;
these are Nim ownership corrections, not vendor-equivalent late-call behavior.
An absent cancel message now returns without changing the active abort flag or
dereferencing a missing request header; the focused cancel test covers both
idle and owned-request cases.
For an accepted `scan_start_req_handler`, the pinned code performs
`scan_ie_download` before `ke_msg_send` publishes the start confirmation;
the busy path sends only the confirmation. Nim now follows that order so a
requester cannot observe acceptance before channel setup is submitted.
The vendor's scan start, cancel, and abort handlers classify activity solely
by the task state. During `scan_ie_download`, the accepted request is already
owned by `scan_env.paramPtr` while the task remains idle until channel
submission returns. Nim also treats a non-nil owned request as active in those
three handlers, preventing a reentrant start from overwriting it and ensuring
cancel/abort mark it instead of reporting idle. Focused tests force a nested
start during IE download and cover cancel/abort in this interval. This is a
deliberate ownership guard beyond the archive's normal-path state test.
Radare2 of `scan.o:scan_set_channel_request` shows that the vendor calls
`chan_scan_req` before its optional band/frequency check for the DS Parameter
IE. Nim now validates each lower-scan channel at request admission and again
before submission. It accepts 2412-2472 MHz in 5 MHz steps, the channel-14
exception at 2484 MHz, and 5005-5825 MHz in 5 MHz steps; other band/frequency
pairs are rejected.
The second check covers in-place edits after admission. Focused checked,
ASan, and firmware-like tests cover invalid gaps and valid endpoints; the M0
WiFi HAL image compiles. This is stricter than the archive on malformed scan
messages and does not establish regulatory or on-device behavior.
The upper scan producer now checks every supplied channel before allocating a
lower-scan request. The station manager likewise checks its selected or
configured channel list before publishing an upper-scan message. This avoids
late BAD_PARAM confirmations after station-manager state publication and
prevents malformed channel entries from rewriting shared probe IE state.
The host builder already maps channel 14 to 2484 MHz; its station-manager
test fixture previously generated 2477 MHz and has been corrected. Focused
producer tests and all 57 station-manager submission cases pass in native
checked, release, and ASan modes. These are Nim-side admission policies;
the pinned `scanu.o:scanu_scan_next` does not validate channel frequency.
The pinned `scan.o` DWARF also declares `scan_get_scan_duration` and
`scan_probe_req_tx` without formal parameters. Both read current request
state from `scan_env`; Nim now exports the matching no-argument ABI. Focused
duration and probe-lifetime tests cover the resulting call paths.
`scan_set_channel_request` is likewise no-argument. In contrast,
`scan_send_cancel_cfm` takes both `status` and `dest_id`; the idle cancel
handler passes its requesting task ID as the destination. Nim previously sent
that confirmation to `TASK_SCAN` instead. The focused test covers requester
routing and the active-scan abort path.
In the pinned upper-MAC `scanu.o`, `scanu_start` also has no formal parameter
and reads the current request from `scanu_env`; Nim now exports that ABI. The
producer-lifetime tests still cover request replacement during its callbacks.
At `scanu_start+0x3e..0x6c`, the vendor sets the SCANU task state, then reloads
the request pointer before reading its probe IE source and length. Nim keeps
the pre-transition request for its owned operation, but now checks the request
epoch after `ke_state_set` before dereferencing it or copying IEs. A diagnostic
callback during that transition can no longer make the producer read retired
storage. The focused lifetime test exercises pointer replacement
and same-pointer epoch renewal at that state transition; this is a Nim-side
ownership guard, not a claim that the vendor has the same reentrancy behavior.
At `scanu_scan_next+0x112..0x122`, the vendor clamps a supplied probe IE
length above 200 to zero and continues constructing generated scan IEs. Nim
previously rejected the whole scan after computing the same clamp; it now
keeps scanning without the oversized supplied IEs. The IE-builder tests cover
the 200/201 boundary and the maximum 16-bit length.
The `me_mgmtframe.o` local `phy_freq_to_channel` helper admits 5 GHz
frequencies from 5005 through 5825 MHz before dividing `(freq - 5000)` by
five. The Nim firmware helper previously ended at 5820 MHz and therefore
rejected channel 165. More importantly, the linked M0 image resolves the
firmware's weak conversion symbols to strong host-side helpers that previously
rejected every 5 GHz channel. Both helper implementations now use the vendor
bounds; the linked image's disassembly confirms the 5 GHz branches. Boundary
checks cover 5000/5004/5005 and 5820/5824/5825/5826 MHz, and the host-backed
Country IE test applies channel power at 5180 and 5825 MHz. The linked
`me_extract_country_reg` calls the strong converter. A source-level CSA test
also uses that converter at channel 165, but `me_extract_csa` is dead-stripped
from this M0 boot image. The archive inverse also truncates off-grid MHz
values within those bounds; for example, 2483 MHz maps to channel 15. Both
Nim converters deliberately require an exact channel center frequency so
malformed inputs cannot advertise a nearby channel or acquire that channel's
Country IE power. Boundary and off-grid tests cover the distinction. The CSA
parser now rejects unsupported primary and
wide-band center channels when conversion returns `0xFFFF`, leaving its output
untouched. This deliberately differs from the vendor parser on invalid IEs:
it avoids publishing invalid frequencies and a secondary-offset overflow in
checked builds. Focused malformed-CSA tests cover those cases.
The pinned `me_mgmtframe.o` DWARF declares `me_add_ie_ssid(frame_addr,
ssid_len, p_ssid)` and `me_add_ie_ext_supp_rates(frame_addr, p_rateset)`.
The latter loads the count from the rate set's first byte; it has no third
count argument. Nim previously exported both with the wrong ABI. Their
signatures and callers now match the vendor, while preserving the expected
SSID and rate IE bytes. A direct function-pointer ABI test and the affected
frame-building tests cover the corrected calls.
The adjacent `me_utils.o` basic-rate helper clears the destination count
before reading the source count. Nim now preserves that order, including the
in-place alias case, while retaining its existing bound on malformed source
counts. A focused host test covers separate and aliased rate sets.
In `scanu_search_by_ssid`, the pinned `scanu.o` loads the active
`sm_env.connectInfo` word at offset 48 and extracts bits 9 and 10. Bit 9
enables a first pass that accepts only result entries whose retained raw-frame
pointer passes the vendor's `0x00FF00FF` mask. When no entry is selected, bit
10 decides whether to return immediately or retry all six entries without
that filter. At `0xee8..0xf04`, the vendor compares the query with the active
global SSID filter, then ranks valid entries by RSSI without comparing each
entry's SSID. Nim now preserves both the directed-filter match and the
preferred, strict, and fallback passes. Focused host tests cover selection
and the returned index in checked, release-like, and AddressSanitizer builds;
the linked M0 image builds. This does not establish over-the-air behavior.

The pinned `sm.o:sm_get_bss_params` publishes a scan-result index only when
`scanu_search_by_ssid` returns a nonnegative index. Nim also selects entries
through its channel-hinted and directed-SSID fallbacks. Those paths now publish
the selected cache slot, so a later failed connection can pass the real index
to `scanu_rm_exist_ssid` instead of silently skipping cache removal. The
focused BSS selection test covers a nonzero slot for both fallbacks; this is
a correction to the Nim-only selection paths, not a claim about vendor flow.

The host `bl_send_scanu_req` builder validates its 2.4 GHz inputs before
allocating the 320-byte upper-scan request. Previously a 16-bit channel count
was narrowed to eight bits, channel zero became a negative frequency index,
and an SSID length above 32 copied into adjacent request fields. The builder
now bounds counts to the configured 2.4 GHz channel set, rejects out-of-range
explicit channels and SSIDs, and returns `EINVAL` without sending a malformed
request. A native canary test covers boundaries in checked, release-like, and
AddressSanitizer modes. This is a host-side safety correction; the pinned
`scanu_task.o` disassembly establishes the receiver's message layout and
normal request handling, not the host builder's input policy.

The pinned `scanu_task.o` start/join handlers read fields through byte 316
without a payload-length check, and its `scan_start_cfm_handler` reads the
first status byte unconditionally. The Nim handlers now reject a request
shorter than the 320-byte upper-scan layout, or a confirmation shorter than
one byte, before touching the body. Focused native tests cover short and
complete requests plus malformed and valid confirmations in checked,
release-like, and AddressSanitizer modes. These are defensive receiver checks,
not vendor-equivalent behavior for malformed messages.

For unfiltered scans, Nim additionally inspects each advertised SSID IE: a
complete, nonempty SSID takes precedence over a conflicting retained value,
and an oversized SSID is rejected. The cache fills in hidden or unavailable
raw SSIDs. This Nim-side extension prevents a stale cache from selecting a
stronger BSS advertising a different SSID; it is not applied to the vendor's
directed-filter path. Focused tests cover short, hidden, oversized and
mismatching SSIDs, preferred/strict raw passes, and a weaker matching
candidate in checked, release, and ASan modes.

The pinned `scanu.o:scanu_find_result` returns the first free slot for an
allocating lookup before examining later slots. Nim now checks all valid
entries for the BSSID before reserving the earliest free slot; this prevents
duplicate BSSID entries after a cache hole. A nil BSSID also returns without
touching the cache. The cache-generation test covers an existing entry behind
a hole, subsequent allocation, and preserved result identity. This is a
deliberate correctness change from the vendor search order.

For an already known BSSID, Nim's scan-frame refresh now preserves the cached
SSID when a subsequent frame has a zero-length SSID IE. It rejects an SSID IE
longer than the 32-byte protocol maximum instead of truncating and caching it.
The Nim-only pre-connect raw-frame pruner also retains the strongest hidden
frame whose cached SSID matches the requested network; otherwise it could
discard the RSN/SAE data before authentication setup. Focused frame-update
and pruning tests cover these cases. These are Nim-side identity and length
corrections, not claims of vendor parity.

Radare2 of `scanu.o:scanu_frame_handler` resolves two channel lookups at
offsets `+0x2ce` and `+0x67a` to `me_freq_to_chan_ptr`; each stores that
function's pointer directly, including null for an unconfigured frequency.
Nim retains a per-result copy of configured channel data, but no longer
manufactures a 20 dBm channel when the requested frequency or band is absent
from the ME table. A focused native test covers configured, missing, and
band-mismatched lookups. The copy remains a Nim-side lifetime extension, not
an exact reproduction of the vendor pointer identity.
The later Nim-only BSS selection fallback also rechecks the retained frame's
DS channel before resolving a missing channel pointer. It cannot substitute
stale RX frequency metadata when the DS channel is unconfigured. Its ME-table
lookup checks the band, and it avoids the vendor's band-0-only lookup on a
band-1 frame. Focused tests cover these paths and malformed DS data.

Radare2 of `sm.o:sm_get_bss_params+0xd2` shows that a found BSS publishes its
entry's channel pointer directly, even when null. The channel hint at
`+0x11c` is reached only after no result is selected. Nim preserves this
boundary: a focused BSSID-selection test keeps a found result's channel null
despite a separate host hint, so the scan-completion caller cannot join that
BSS using an unrelated channel.

Radare2 of `scanu.o:find_wpa_rsn_ie` shows only the vendor-IE and RSN-IE
lookups; it does not validate cipher suitability for the later Nim SAE choice.
The local supplicant's public cipher enum maps CCMP to 4 and TKIP+CCMP to 5.
Nim now reads the RSN group and pairwise suite selectors and removes SAE from
the eligible AKM mask unless the group suite is CCMP and at least one pairwise
suite is CCMP. The callback-based scan path applies the same rule to its parsed
cipher enums, and the selected-BSS auth path rechecks the retained RSN IE.
PSK remains eligible on a transition BSS with TKIP-only ciphers; an SAE-only
BSS with those ciphers is not selected. Focused host tests cover both paths
and malformed RSN lengths in checked, release-like, and ASan builds. This is a
Nim-side security policy, not a claim that the vendor scan object enforces it.

The SDK `wifi_wpa_ie_t` ABI places `pairwise_cipher` at byte 4 and
`group_cipher` at byte 8; `wpa_parse_wpa_ie_wrapper` fills those fields by
name. The Nim scan view had them reversed, so mixed-cipher results could be
published with swapped group/pairwise values and the SAE cipher gate could
take the wrong branch. The view and its offset assertions now follow the SDK
ABI. A native test writes parser-output bytes at the C offsets and checks
both the selected AKM and published cipher pair; a C static assertion checks
the pinned header itself.
The adjacent `wifi_connect_parm_t` handoff has pairwise cipher at byte 56 and
group cipher at byte 57 in the archive's short-enum ABI. Nim had copied its
group-then-pairwise VIF bytes as one word, reversing the callback payload.
The notification view now names and writes the two bytes separately. The
focused test checks the callback payload with distinct cipher values.
Radare2 of `scanu.o:scanu_frame_handler+0x8de..0x950` also shows a zeroed
128-byte callback buffer with no write to `pmf_required` at byte 123. That
would make the local `wpa_set_bss` overlay disable PMF even after selecting
SAE. Nim now sets the required byte from the negotiated policy and passes
public cipher 6 (BIP-CMAC-128) at byte 124 whenever both sides support PMF.
For optional PMF it leaves `pmf_required` clear while still advertising
capability. This intentionally corrects the vendor callback payload; it does
not imply the archive itself negotiated PMF successfully.

The pinned SDK's RSN parser leaves `mgmt_group_cipher` zero even when an
explicit suite is present. The local firmware can compute only BIP-CMAC-128,
so the Nim RSN walker now checks the raw management-group selector, treating
an omitted selector as the standard BIP-CMAC-128 default. Both the directed
scan and selected-BSS paths reject PMF negotiation when the AP explicitly
advertises another management cipher. Focused host tests cover the default,
explicit CMAC, unsupported suite, and malformed tail; the M0 WiFi HAL image
builds. This is static policy evidence, not on-device association validation.

The pinned `scanu_frame_handler` uses first-match `mac_ie_find` calls for SSID
and DS Parameter Set after result lookup. Nim's pre-admission IE walk now
rejects a second SSID or DS element, including a hidden first SSID followed
by a visible one, before parser callbacks or cache reservation. This avoids
choosing an identity or channel from contradictory singleton IEs. Focused RX
admission tests exercise both duplicate types and mutation controls.

The pinned `scanu.o:find_wpa_rsn_ie` likewise calls first-match WPA vendor-IE
and RSN-IE finders. Nim's scan admission now rejects a second IE of either
security kind before those callbacks can interpret an ambiguous advertisement.
One WPA IE alongside one RSN IE remains valid for transition networks, and
unrelated vendor IEs are unaffected. The focused admission test checks both
rejections and guard-removal mutations in checked, release, and ASan modes.
This is a local fail-closed policy, not behavior recovered from the archive.

At `scanu.o:scanu_scan_next+0x2dc..0x31a`, a directed miss with retries left
decrements `scanu_env.joinRetryCount`, sets `resultState`, clears `scanBand`
at offset 181, and loops into channel construction without clearing the
BSSID-filter flag. Nim previously cleared that flag and returned, so it never
sent the retry `SCAN_START_REQ`. Nim now repeats the band-0 scan in the same
call while keeping directed filtering. Producer-lifetime tests cover the
retry publication and replacement during its diagnostic callback.

Radare2 of `scan.o:scan_set_channel_request+0x6c..0xaa` shows the vendor
reloading channel band and frequency after `chan_scan_req`; the request can
therefore be changed by a synchronous callback before its DS Parameter IE is
filled. At `scan_ie_download+0x3e`, it likewise reloads the caller's IE length
after the channel request. Nim now uses the channel and bounded IE length
captured before that callout, so the DS IE describes the channel actually
requested and the end pointer cannot be extended by a reentrant length edit.
Request-epoch checks still stop replacement scans. Focused native tests cover
both in-place mutations and scan replacement; this is a deliberate Nim-side
correctness change, not a claim of vendor parity under reentrancy.
The Nim channel path also snapshots its request fields before diagnostic trace
callouts and checks the request epoch after each trace. This prevents a trace
callback from submitting a retired scan or mixing fields from an in-place
edit; focused tests exercise both trace points.

At `scan.o:scan_probe_req_tx+0x106..0x12a`, the vendor stores the shared IE
buffer address at hardware descriptor offset 16 and subtracts the IE length
from the inline payload end before pushing the frame. Nim instead copies the
bounded IEs into the frame slot's 512-byte inline payload, keeps descriptor
offset 16 clear, and transmits the full contiguous length. The maximum probe
payload is 258 bytes. The probe-lifetime tests check exact frame bytes, DMA
bounds, and independence from later edits to the shared IE buffer. This is a
deliberate buffer-ownership change, not an on-device TX validation.

Scan RX-filter setup and MAC activation no longer replace calibrated RF or
AGC words with fixed WB03 values. Station authentication/association builders
and payload DMA handling likewise do not replay those fixed values or pulse
the RF latch service. The three former latch build options remain accepted
but have no effect. RF/descriptor observation hooks and existing callback
ownership checks remain; the legacy TX-latch counter is retained but not
incremented by these paths.

Total channel-power compensation applies to every board/crystal combination.
It sign-wraps the temperature-minus-applied-plus-channel sum to 16 bits, then
clips it to [-16, 16]. Chip versions other than 99 add the TX gain offset and
write only the RF704 high byte and RF7AC low byte in vendor order.

Chip version 99 instead resets the default WLAN tables, splits the clipped
compensation into a four-unit coarse step and residual in [-3, 1], adjusts
all 18 rows and all 13 indices, and publishes WLAN power fields only. It does
not round a negative remainder of -3 to the next lower coarse step: the pinned
`rf_pri_set_channel_total_pwr_comp+0xd8..+0x116` branches only when the signed
remainder exceeds 1. The Nim path previously made that extra negative
adjustment, shifting the power table for totals such as -3, -7, and -11.
The focused table test includes those totals in its [-40, 40] sweep, and the
built M0 image retains the corrected positive-only branch. This path does not
replay TXCAL or touch BZ fields. The existing index-validation guard
suppresses publication when shifted indices fall outside the 18-row table;
the vendor routine has unchecked reads for those states. This guarded case
is not claimed as byte-for-byte execution parity. These are modeled host
checks and linked-code inspection, not physical radio validation.

### BZ And Temperature Compensation

RF780 combines clipped channel correction with the BZ correction; RF7B4 uses
the separate BT correction. Channel aggregation uses those clipped samples,
choosing the minimum negative sample or otherwise their mean. The raw signed
configuration copy stays unchanged. Target-window updates use the vendor's
representative record key rather than comparing or normalizing every entry.

The shared temperature sampler models left-follow mode 0 and linear mode 1.
Unsupported interior modes retain the caller's accumulator; endpoints still
calculate. Sensor scaling wraps to a signed halfword before further use.
Interpolation preserves 32-bit intermediates, including wrapping products.
Division follows the non-trapping RV32 zero/overflow results rather than
retaining an old correction. See the [RISC-V ISA manual](https://docs.riscv.org/reference/isa/v20191213/_attachments/riscv-unprivileged.pdf).

BZ clears current slots on entry. Enabled measurement passes write baseline
slots directly; disabled measurement passes preserve the baseline. Samples
carry one shared scalar through all five channels, publishing its last value
to WLAN temperature state only if a calculation occurred. Ordinary passes
write the current-minus-baseline fields before updating the aggregate.
With a zero channel-count word, the vendor skips table copying but still
samples through the existing first offset; a single channel copies only its
first row. The focused 0/1-channel test checks both paths, baseline ownership,
and the two RF register words in checked, ASan, and firmware-like modes.
WLAN clears its sample first, updates the saved sensor only when enabled and
outside a measurement pass, and saves scaled-then-divided temperature rather
than the original input word. Disabled calls still apply total compensation.

### Receive Gain And Carrier Error

The writable nine-byte `rxgain` export now matches the RF archive:
`14,19,26,32,38,45,50,57,63`. `rc2_config_rxgain` compares its raw signed ABI
word with the cached signed byte before narrowing, and preserves the vendor's
nine ordered byte-field writes at modem `C080/C084/C088`. This code runs from
normal PHY initialization at offset zero and LP PHY at offset minus five.
The cached byte's initial value remains `-128`.

Carrier-error capcode adjustment calls the getter before sampling the live
accumulator, reloads configuration before the setter, and passes the adjusted
byte in both setter arguments. It masks interrupts around the setter and the
accumulator/holdoff publication, restoring the previous enable state. Unlike
the aliased outputs in `wl_init`, this getter receives distinct byte outputs.
Nil configuration/callback guards remain local defensive behavior. The loop
normalizes its PPM input to the low halfword before weighting and wrapping.
The detector getter preserves all six DSSS bits `25:20`, not just four.

Fresh disassembly confirms the existing RSSI correction and DSSS/OFDM PPM
formulas. The BBA vector API wrappers have no callers in the current native
RX source and no undefined references from the matching Wi-Fi archive; their
behavior is checked as a separate API surface, not as an established active
RX processing stage. Native tests and a retained target build cover these
paths. Actual receiver behavior and callback stack targets remain unproven.

### BBA State And Publication

The `bba` pointer export selects the current word-aligned, 20-byte state buffer;
it initially points at `bba_env`. A Nim declaration pragma supplies that
linker-time address, matching the vendor data without a runtime initializer
that could later overwrite a rebound pointer. Bare-metal startup copies data
before calling user `main`; Wi-Fi runtime initialization separately calls
`PreMain`. Both behaviors are accounted for rather than assuming `NimMain` runs.
The four-byte `pd_th_att` and `pd_th_rls` exports are writable; their existing
signed defaults match the vendor and are unchanged.

Public MILE/state setters publish the latch before RF register changes. The
detector loop retains the opposite order. State zero samples the previous
state after the OFDM/DSSS gate writes. Reset publishes state/gain/comp/latch
with one word at offset 8, while interval/count use one halfword at offset 16
in init/reset/carrier reset. Padding bytes and unrelated state remain intact.
The interval/count helper expresses the coupled publication explicitly;
target decoding confirms the word and halfword stores. Focused tests cover
state redirection, callback-driven redirection, custom signed thresholds,
publication order/widths, all gain profiles, and interrupt-state preservation.
These checks do not establish whole-image or hardware correctness.

### Low-Power Initialization

`wl_lp_init` takes channel MHz as its second ABI word, binds the WL views,
and calls the low-power default, RF and PHY sequences. It does not rebind
the separate RF calibration pointer, supply another crystal-input call, or
finish with normal `phy_init`. The Nim interface now uses an integer channel
argument; this disassembly establishes its register semantics, not the
original C integer typedef. Configuration is reloaded after initializer calls.

`lp_rf_pri_init` preserves calibration ownership and selects full calibration
only for a nonzero cold argument; its second argument is unused in this RF
object. `lp_phy_init` samples the API-mode gate once after the common phase.
Its receive-gain tail writes modem `0x24C0C018`, not CRM `0x24940018`.
Low power copies only `0x3C0` bytes (240 words) from the 2048-byte `agcmem`
asset. Normal PHY retains its separate `0x800`-byte copy. The LP AGC body has
distinct slope, stage and ramp fields and no longer delegates to normal PHY.

Valid active status samples use signed `(48 * old + 80 * new) >> 7` smoothing.
Inactive updates increment a wrapping 16-bit counter and invalidate only when
the increment equals two. The halfword multiply-add interpretation follows
the [T-Head instruction specification](https://github.com/T-head-Semi/thead-extension-spec/blob/master/xtheadmac/mulah.adoc).
Focused native checks cover all signed status pairs, every inactive-counter
value, raw frequency bits, call ordering, configuration reloads, calibration
ownership, all API-mode bytes, and the LP AGC store trace. A retained-entry
M0 build compiles these paths even though the normal HAL image discards them.
This is static parity evidence, not low-power hardware validation.

### RF Entry And Delay Ownership

Wi-Fi delay hooks no longer read or clear the RF calibration busy bits.
Initialization does not open a latch-service window around modem setup.
Elapsed-time waiting and caller diagnostics remain unchanged; the legacy
latch-enable function only records its diagnostic argument. Busy/READY state
is not manufactured by delay handling.

The standalone HTTP image tested on 2026-11-21 stops during cold RF
initialization, before scan. JTAG resolves the repeated 50-us delay caller to
`rfPriConfigChannelForCal(9)` in the flashed ELF. RF[0xB4] remains
`0x0010C300` (bit 20 set) across target resets; bit 24 clears. The channel
wait counter continues to increase, while M0 mtime advances and no trap is
recorded. Its calibration record contains FCAL `0x97`, ACAL `0x25`, and SDM
divider `0x14555555`. In `librf_bl808.a:rf_pri.c.o`,
`rf_pri_config_channel+0xbe..0x120` performs the same B8/B0 strobes and waits
for mask `0x01100000` to clear. This localizes the failure to RF readiness or
preceding setup, not a frozen delay timer or a proven mismatch in that polling
loop. The older successful WiFi trace was captured before the delay hook
stopped manufacturing RF busy-bit transitions, so it is not a clean control
for the current image.

The separate `m0_wifi_nimfw_boot_test` probe stopped earlier after a full
power cycle. Its JTAG memory log identifies the boot probe; its packaged
firmware body matches the boot-probe binary, not the HTTP image. In that ELF,
PC `0x5802F83A` is in `waitRfFcalReady`: RF[0xAC] was `0x10` (START set,
READY bit 20 clear), the FCAL wait counter was nonzero, and the final stage
was F403. RF[0xB4] was `0x0000C300`; it is not the register this PC polls.
The matching ELF and capture are under `build/hw-validation-rf-lo-flash/`.

Static comparison found a setup error *before* that wait. In `rf_pri_lo_fcal`
(+0x46..+0x72) and `rf_pri_lo_acal` (+0x36..+0x68), the archive sets
RF[0x30] to `(value & 0x0CF090FF) | 0x0CF00000`. The old WiFi port and its
tests shifted the profile into the wrong bits. The corrected LO paths share
the vendor default with `rf_pri_config_mode`; modes 3..6 retain their
distinct profiles. The preceding fixed-default sequence also uses a direct
zero store to RF[0x63C], reads back 0x2000F884 after setting bit 2, and
preserves RF[0x68] with mask `0x0C00C088`. The first cold capture predates these
corrections. A later probe, written and verified through the persistent
2 Mbps UART anchor, passed the initial FCAL wait and reproduced the channel-9
stall: the FCAL wait counter was zero, the channel wait counter was 9, and
the last busy status was `0x0010C300`. The matching build and OpenOCD logs
are under `build/hw-validation-rf-calibration-publication/`.

The pinned BL808 WiFi demo uses
[`libbl606p_phyrf.a`](https://github.com/bouffalolab/bl_iot_sdk/blob/b773b3f4bf6154125304a328c72bf2aa7168a715/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a)
(Git blob `a9935b475d2198000ae7b67d141f00767176a81a`), not the
BL616-derived archive tracked for BLE. Its `rf_pri.o` agrees on RF[0x30], but
uses a different FCAL setup (`rf_pri_lo_fcal+0x8e..0x13a`): set RF[0x1C]
bit 3 early, do not clear RF[0xB8] bit 4, select RF[0xA4][1:0] = 2, and settle
for 50 us. ACAL (`+0xa4..0x18c`) sets RF[0xA4][10:8] = 4 per channel
and searches a five-bit RF[0xA0] field using four comparator steps and a
final sample. TXCAL (`+0x3c..0x1ea`) starts the DFE without the extra RF[0x23C]
writes, waits on the same two channel busy bits, and loads a five-bit ACAL
code. These setup changes were not in the later probe above.

The 40 MHz WiFi-only cold entry also uses the demo's pre-calibration writes
(`rf_pri_init+0x0a..0x36` and `+0x14e..0x29a`), without the diagnostic
prints. The board-level PLL power-up is unchanged; this RF entry sets the
PLL output gates without running the BL616 PLL reset and divider sequence.
The native trace includes the AON registers at `0x2000F820` and
`0x2000F884`, the direct zero store to RF[0x63C], and the three default
profiles at RF[0x128..0x130]. Without the native calibration define, only
this pre-calibration portion changes for a 40 MHz WiFi-only cold boot.

The standalone BL808 TXCAL implementation uses the demo scratch snapshot
(RF[0x84], RF[0x8C], and RF[0x70] instead of RF[0x88], RF[0x90], and
RF[0x74]). After channel 9 it selects the RF[0x6C] mixer by sweeping eight
codes, then measures I/Q in RF[0x70] and RF[0x600]. The native search uses
frequency words `0xF400/0x1E800`, not the inherited `0x9200/0x12400`.
The eight records at calibration `+0x68..+0xA7` pack 6-, 6-, 11-, and
10-bit values. Correction replay uses those slots in order in both RF banks
(`0x708..0x744` and `0x764..0x7A0`), then applies slot 3 to the live
I/Q registers after scratch restore.

`bl808WifiNativeWlanCalibration` selects the native 40 MHz WiFi-only profile
for the HAL-managed calibration bank. Native warm init recalibrates like
the demo. A switch to the coexistence or low-power profile clears the
incompatible bank and runs full legacy calibration before any legacy replay.
Caller-owned calibration buffers still use the legacy contract. The native
retune uses the demo notch tail without restoring legacy power or RF[0x70]
fields; legacy compensation writers cannot overwrite the native gain bank.

For the native bank, FCAL keeps the first measured count at or above the
target (`rf_pri_lo_fcal+0x318..0x352`). Each halfword at `+0x1C+2*slot` stores
FCAL in bits 7:0 and ACAL in bits 12:8. Channel-9 setup and VCO table loading
decode the same layout. LO stages use the same 27-register scratch snapshot
as the native ROSCAL, RCCAL and TXCAL stages. Stage tags `F310` through `F313`
mark completion of FCAL, ACAL, ROSCAL and RCCAL, respectively; `F300` marks
the full calibration return.

The opt-in path also uses the demo's post-VCO RFC handshake, three
rate-power rows, and PHY init order. It loads 512 AGC words and the first
190 LDPC words from the matching radio tables. PHY init leaves an invalid
channel cache; the explicit MM start request performs the first tune.

The Ox64 boot probe built with `bl808WifiNativeWlanCalibration=1` passed
after writing through the reinstalled persistent 2 Mbps UART anchor.
`build/hw-validation-rf-native-wlan/logs/m0_wifi_nimfw_boot_test.jtag-memory.log`
records `wifi_rf_core_init done`, `bl_init done` and `[PASS] wifi nimfw init`.
The linker map in that run resolves both the native RF and PHY init paths to
Nim. This run establishes boot completion, not scan, association, or BLE
coexistence behavior. The standalone boot, scan, station, and HTTP validation
entries select this profile explicitly. Coexistence and the legacy cold-scan
control keep their separate profile. Other builds can opt in with
`-d:bl808WifiNativeWlanCalibration=1`; activation also requires a managed
WiFi-only calibration bank and a configured 40 MHz crystal.

The native Ox64 join capture under `build/hw-validation-wifi-auth-native-synth/`
reached open authentication at 2462 MHz. Its final THD status `0x80010700`
has seven retries and retry-limit bit 16 set, with TX-success bit 23 clear.
`me_utils.o:me_tx_cfm_singleton+0x0c..0x18` adds bit 16 to the failed-attempt
count. An ACK is not a management response; the firmware no longer has a
diagnostic mode that synthesizes one. The reused-slot DMA fixture checks that
the stale status is cleared and the frame and rate policy survive submission.

The native RF init now follows `rf_pri.o:rf_pri_init+0x3a0..0x3b0` by OR-ing
`0x0006` then `0x4001` into RF[0x2c], leaving the bit-5 pulse to
`rfc.o:rfc_init+0x7ee..0x884`. The channel and gain-table programming audits
did not isolate the on-air failure. The AP advertises 1 Mbps as a basic rate,
and the chosen power index `0x50` matches the demo's lookup. Neither software
value proves that the radio transmitted a decodable frame or received an ACK.

The archived BL808 vendor control, replayed through the UART anchor without
changing boot2 or the partition tables, authenticated to the same Frog BSSID
on channel 11. Its trace at
`build/hw-validation-wifi-auth-vendor-control/logs/prebuilt_wifi-vendor-control.primary.uart.log`
shows TX success (`0x80800000`) and 14 passing checks. It uses a forced
station MAC and a forced TX power index, so this is a board/AP control, not
an isolated RF comparison.

The BL808 E907 SDK's `EF_Ctrl_Read_MAC_Address` reads eFuse region 0 at
offsets `0x14` and `0x18`, validates the six-bit zero count, and reverses
the six stored bytes to network order. Nim uses the boot-loaded shadow
registers at those offsets instead of the unused words at `0xB0` and
`0xB4`. The next native run put the validated factory address into the
auth frame at the original power index, but still ended with no ACK.

The calibration control without `bl808WifiNativeWlanCalibration` stopped
at PHY assertion 586 before scanning. In the native profile,
`hal_machw_init` now keeps the timing fields produced by the vendor-style
read/modify/write sequence instead of overwriting five complete timing
registers after initialization. That hardware run also used a 1 us TXCAL wait
between the RF mode write and TX DFE startup: the demo's `udelay(0)`
still spins at this point. That capture showed unchanged MAC
timing readback, a different measured TXCAL correction, and the same
authentication retry exhaustion:
`build/hw-validation-wifi-auth-native-timing/logs/m0_wifi_nimfw_hal_test.jtag-memory.log`.

Native LO FCAL/ACAL, ROSCAL, RCCAL and TXCAL now use the pinned BL808
`phyrf_utils.o:udelay+0x0..0x30` behavior: a volatile 32-through-zero spin
before each MAC TIMLO deadline check, even for argument zero. The TXCAL
channel-9 pulse sequence uses that same timer. Nim bounds the poll and falls
back to its existing platform delay if the MAC timer does not reach the
deadline; caller-owned legacy calibration retains the platform timer. Host
vectors cover zero, positive, wrapped, and stalled deadlines.
The Ox64 run with JTAG detached during Wi-Fi reported zero calibration timer
fallbacks. All eight TXCAL records were nonzero, their correction fields matched
both RF register banks, and the live I/Q fields matched slot 3. Auth and assoc
were ACKed, but all four EAPOL M2 confirmations still reported retry exhaustion.
See `build/hw-validation-wifi-native-mac-cal-timer/logs/` for the UART log and
the post-run OpenOCD readback. This establishes correction publication, not
whether the measured values were optimal or why M2 did not get an ACK.
The retained failed M2 descriptor had a 34-byte QoS/SNAP header, one terminal
121-byte EAPOL buffer, and a 159-byte frame including FCS. Its header and
normal ACK controls matched the vendor trace. Its rate words were
`0x80001207/0x80001007/0x80001207/0x80000400`, with factory power bytes
`0x40/0x40/0x40/0x50`. The retained memory is a post-completion snapshot,
not an over-the-air capture.

At `sm_auth_send` entry on the same Ox64, the vendor and Nim builds
matched on 77 of 81 sampled words, including MAC timing, RX filtering,
coexistence and the sampled RF routing controls. Three differences were
calibration values (`RF[0x70]`, `RF[0xA0]`, `RF[0x600]`). The remaining
difference was in `0x4000E41C`; it varied between native runs, and the
write watchpoints found only the expected bit-6 RMWs. This does not establish
an RF setting to change. Both captures are under
`build/hw-validation-wifi-auth-register-ab/logs/`.

`scan.o:scan_probe_req_tx+0x124..0x12c` submits a frame with station index
`0xFF` through normal `txl_frame_push`. The Nim key guard now accepts the
no-peer sentinel for unprotected internal management and control MPDUs with
a usable header. Reserved key bindings still take precedence, and host
queue descriptors, protected frames and data do not acquire this exception.
The DMA regression checks that a broadcast probe reaches the AC_VO trigger
with no ACK requested. On the Ox64 this changed the internal-TX counters
from 6 confirms and 22 releases to 27 confirms and 1 release before the
same auth retry exhaustion:
`build/hw-validation-wifi-auth-stationless-probe/logs/m0_wifi_nimfw_hal_test.jtag-memory.log`.
These confirms do not show that the peer decoded any of the broadcast probes.

Cold RF calibration runs before the Nim WiFi module initializer. The native
gain rows and selectors previously used module-time copies into zeroed storage,
so `rf_pri_gain_table_WR2REG`'s Nim counterpart read zeros on this path. The
writable defaults now use literal static initializers; the RV32 ELF places
both arrays in `.data`, and a host constructor test reads them before
`NimMain`. Ox64 readback changed the zero gain headers at RF[0x700/0x704]
to `0x004524D4/0x0028E3D0`. With `bl808WifiProbeReplyDiag`, RX admission
recorded five valid probe responses from `Frog` on channel 11 addressed to
the Ox64. Authentication and association were ACKed, and the AP sent WPA
message 1. Connection still failed in the subsequent EAPOL exchange:
`build/hw-validation-wifi-native-pa-gain/logs/m0_wifi_nimfw_hal_test.jtag-memory.log`.

The later rate-control build and the archived gain-fix build were both retested
with no JTAG polling during the exchange. Both retained the gain headers above
and saw no directed probe replies. The rate-control build exhausted auth
retries; the archived build ACKed auth after five retries, then exhausted
association retries. Neither run reached EAPOL. See the `uninterrupted-repeat`
and `gain-baseline-ab` logs under `build/hw-validation-wifi-native-rc-cold-seed/`.
The earlier vendor connect control applied its explicit high-power profile
(descriptor power byte `0x70`), while the native BL808 MCS7 default is `0x40`.
That control is useful for frame comparisons, but does not isolate the effect
of the native rate-control changes or the default TX power.

The demo's `rfc_config_channel+0x5e/+0x72` includes 1 us waits after both
edges of the RF[0x268] strobe. Native RFC startup, RC FSM force and release,
and channel tune now run the pinned `rfc_helper.o:wait_us` countdown rather
than the platform timer: clamp to 24 bits, multiply by 16, and decrement
through zero. The two inline force/release waits use the same seed of 320.
Legacy calibration and retune keep their previous clock behavior. With these
RFC changes and the cold-rate endpoint fix, the default-policy Ox64 run
received five directed probe replies from `Frog` and ACKs for auth and assoc.
All four M2s still exhausted retries. The retained M2 rate and power words
were unchanged from the earlier MAC-timer run; the calibration fallback
counter was zero. See `build/hw-validation-wifi-native-rfc-countdown/logs/`.

On that RFC baseline, the opt-in `bl808WifiDiagEapolLongGi` repeat reached
EAPOL after a reboot with runtime JTAG detached. The retained M2 DMA policy
changed the two short-GI HT words from `0x80001207` to `0x80001007`; the
other rates and power bytes were unchanged. Auth and assoc were ACKed, but
all four M2 submissions still reported no ACK. The diagnostic remains off by
default. See `build/hw-validation-wifi-native-rfc-long-gi/reboot-1/logs/`.

In the pinned `txl_cntrl.o`, `txl_payload_handle_backup` updates the live
tail's next pointer with one aligned RV32 word store before resuming DMA.
The pinned RX header and payload append routines publish their links the
same way. The previous packed Nim assignments compiled to byte stores,
allowing DMA to see a partially updated address. The three append paths now
write the aligned link words directly; the linked Ox64 image confirms one
`sw` per link before the DMA trigger. TX from an empty chain also now arms
the deadline and aggregation state before optional status readbacks, as
the pinned startup order requires. The live-tail race does not explain a
frame submitted on an empty chain.

The word-link image was built against the same BL808 references and flashed
over the UART anchor with default rates. Its first boot exhausted auth
retries. On a reboot-only repeat with JTAG detached until completion, auth
and assoc were both ACKed on the first attempt, but all four M2 submissions
again reported no ACK. See `build/hw-validation-wifi-native-dma-word-link/`.
The older passing Nim run under
`build/hw-validation-pure-nim-audit-wifi-driver-default-txsettle-wifi-hw/`
logged `high_power_profile`; it is not a passing control for the current
BL808-native RF path.

The Nim supplicant adapter previously supplied a fixed-seed xorshift stream
to `os_get_random`; the first cold-boot SNonce matched that stream. The
pinned E907 SDK's `os_bl.c:os_get_random` calls `bl_rand_stream`, whose active
implementation uses libc `rand()`, so reproducing it would not correct the
entropy defect. The Nim adapter now uses `sec.trngReadAll` for each block,
restores the incoming IRQ state after each read, and clears the caller's
output on TRNG failure. The linked E907 WPA M1 handler requests 32 bytes and
branches to failure before PTK derivation on a nonzero result. This corrects
the fixed stream, but does not qualify TRNG health checks or contention
across security-engine callers on different harts.

The Ox64 build under `build/hw-validation-wifi-native-trng/` did not reach
WPA on its initial boot or first repeat. The second UART-anchor reboot, with
JTAG detached during Wi-Fi, ACKed auth and assoc and produced a nonzero
SNonce different from the old fixed sequence. All four M2 submissions still
reported no ACK. The validation console and standard Wi-Fi JTAG snapshots no
longer dump key or transcript bytes. Keep earlier logs and raw RAM captures
from the locally instrumented SDK private.

Saved native and vendor auth-entry captures match across the nine MAC
timing words at `0x24B000E4..0x24B00104`. The pinned TRPC lookup also returns
`0x40` for default MCS7. Neither check proves which gain the RF hardware
selected for a given frame or whether RX was ready when the peer replied.
The pinned `cli.o:cmd_dump_txgain_register` reads RF `+0x7A4` for selected
table index, requested power and digital gain, and RF `+0x4C` for analog gain.
A completion-correlated readback and a working passive capture would help
separate failed transmission from missed ACK reception without a power
override.

The opt-in `bl808WifiDiagEapolRfGain` trace samples those RF words, plus the
CLI's DFE and gain-control words at `+0x63C` and `+0x2C`, when a host EAPOL
descriptor reaches lower TX completion. It records the first eight samples
with their raw THD status, and neither writes RF registers nor changes
descriptor policy. On Ox64, auth and assoc were ACKed, but four WPA M2
submissions reported no ACK. All eight lower samples had status `0x80010700`
and `+0x7A4 = 0x00044000`: gain table row 4, requested power 64 quarter-dB
units, digital gain 0. `+0x4C` alternated between `0x00C73237` and
`0x00C75137`; the TBB/TMX fields were 12/7, matching the row's values. These
are samples near completion from a shared RF register, not a record of every
RF attempt or a measurement of transmitted power. An earlier channel-11
capture contained no frames. See
`build/hw-validation-wifi-native-eapol-rf-gain/logs/`.

The pinned MAC copies `0x2200` as the data ACK-control word and uses `0x0200`
for internal auth/assoc; both request a normal ACK. The Nim descriptor and
control-port protection follow those paths. `txl_transmit_trigger` in both
builds forwards the completion word from the same hardware offset, so the
observed no-ACK status is not a Nim interpretation of a success bit.

Pinned `me_utils.o:me_tx_cfm_singleton` interprets `0x80010700` as seven
retries followed by terminal failure. `rc.o:rc_update_counters+0xa6` assigns
four failures to each rate slot. The observed stock chain started with two
MCS7 slots (short and long GI) at `0x40`; at eight attempts, rate accounting
does not reach its fourth-slot 1 Mbps fallback at `0x50`. This explains why
an intact fallback entry can coexist with the `0x40` completion readback.
On the Ox64, forcing copies of the existing 1 Mbps pair into the reachable
slots gave first-attempt ACKs for M2 and M4, installed the PTK and passed all
14 HAL checks. The retained policy and RF samples both showed `0x50`. See
`build/hw-validation-wifi-native-eapol-cck/logs/` and `post-run/logs/`.

With forced CCK off, the production fallback build retained `[HT MCS7 SGI,
1 Mbps CCK, HT MCS7 LGI, 1 Mbps CCK]` and power words `[0x40, 0x50, 0x40,
0x50]`. The two EAPOL completions were `0x80800500` (success after five
retries) and both sampled the second slot's `0x50` RF request. The PTK was
installed and all 14 HAL checks passed. This distinguishes the reachable
fallback from both the stock retry exhaustion and the diagnostic that used
CCK from the first attempt. See
`build/hw-validation-wifi-native-eapol-reachable/logs/` and `post-run/logs/`.

The real-lwIP HTTP manifest was also flashed with the production fallback
and no RF or rate diagnostic. Unlike the HAL example it calls connect
without first running an explicit scan. It received scan items but the
synchronous call returned with status/reason still unset; post-run JTAG
found `sm_state = 1` (`SmScanningState`) and no auth, assoc, or EAPOL
confirmations. DHCP and the TCP/UDP host checks did not run. This is an
earlier cold auto-scan failure, not a regression observed on the M2 fallback.
See `build/hw-validation-wifi-native-eapol-reachable-http/logs/`.

The cold-scan snapshot showed both lower SCAN and SCANU idle, with the
lower cursor at 11 and both request pointers nil. `bl808WifiDiagColdScan`
then recorded `0801 / 01040801 / 00000003 / 0 / 0 / 0`: the SM published
an owned request, SCANU found its reserved `SCANU_START_CFM`, and the owner
check rejected it before SM dispatch. No BSS selection ran at completion.
In the pinned archive `chan.o:+0x124a/+0x12ba` publishes channel END and
forces idle, and `mm.o:+0x140e` calls `txl_reset`. The vendor then delivers
the scan completion. Nim's normal channel TX reset advances an epoch and
used to make the still-live station scan owner stale. The channel-reset
wrapper now revalidates and carries the scan owner and its reply through
that expected drain, including cold return with no home context. The same
wrapper keeps an already armed channel gate current on that path. A failed
or recovery reset, a replaced connection, and a changed VIF still do not
preserve the reply. See `build/hw-validation-wifi-native-cold-scan-diag/`.

The stock real-lwIP manifest was rerun with the ownership fix and the trace
flag off. On a cold boot, with no explicit prescan, it reached auto-scan,
auth, association, and WPA completion. The retained counters show two
ACKed EAPOL frames and PTK installation. It then timed out in DHCP:
31 Discover transmissions, 31 retry-limit/no-ACK completions, and zero DHCP
receives in lwIP. The data rate words remained `80001207/80001007/80001207/80000400`
with powers `40/40/40/50`, so the data path still leaves the 1 Mbps pair
in the fourth slot. TCP and UDP host actions did not run. See
`build/hw-validation-wifi-native-scan-owner-keep/`, including `post-run/logs/`
for the DHCP counters.

The rate-control snapshot recorded all 31 completions as eight attempts,
eight failures. The pinned `rc.o:rc_update_counters` accounts for four
attempts per rate slot; the fourth slot cannot be reached with that
budget. The pinned `me_utils.o:me_update_buffer_control+0xe0..+0x116`
also replaces the HT MCS with the VIF limit unless the RC flag at +175 has
bit 6 set. The native STA policy now puts the negotiated 1 Mbps sample in
the second slot if both leading HT samples are below the throughput
eligibility threshold. The hardware and rate-control counters then use
the same slot; the build does not force rates or power per data packet.
The next stock HTTP run joined Frog on channel 6, obtained a DHCP lease,
and started both listeners. Post-run counters recorded five HTTP requests,
including three WASM requests, and one UDP echo. See
`build/hw-validation-wifi-native-data-reachable/logs/` and
`data-post-run/logs/` in that run.

That run lost its station at the 30-second traffic probe: 303 received
beacons, eleven Null frame attempts, no hardware queue entries or
confirmations, and one connection-loss indication. The pinned
`txl_frame.o:txl_frame_send_null_frame` and
`txl_frame_send_qosnull_frame` submit clear header-only frames of 24 and
26 bytes to the internal VO path, with no pairwise-key reservation.
Nim's reservation guard had rejected them once the station installed a
pairwise key. Internal TX now admits those exact unprotected subtypes
only with no payload and matching DMA bounds. Keyed data still needs a
current reservation, and a stale reservation cannot use the exception.
The host DMA fixture tests both Null variants with a key installed.

With the Null TX fix flashed, the station was still associated after
931 received beacons. Three Null frames reached the queue and completion
event, the successful probe updated the keepalive timestamp, and no
connection-loss indication was recorded. On that same boot, a standalone
run of the manifest host probe passed HTTP, WASM install/invoke/delete,
UDP echo, and the HTTP diagnostics checks. The manifest's initial host
action and earlier retries intermittently got empty HTTP responses; a
wired capture showed the board acknowledge the HTTP request in TCP
without returning data. This verifies the keepalive fix, not reliable
HTTP on every attempt. See
`build/hw-validation-wifi-native-null-admission/logs/` and the
`data-post-run/logs/sustained-traffic.m0.openocd.log` snapshot in that run.

The wired trace also showed a gap in the board's IPv4 identification
sequence between SYN-ACK and the cumulative TCP ACK. The received ACK
was sent with the sequence number advanced by the missing response
and its FIN, but no retransmission arrived. The SDK's `tcp_slowtmr`
checks `tcp_ticks - pcb->rtime` for retransmits and also uses the tick
for TIME_WAIT expiry. Radare2 showed the linked local
`tcpip_tmr_compensate_tick` was only a return; a no-reset JTAG snapshot
confirmed zero ticks and a retained TIME_WAIT PCB.

The Wi-Fi lwIP port now advances SDK TCP slow ticks from the
cooperative millisecond clock on input/output and before periodic TCP
service. It carries partial intervals forward and handles unsigned
millisecond wrap. The host fixture links the real SDK TCP core and
the production timeout port. It loses the first HTTP response and FIN,
checks that the duplicate request is only ACKed, and verifies
retransmission of the original response and FIN without a second
application callback. Separate cases cover TIME_WAIT expiry, an idle
periodic advance, sub-tick carry, and wrap.

The corrected image was written and verified through the UART anchor.
With board-to-host UART output silent, the harness used JTAG replies.
The first attempt stopped in `uart_recv_byte` during a 4 KiB write with
the RX FIFO overflow flag set. The JTAG reply path now waits one 8N1
frame time after a payload write before halting M0. It also keeps the
original request sequence across a transient debug read error during
reboot, instead of resending the command and losing its acknowledgment.
The stock host probe passed on the new boot; a JTAG snapshot measured
101 TCP slow ticks and empty active and TIME_WAIT queues after five
HTTP requests. The reboot-only harness command then passed with JTAG
replies. The stock `m0_wifi_http_server` manifest passed with
`--no-flash --no-jtag-reset --jtag-memory-log` on that reboot, including
scan, WPA, DHCP, HTTP, WASM, and UDP. Board-to-host UART output was still
silent. See `build/hw-validation-wifi-native-tcp-clock/` for the flash,
host probe, and TCP clock logs.

A wired steady-state sample on that image received 15 of 16 HTTP
responses and 12 of 16 one-shot UDP echoes. The board's receive and send
counters each increased by all 16 UDP requests. Its first two retry
slots held HT and 9 Mbps OFDM, with success estimates `0x3fc4` and
`0x4709`; the measured 1 Mbps entry was `0xbf8f` but was in slot four.
The pinned `rc.o:rc_update_retry_chain+0x54` branches on the primary
rate's CCK classification, and `+0x130..+0x14e` removes CCK candidates
from the middle slots when the primary is non-CCK. The native station
fallback now covers this measured steady-state case, not just startup.
See `build/hw-validation-wifi-native-tcp-clock/logs/steady-state.pcap`
and `data-post-run/logs/steady-after-burst.m0.openocd.log`.

The stock build with the expanded fallback joined Frog and leased an
address, but the first manifest HTTP request still returned no body.
The harness halted M0 for its failure snapshot. After resume the same
traffic sample got 15 of 16 HTTP responses and 13 of 16 one-shot UDP
echoes. The application queued all 16 replies, and 1 Mbps was the
primary rate in the final snapshot. That sample does not establish
an improvement in packet delivery. See
`build/hw-validation-wifi-native-warm-cck/logs/steady-state-resumed.pcap`.

`-d:bl808WifiDiagHostTxStatus=1` enables a 24-entry host confirmation
ring to match individual replies with MAC completion words. It stores
IPv4 IDs and lengths, transport ports, TCP flags and sequence numbers,
the host re-push index and the raw confirmation word. UDP uses the TCP
sequence word for MAC TIMLO at host confirmation, not the on-air TX time.
The record size is unchanged. It retains no packet data and is not
enabled in the production manifest.

The trace-enabled image passed the full manifest over the UART anchor
with JTAG acknowledgments and startup logs. In 20 subsequent one-shot
UDP probes, 15 echoed. All 20 requests reached the application and
queued replies. Every delivered echo had a TX-success confirmation.
Among the five missed echoes, two each had three confirmations
`0x80010701` (retry limit, no ACK), and two had `0x40000001` (abort or
flush before a successful TX). There was no retained completion for
the fifth. This separates retries on air from software
TX aborts; it does not yet identify the source of the aborts. See
`build/hw-validation-wifi-native-tx-status/logs/udp-correlation.matched.jsonl`.
An eight-probe follow-up reproduced one `0x40000001` abort. The TX
reset epoch advanced from 28 to 30 between snapshots without a
connection-loss indication. This narrows the next capture to the
reset and flush paths but does not tie a specific reset to that frame.

An M0 breakpoint caught `assert_rec` at line 698 of the pinned
`hal_machw.o:hal_machw_gen_handler`: AC0 TX DMA-dead (IRQ bit 13).
The single pending descriptor had retry count five and an unfinished
status. Its first fallback word was `0x80001217` (HT20 MCS 23, three
streams), despite a one-chain modem. The rate-control table contained
that entry and recorded zero-based maximum NSS 2, against local and peer
HT MCS prefixes `ff 00 00 00` and `ff ff ff 00`.

The vendor `rc.o:rc_init+0xba` relocation loads `me_env+0x0b`
for the local HT MCS decoder. The old Nim image loaded `me_env+0x2c`
because `me_env` is word-backed. This read channel configuration bytes,
not the HT mask. The typed view now passes the same byte address as the
vendor. The host fixture uses word-backed storage and checks both the
sample table and initial retry policy with mismatched local and peer
stream counts. No DMA recovery interrupt is masked.
See `build/hw-validation-wifi-native-tx-status/data-post-run/logs/`
for `ac0-dma-dead.m0.openocd.log` and `ac0-rate-caps.m0.openocd.log`.

With just the NSS correction, two boots ended in AP deauthentication
reason 2. The retry snapshot showed ACKed auth/assoc, association status 0,
four unacknowledged EAPOL M2s (`0x80010701`), and no PTK install. The
retained M2 chain was HT MCS 7, 48 Mb/s OFDM, 36 Mb/s OFDM, then 1 Mb/s
CCK. The existing EAPOL fallback rule covered equivalent HT rates in
the first two slots but not HT followed by OFDM. It now also copies the
negotiated CCK rate and its own power into slot two for that case. This
changes only the per-frame EAPOL copy; other traffic and the station
template retain their rates. See
`build/hw-validation-wifi-native-nss-offset-retry/logs/` for
`join-eapol.json` and `eapol-policy.json`.

The next Ox64 run negotiated on channel 11 (2462 MHz) with max NSS index 0.
Both EAPOL transmissions were ACKed and the PTK installed. All 31 DHCP
Discovers then exhausted retries with that same HT/OFDM leading pair.
Rate control recorded failures on both entries; the later 1 Mb/s entry
had no observations. The native cold-rate rule now moves the negotiated
1 Mb/s entry to tracked slot two when both leading rates are non-CCK and
both lack a usable success estimate. This keeps the programmed attempts
and rate counters on the same entries. It leaves an existing reachable
CCK rate, a usable leading rate, and fixed-rate mode alone. See
`build/hw-validation-wifi-native-nss-eapol-ofdm/logs/dhcp-and-eapol.json`.

With the tracked fallback, the trace-enabled Ox64 image passed the full
`m0_wifi_http_server` manifest after UART-anchor flash and reboot. The
channel-11 station reported one-stream HT rates throughout the follow-up;
both EAPOL frames were ACKed and the PTK was installed. The board queued
echoes for all 60 UDP probes and the host received 52. The TX reset epoch
stayed at 23 and there were no connection-loss indications. Seven misses
had only retry-limit/no-ACK completions; the eighth had no retained
completion. No flush status was retained in this sample. The filtered
Mac monitor capture contained zero packets, so the channel and completion
evidence comes from the board, not an over-the-air capture.
See `build/hw-validation-wifi-native-nss-cold-ofdm/logs/nss-burst.json`.

The pinned SDK host `bl_tx_check_ret` requires bit 23 for all STA
uplink frames, including Ethernet broadcast and multicast. The AP is
the unicast 802.11 receiver. Pinned `txu_cntrl.o:txu_cntrl_cfm+0x8`
sets bit 0 when publishing a confirmation but does not change the
underlying RF result. The Nim host now uses the STA rule, so a failed
DHCP Discover can take the existing bounded host resubmission path
instead of being reported as successful. Hardware-done AP group frames
still complete without an ACK.

The SDK names bit 30 `DESC_DONE_SW_TX_BIT`. Pinned
`txu_cntrl.o:txu_cntrl_push+0x1ac..+0x1b2` combines it with descriptor-done and
a software drop or defer reason before queuing the confirmation.
Nim now rejects software-only statuses as host TX success and keeps
them out of both RF rate counters and the rate trial countdown. Host
channel and power-save deferrals still take their existing retry paths.
The regression drives the real host callback and rate confirmation
wrapper with these status words.

On the next UART-anchor boot the complete HTTP/WASM/UDP manifest passed.
The first broadcast DHCP Discover exhausted retries (`0x80010701`).
Its host status was failure, and the first resubmission was ACKed
(`0x80800601`). This is reflected in the status and repush bytes in
`build/hw-validation-wifi-native-tx-completion/logs/dhcp-and-eapol.json`.
The follow-up burst received 38 of 60 replies: 43 requests reached the
application and queued replies, and five of those exhausted reply retries.
The other 17 requests did not reach the application. The reset epoch
did not change. A later 15-probe sample reached the application 15 times
and echoed 13 times, so the ingress loss was intermittent.

Twelve IPv4 descriptor completions from the same boot had intact inline
DMA policies and matched the current RC table for all slots reached,
including an HT/48 Mb/s retry exhaustion. See
`build/hw-validation-wifi-native-tx-completion/logs/rate-attribution.json`.
This does not cover a rotated or replaced in-flight trial. In an earlier
loss burst, the negotiated 11 Mb/s CCK sample had a 52% success estimate
while the leading HT/OFDM rates were below 50% and 1 Mb/s was unmeasured.
The native rule now searches the negotiated CCK samples for a measured
fallback under that same threshold, rather than considering only
1 Mb/s. It moves the chosen sample's tracked index into slot two.

The measured-fallback image passed the full manifest after UART-anchor
flash and reboot. On channel 11, the next 60 probes all reached the UDP
callback and queued replies; 49 echoed. The 11 misses all showed
retry-limit/no-ACK confirmations. The TX reset epoch stayed at 25,
with no connection-loss indication, RX upload failure, or host pbuf
allocation failure. The sampled hardware policies used 1 Mb/s and HT
MCS 7 in the first two slots. They did not capture a promotion of the
measured 11 Mb/s sample, so this run verifies end-to-end function, not
the effectiveness of the new selection rule. See
`build/hw-validation-wifi-native-tx-measured-cck/logs/nss-burst.json`.

The pinned singleton confirmation extracts attempts from the THD, but
`rc.o:rc_update_counters+0xa6..+0xac` charges four failed attempts per
slot against the station's live rate table. That table can be sorted or
changed after the frame is queued. Pinned
`txl_cntrl.o:txl_payload_handle_backup+0xee..+0x102` installs the copied
inline policy in the hardware descriptor, so the native M0 confirmation
path now snapshots its rate words before releasing the completion owner.
It resolves reached slots by rate identity, skips rates no longer in the
table, and also accounts for EAPOL under the policy it actually used.

Pinned `rc.o:rc_init+0x448..+0x464` can seed two legacy 2 Mb/s samples
with identical `0x0001` rate words. `rc_update_retry_chain+0x11e..+0x122`
can select the second entry, and `rc_update_counters+0x98..+0xa2` uses
the selected index. Native singleton feedback now records the sample
index for each rotated hardware slot at submission. Replacing samples or
sorting a table with duplicates invalidates those indices. An untagged
word, or one moved by a sort without duplicates, is only credited if it
identifies exactly one current sample.

This covers the observed normal-ACK, eight-attempt singleton profile.
Only unambiguous hardware ACK and MAC retry-limit reports supply samples;
software, lifetime, and RTS retry statuses are excluded. The exported
vendor counter ABI remains unchanged. A private generation tag on each
host wrapper records the trial's physical slot after rate rotation.
Only a current, matching completion that reached that slot advances the
trial. Rate configuration changes invalidate the tag. Finally, native
completion commits the host status, packet accounting, and queue
publication under one IRQ guard; optional diagnostics run outside it.

The UART-anchor image with this change passed the full HTTP/WASM/UDP
manifest. The channel-11 follow-up received all 60 requests, queued all
60 replies and echoed 50. The ten misses had only retry-limit/no-ACK
completions. There was no TX reset, connection loss, or RX upload failure.
A separate M0 breakpoint captured six live counter calls with non-null
submitted-rate words and one or two attempts. None completed a trial;
the rotated-slot, early-ACK and stale-generation cases are covered by
the host regression. These samples confirm the native attribution path
is active, not that it improves packet delivery. See
`build/hw-validation-wifi-native-tx-rates/logs/` for `nss-burst.json`
and `actual-rate-feedback.json`.

A later channel-11 breakpoint sample recorded 24 IPv4 completions with
normal ACK policy. Six exhausted the retry limit: three of 13 with
11 Mb/s CCK then 6 Mb/s OFDM, and three of 11 with 6 Mb/s OFDM then HT
MCS 7. Both failures and successes occurred with the same policy power
words. The shared RF `+0x7a4` latch sometimes showed an index not in
the submitted policy even after a first-attempt ACK, so that readback
is not per-attempt transmit-power evidence. See `logs/udp-rf-feedback.json`
in the same run directory.

The pinned BL808 demo `phy.o:phy_set_channel+0x0c/+0x108..+0x11c`
keys a retune on band, channel type, primary frequency, and center
frequency. The native port uses those four fields and updates local
metadata separately. Pinned `rf_pri.o:rf_pri_txcal` keeps
`0xFF0FFFFF` at RF `+0xbc` and `0xC0000000` at RF `+0xc4`;
the later `0xEFFFFFFF` clears the RF `+0xb0` strobe, not the divider.
The channel-9 fixture checks the full write and delay order with nonzero
initial values.

After the earlier data capture, the board became unreachable while the
CPU and MAC timer were still running. JTAG showed an inactive STA, one AP
deauth/disassoc handler call and disconnect indication, no local
connection-loss indication, and stored 802.11 reason 7. All six prior
beacon-driven null probes entered lower TX and arrived at the frame
confirmation event. The public keepalive ACK counters do not cover their
`mm_ap_traffic_probe_cfm` callback, so the snapshot does not establish
the individual ACK results or why the AP no longer considered the STA
associated. See `data-post-run/logs/steady-unreachable-*.m0.openocd.log`.
The unchanged image rejoined after a UART-anchor reboot, with no SPI
flash write. The next 36 UDP probes returned 33 echoes without a hit on
the shared PHY reset routine used by channel retunes and CCA recovery.
See `logs/steady-phy-reset-after-anchor.json`. This excludes that reset
path for the sampled misses only.

Two idle captures on the same image reached the actual
`mm_ap_traffic_probe_cfm` callback 16 times: 10 had hardware ACK bit 23
set and six exhausted retries (`0x80010700`). An ACK refreshed the probe
timestamp and restored the budget to 10. Several probes completed close
together while the debugger was stopping M0, so the sample does not
measure uninstrumented throughput or justify changing the probe cadence.
The station remained associated through the end of the captures at
2462 MHz and about -73 dBm. See `logs/idle-null-ack-breakpoints.json`
and `logs/idle-null-ack-extended.json` in the same run directory.

Pinned `sm.o:sm_disconnect_process+0x4a` requests resource cleanup and
`+0x72` sends `SM_DISCONNECT_IND` without waiting for the cleanup replies.
Nim now publishes that indication once the first cleanup request is queued,
instead of waiting for station and key deletion. It transfers the message
out of cleanup ownership before calling the host; a callback may replace
the VIF, and the remaining requests still require the original session.
SM stays busy until cleanup finishes, and a failed connection attempt
still gets its final indication after cleanup. The host regression holds
the station-delete reply and checks that the original status and reason
are already visible, with no duplicate when the reply is released.

The native HAL image was flashed through the UART anchor. At the
`mm_sta_del_req_handler` entry breakpoint, SM was still disconnecting
(state 10) and the host RX handler had already seen one indication with
status 19 and reason 3 (local disconnect). This first run lost startup
markers because the console ring wrapped before breakpoint capture ended.
A no-flash UART-anchor reboot with immediate JTAG console capture
recorded all 14 required HAL markers. See
`build/hw-validation-wifi-native-link-loss/` for the breakpoint log and
`reboot-capture/logs/` for the successful marker capture. This verifies
notification ordering, not the cause of the earlier reason-7 disconnect.

The RX-duration read-order image passed the full HTTP/WASM/UDP manifest
after UART-anchor flash and reboot. An interleaved channel-11 sample sent
16 UDP requests each with 32, 384, and 1200 bytes. The board received
and queued replies for all 48; the host got 14, 13, and 13 echoes,
respectively. All eight misses retained only retry-limit/no-ACK
confirmations. Seven misses were in two consecutive runs spanning
different sizes. Beacon and TBTT counters advanced, with no TX reset,
link loss, RX upload failure, or host pbuf allocation failure. This
sample shows no clear size dependency and does not establish a cause
or a packet-delivery improvement. See
`build/hw-validation-wifi-native-rx-duration/logs/udp-size-correlation.json`.

The timestamped confirmation build passed the HTTP/WASM/UDP manifest.
Of 48 requests, all reached the application, 41 echoed, and all seven
misses had retry-limit/no-ACK completions at re-push indices 0 through 3.
The intervals from first to fourth host confirmation ranged from 7.765
to 171.352 ms. In this run five of the misses were 1200-byte payloads;
the earlier interleaved run did not show a similar size skew. The
SDK and Nim both permit three re-pushes, process pending frames first,
and do not add a host retry timer for the retry-limit status. See
`build/hw-validation-wifi-native-tx-timing/logs/udp-confirm-timing.json`.

In `me_utils.o:me_update_buffer_control+0x112`, a negotiated HT MCS can
replace the one in an RC sample before DMA policy publication. The
native attribution path correctly refuses to credit an unsent rate, but
previously left the substituted trial armed. The station policy commit
now compares the armed sample to its physical retry slot and requests
restoration on a mismatch, without crediting the trial. Per-frame
overrides still do not cancel the station trial. The same commit clears
consumed policy flags before restoring IRQs; the vendor's enable at
`+0x1d6` precedes the clear at `+0x1da`, allowing a refresh raised there
to be erased. Tests cover all rotations, unsent-sample accounting, and
a fresh flag set during IRQ restore.

The corrected image passed the HTTP/WASM/UDP manifest after UART-anchor
flash and reboot. On channel 11, an M0 snapshot caught an HT trial at
physical slot 0 requesting `0x1002` while the policy held `0x80001007`.
The branch moved stage 2 to 3 and invalidated serial 3
(`0x80000003`). See
`build/hw-validation-wifi-native-trial-policy/logs/trial-policy-mismatch.json`.
This confirms the mismatch occurs on hardware and the new branch is
active. It does not establish what causes the separate no-ACK bursts.

Two follow-ups on that same image echoed 46 and 26 of 48 probes. The
application received and queued replies for every request, and every
miss had four retry-limit/no-ACK confirmations. In the second run,
the RX duplicate trace matched AP retransmissions to nine successful
probes and four misses, without ring overflow. Those retransmissions
did not distinguish the uplink failures from the successful echoes.
See `logs/udp-confirm-timing-after-policy.json` and
`logs/udp-ap-retry-correlation.json` in the trial-policy run directory.

The pinned `rc.o:rc_init+0x4a8` clears `rc_sta_stats.info`. Bit 6 is
set when the fixed-rate request is applied, not during an ordinary
association. Consequently `me_utils.o:me_update_buffer_control+0x106..0x116`
can substitute the peer's highest first-stream MCS for *every* HT
retry slot, not only for an active trial. In the native BL808 1SS
station path, RC seeds its table from the local/peer MCS intersection
and uses the lowest negotiated MCS when 1 Mbps is unavailable. Policy
publication preserves the selected rates and that negotiated bitmap,
including after retry rotation. AP and archive-compatible policy
paths retain the SDK rewrite. This restores distinct retry rates and
valid trial samples; it does not identify the source of no-ACK bursts.

The UART-anchor image passed the HTTP/WASM/UDP manifest. Its channel-11
follow-up echoed 41 of 48 probes and all 13 snapshots matched the RC
selection to the programmed policy. Every request reached the application
and queued a reply. The seven misses had four no-ACK confirmations each
and no TX reset, connection loss, or RX upload failure. A breakpoint
confirmed publication for an armed legacy trial (`0x0003`), but did not
catch a lower HT trial. See `build/hw-validation-wifi-native-ht-retries/logs/`
for `udp-ap-retry-correlation.json` and `trial-policy-preserved.json`.

The pinned `hal_machw.o:hal_machw_init+0x6e..0x206` programs the same
MAC timing fields as Nim for a nonzero reset clock. Neither initializer
writes the four RX-start delay bytes at `0x24B00100`, which matched in
the native/vendor auth-entry capture above. That does not measure PHY
receive readiness after TX. A missed completion alone cannot distinguish
absence of an on-air ACK from failure to detect one locally.

Two longer-lived channel-11 samples of the HT retry image echoed 48/48
and 95/96 requests. In the first, a live automatic policy preserved
`0x1205` and `0x1207` together, with MCS 5 leading; the SDK publication
loop would have substituted MCS 7. In the extended run the sole missed
reply exhausted four confirmations over 40.138 ms. The sampled BSSID,
power-save state, MAC mode, RX filter and RX-start delays stayed stable,
with beacon RSSI at -74 to -73 dBm. These observations do not sample
the receive path during an individual response window. See
`udp-link-state-correlation.json` and `udp-link-state-extended.json` in
the HT-retry run directory.

Station activation in pinned `mm_task.o:mm_hw_config_handler+0x4ea`
copies the voice EDCA word to the other hardware queues. On Frog, the
station saved four different queue words but all four hardware registers
held `0x0002f322`. Nim now publishes each saved slot for STA as well as
AP, consistent with the per-access-category parameters in the
[IEEE 802.11 QoS overview](https://ieee802.org/1/files/public/docs2008/avb-gs-802-11-qos-tutorial-1108.pdf).
Non-QoS station setup supplies the same legacy default to all slots, so
that profile retains its previous result. The pre-fix readback is in
`build/hw-validation-wifi-native-ht-retries/logs/live-edca.json`.

The pinned STA VIF-state confirmation does not replace the shared
AP RX filter installed by `mm_hw_ap_info_set`. The native confirmation
now keeps that filter when an AP is registered. If AP is registered first,
adding an address-compatible VIF no longer reruns the single-interface
MAC setup that clears AP mode. Host fixtures cover both orderings and
check preservation of PS-Poll admission and the two-VIF filter bit.

Pinned `txl_cntrl.o:txl_transmit_trigger+0x9a` reads the primary THD
completion word with one aligned `lw`. The native M0 build had used
multiple byte loads through the packed layout. It now uses one aligned
volatile word load for the readiness decision and its diagnostic snapshot.
This is a DMA read correction, not evidence that previous no-ACK reports
were torn reads.

The corrected image passed the HTTP/WASM/UDP manifest after UART-anchor
flash and reboot. All 13 channel-11 snapshots matched the negotiated
and saved queue words: `0x00000a47`, `0x00000a43`, `0x0005e432`,
`0x0002f322` (BK, BE, VI, VO). The application received and queued all
48 UDP replies; 37 echoed. Each miss exhausted four no-ACK confirmations
over 36.813 to 73.745 ms, without a TX reset or disconnect. The queue
programming is verified; the losses are not resolved. See
`build/hw-validation-wifi-native-edca-owner/logs/udp-edca-followup.json`.

Pinned `me_utils.o:me_beacon_check+0x52/+0xb4/+0x108` processes ERP,
power, and channel updates but does not refresh WMM. The native RX path
now independently reads the WMM update count on admitted beacons from
the current associated peer, with the RX-harvest frequency checked
against the VIF's context. The update is not gated on the old beacon
CRC: pinned `mm.o:mm_check_beacon+0x33a..0x36a` hashes non-TIM payloads
without their IE IDs or lengths. The same bounds-checked WMM decoder
is used at scan and for live updates. Invalid live input leaves the
last profile intact, and the update count wraps from 15 to zero.

Pinned `rxu_cntrl.o:rxu_mgt_frame_check+0x1c/+0x28/+0x2c` obtains a
pointer from the first RX payload descriptor, then passes that pointer
and the full length to ME at `+0x3e0..+0x3e8`. Its indication copy at
`+0x496..+0x49e` and `+0x50e..+0x518` also reads from that same pointer.
`rxl_cntrl.o:rxl_mpdu_transfer+0x22..+0x64` follows the payload chain
when transferring ownership; adjacency is not guaranteed after reuse.
Nim copies management indications by segment. For split beacons only,
MM, TIM, WMM and ME use scoped contiguous copies of the validated span
(at most 2328 bytes including the 24-byte beacon header). Each copy is
released before RX ownership transfers; the DMA chain stays unchanged.
The single-buffer beacon and chained data paths are unchanged, and
protected-management integrity checks continue to read by segment.
Host tests exercised a TIM crossing nonadjacent buffers, allocation
failure, and descriptor reuse during allocation. The UART-anchor build
joined Frog and passed DHCP, HTTP, WASM and UDP echo; that bench run did
not exercise a known split beacon. See
`build/hw-validation-wifi-native-split-beacon/logs/`.
Host tests covered nonadjacent buffers, a TIM IE crossing the boundary,
descriptor reuse during allocation and the protected-management trailer.
The UART-anchor flash and reboot passed association, DHCP and the
HTTP/WASM/UDP probes against Frog (channel 6 on this boot). The AP did
not supply a known split beacon in that run. See
`build/hw-validation-wifi-native-split-beacon/logs/`.

Pinned `arch_main.o:wifi_main+0x1bc..+0x1ce` and the clear branch at
`+0x1f2..+0x1f8` copy `0x24B00120[19]` to MAC platform control
`0x24900084[0]` once before `bl_sleep_schedule`. Nim's backend previously
repeated the same read/modify/write before the firmware service step. The
service step is now the only writer in the poll path. The checked, release,
and ASan host fixture validates both bit values and preserves all other
bits; the linked M0 image emits a single `sw` before sleep scheduling.

The UART-anchor build joined Frog and passed the HTTP/WASM/UDP manifest.
A paced follow-up at 2462 MHz reached and queued all 24 replies, of which
21 echoed. Three consecutive misses each had four `0x80010701` completions,
without a TX reset or change to the sampled filter and receive-start delays.
Thus the extra write is not necessary for the retry-limit bursts. No PHY,
TX rate or power configuration was changed for this test. The baseline
and follow-up are in `build/hw-validation-wifi-native-split-beacon/logs/udp-ack-baseline.json`
and `build/hw-validation-wifi-native-mac-poll/logs/udp-ack-after-poll.json`.

Pinned `mm_task.o:mm_hw_config_handler+0x3c..+0x6a` saves the MAC mode
and MM state before requesting idle; `+0x256..+0x262` restores them.
Nim now associates that temporary idle transition with the initiating
kernel message. If the channel context or VIF binding has changed on replay,
the stale request is still freed without retuning or confirming it. Once
the idle event has arrived, the abandoned transition restores the saved
mode and task state once. Explicit idle/bypass handoffs, resets and queue
flushes invalidate the restore. A new idle request also clears an old
posted event, and the event handler cannot move an active or bypassed task
back to idle. This corrects a software stall; it does not explain the
completed hardware retry-limit reports.

For station state-down, pinned `mm_task.o:mm_hw_config_handler+0x3dc`,
`+0x3ea`, and `+0x3f8` clear the three timers before the VIF state write
at `+0x4b2`. Nim keeps that order but rechecks its staged cleanup request
under the IRQ lock before clearing each timer or marking the VIF down.
Replaying slot reuse at the MAC-idle read or during any timer clear no
longer clears the replacement VIF's timers or state.

The Nim message scheduler updates the drained message event before it
checks for an abandoned idle transition. If the old request is discarded
before the event update, the restore check still sees it; if it is
discarded after the check, its new event stays pending. A host replay
discards the final saved request immediately before the empty-queue check
and requires the previous radio mode to be restored without other work.

On the live all-core manager, M0 served seven HTTP requests and its heartbeat
advanced while the Timer0 watchdog feed count stayed zero. The timer approached
its 20-second match and OpenOCD recorded an unexpected M0 reset. The manager's
`yieldNow()` loop kept the scheduler's ready queue nonempty, preventing it from
reaching poll hooks. The scheduler now runs only the entry batch on each pass,
so watchdog, timer, and I/O service are not contingent on an empty ready queue.
The reconnect WPA wait begins after the connect call, and the manager only
publishes recovery with WPA complete and an address. This explains a reproduced
reboot, not the separate failed authentication or association.

The fair scheduler also exposed an LP stack overwrite during WASM task start:
the compiled task-start frame was 2092 bytes, larger than the 2 KiB stack.
The LP live worker now reserves 4 KiB; other LP flash builds retain the 2 KiB
default. With that worker and the corrected M0/D0 images flashed, all four
WASM execution targets returned their expected results. All 21 detached HTTP
probes passed in 61 seconds. The watchdog feed count advanced from 2152 to
9043 and its reset latch stayed clear. Logs are under
`build/hw-validation-allcore-wasm-http-fair-scheduler-recovery/logs/`.
A forced reconnect was not exercised in this run.

The subsequent `AllcoreHttpBenchReconnectMs=15000` run exercised one warm
disconnect through the serving manager's normal recovery path. Initial WPA,
DHCP, and all four WASM targets were healthy. The disconnect returned failure,
the following scan returned zero, and no join result was logged before OpenOCD
reported `Hart 0 unexpectedly reset`. Wired capture saw DHCP and gratuitous ARP
resume after that reset, consistent with a new boot rather than warm recovery.
The logs are under `build/hw-validation-allcore-wasm-http-warm-reconnect/logs/`.
This localizes the reproduced failure to warm teardown or early re-entry; it
does not establish which call stalled, or that a new auth request was sent.

Two teardown paths now have host regressions. The pinned disconnect
completion ignores the TX status and starts local cleanup even when a TX
reset drains the frame. Nim now claims that cleanup once, only for the
still-current SM/VIF/station owner, and defers its commands until the reset
ends. Scan and join also return busy while SM is already disconnecting, rather
than issuing an abort that cannot advance that state. The bench marker `disconnect_stages` packs
current SM state, last SM disconnect request state, request count, and
disconnect-process call count from low to high byte. `scan_recovery` packs SM state,
host recovery stage, and signed 16-bit recovery result in the same order.

The guarded build reached disconnect processing but remained in SM state 10.
Two live snapshots found cleanup waiting on its last request, `ME_SET_ACTIVE_REQ`
(`0x0c0d`), in the saved queue with ME idle. `meControlCommand` was null, but
`meControlReply` held `0x01896578`, not a message pointer. Watchdog feeds rose
between the snapshots; the reset latch was clear. See
`build/hw-validation-allcore-wasm-http-disconnect-reset/logs/warm-cleanup-live-snapshot.jsonl`.

In that linked image `chan_env` was at `0x2204b02c` and was 132 bytes long.
The RSSI code stored the MAC timestamp at `chan_env + 132`, which was
`meControlReply` at `0x2204b0b0`. ME then saved new commands because it looked
like a reply was already reserved. Pinned `mm.o:mm_check_rssi` loads and stores
the dedicated `.bss.last_us` via `.LANCHOR4`, not a word past the channel ABI.
Nim now uses separate MM storage. The old accessor fails the adjacency
regression by overwriting a sentinel reply; the corrected one preserves it.

With the RSSI fix, the Ox64 warm test completed disconnect, scanned 10 results,
rejoined Frog, completed WPA, and restored `192.168.1.114`. HTTP probes before
and after showed all four heartbeats advancing without a boot in between.
The UART-anchor run and independent HTTP samples are under
`build/hw-validation-allcore-wasm-http-rssi-teardown/logs/`.

Pinned `sm.o:sm_delete_resources` queues teardown requests without reserving
all their replies. Nim previously required eight allocations for an active STA
before sending its first cleanup command. Cleanup now reserves only the current
request and its reply, reusing the station-delete request for its confirmation.
An allocation failure leaves that step pending without undoing completed steps.
The disconnect indication is still sent once after the first request is queued.
The host fixture covers completion with at most three live messages and injected
failures at each allocation. Those allocation limits and failures were not
injected on the Ox64.

The next UART-anchor run enabled three forced reconnects and required lwIP to
confirm a lease before HTTP could resume. The hardware Wi-Fi build links the
pinned SDK lwIP: `netif_set_link_up` calls `dhcp_network_changed`, which already
revalidates a bound lease. The warm path now waits for `dhcp_supplied_address`
instead of restarting that exchange or accepting a cached diagnostic address.
Checked and release CPS tests cover delayed lease acceptance, timestamp wrap,
timeout, and link loss while the lease is being checked.

On the first forced cycle, staged teardown returned success and SM reached
idle. The host scan then returned zero results after about 30 seconds. The
watchdog reset latch was clear in the failure snapshot. This run did not
validate DHCP revalidation or repeated reconnects. The known-good RSSI-fix
release was restored. See `build/hw-validation-allcore-wasm-http-warm-lease-3/logs/`.

Separately, the pinned lower `scan_task.o:scan_start_req_handler` sends a
confirmation with status 8 when busy. Nim's upper SCANU owner guard previously
dropped an overlapping host request without sending that caller a completion.
If a request reaches that guard, it now reuses the rejected message for a busy
confirmation without changing the active scan. Ordinary busy dispatch still
saves `SCANU_START_REQ`, matching the pinned `scanu_default_state` table, so this
guard is not a general busy reply. Neither path was identified as the cause of
the zero-result scan.

In pinned `sm_task.o`, `scanu_start_cfm_handler+0x5c` and
`scanu_join_cfm_handler+0x48` check the cancel byte before reporting the scan or
join outcome. The failed-confirmation path now also consumes that cancel and
reports status 26 or 25, respectively, without accepting a stale reply. The
fixture covers both failure statuses and duplicate delivery.

`bl808WifiDiagWarmScan` traces command submission status, SCANU admission,
lower confirmation, dwell reservation and notification delivery, host status,
and manager completion. `warm_scan_state` combines channel flags, slot, SCAN
state, and SCANU state in successive bytes, with bit 31 set for a scheduled
context. The first M0-only trace image ended at `0x0e04e0`, overlapping the
LP worker's reserved start at `0x0e0000`. The LP worker timed out before Wi-Fi
started. After restoring LP, the smaller trace image ended at `0x0dfe40`.
The UART-anchor harness now checks the M0 segments against the manifest's LP
offset even when the LP worker is not in the selected outputs.

The smaller trace image completed scan submission, all 11 channel dwells,
and the host success confirmation in each of three warm cycles. Scan elapsed
times were 3765, 3576, and 3205 ms, with 12, 8, and 7 results respectively.
The first two cycles restored WPA, a confirmed DHCP lease, and HTTP with all
four heartbeat counters increasing. The third returned association failure
(`5`, reason `0xffff`) before WPA instead. Several local paths report that
pair, and the retained association TX counters are cumulative, so the trace
cannot identify the failing path or prove that cycle sent an association frame.
All four counters later restarted, showing that HTTP returned after a reboot.
The failure snapshot's watchdog latch was clear; it does not identify the
subsequent reset cause. See `build/hw-validation-allcore-wasm-http-warm-trace-fit/logs/`.

The next trace build resets `warm_assoc_failure_stage` for each reconnect and
records the local branch that reports `5/0xffff`. Pinned `sm.o` queues VIF
activation before its void `me_init_rate` call; Nim can instead reject a
successful association if the native-calibration HT rate mask is empty.
Nim also reserves seven messages before activation where pinned `sm_assoc_done`
allocates its first request only. These are distinct candidates, not diagnoses
of the third cycle. The failure-stage build fits the M0 flash window and was
not flashed; the non-bench RSSI-fix release was restored after the trial.

The next UART-anchor run reproduced the third-cycle failure and recorded
`warm_assoc_failure_stage=0x0b`, the station activation failure path. The
first two cycles passed. Pinned `sta_mgmt.o:sta_mgmt_init` steps by 368 bytes
until `sta_info_tab+0x730`, placing five peer entries on the free list, and
then initializes slots 5 and 6 for the VIFs. Nim also retires peers to the
tail of that list, so a fresh boot followed by three reconnects can assign
IDs 0, 1, 2, and 3. The host had been compiled with `CFG_STA_MAX=1` and two
VIFs, giving `bl_hw.sta_table` only three entries. It rejected the fourth
assignment when activation tried to publish the peer.

The Nim host table, SDK build flags, and offsets for the following
`mod_params` and `ht_cap` fields now use the firmware counts. The M0 build
asserts these values against the actual SDK C struct. STA events accept
peer indices 0 through 4; indices 5 and 6 are present only for radio entries
belonging to the VIFs. The host regression drives reconnects through all
five peer slots and wraparound; restoring the old three-slot check fails it.
The reproduction is under
`build/hw-validation-allcore-wasm-http-warm-assoc-trace-live/logs/`.

The seven-slot candidate passed the host regression and the M0 build, but its
Ox64 run timed out during cold connection before any warm cycle. A no-flash
breakpoint at `sm_connect_ind` captured `(11, 0xffff)` from
`sm_rsp_timeout_ind_handler` while SM was in state 6 (authenticating).
Station registration had succeeded; the most recent auth TX completed with
`0x80010700` (retry limit, no ACK). RX and SM auth response counters were
zero, and no association request had been sent. This is earlier than host
station publication and is distinct from the three-slot activation failure.
It doesn't establish what prevented the TX/ACK exchange. The candidate was
not left on the bench. Logs are under
`build/hw-validation-allcore-wasm-http-host-sta7-{live,cold-observe}/logs/`.
After UART-anchor restore and reboot, the prior RSSI-fix release also
reported status 11, SM state 6 and a last auth TX completion of `0x80010700`
in a no-reset JTAG read. Thus the cold failure is also reproducible without
the station-table change. See
`build/hw-validation-allcore-wasm-http-host-sta7-restore-observe/logs/`.

Pinned `chan.o:chan_pre_switch_channel+0xa4` programs the selected context.
`sm.o:sm_auth_send+0x152` then submits authentication TX without programming
the channel a second time. Nim's extra pre-auth step favored the frequency
cached by the previous `sm_connect_ind`, including failed attempts, over the
new join's context. An inactive, not-yet-associated STA was also excluded
from the context lookup. This could undo the scheduler's retune while lower
TX admission still used the scheduler's logical channel.

Normal Wi-Fi authentication now leaves channel selection to the scheduler.
The BLE reclaim path requires the operational context and TX permission;
when a join is in progress it takes channel metadata from that join's STA
context, never a previous completion or another VIF. The explicit forced
frequency bench override is unchanged. Host tests drive an inactive STA's
channel-6 to channel-11 transition with stale SM metadata and a second STA
on channel 6, and check that no reclaim occurs without a valid context.

The corrected M0 diagnostic image joined Frog on channel 11 and served
`/wasm/cores` with passing M0, D0, LP, and enclave results. All six forced
disconnect/reconnect cycles passed on the Ox64. Reconnects used station IDs
1, 2, 3, 4, 0, and 1, and each reported an authentication ACK, an association
ACK, and a DHCP lease. The trace is in
`build/hw-validation-allcore-wasm-http-auth-channel-live/logs/`.
This verifies the corrected path on the bench; no over-air trace was
captured to establish the transmitted channel of an earlier failed retry.

The non-bench build was then left in flash. It joined Frog, obtained
`192.168.1.114`, reported advancing heartbeats and correct WASM results for
all four execution targets, and returned `42` for an HTTP invocation of
`add(19,23)`. The manifest run captured DHCP and HTTP readiness but missed
the early boot markers in the JTAG-memory log and timed out. Its failure
snapshot halted M0; a no-reset JTAG read/resume restored service. See
`build/hw-validation-allcore-wasm-http-auth-channel-release/logs/`.

Two HTTP issues are separate from the Wi-Fi result. The generated CPS code
stores the lease in a coroutine field while the status handler reads the
zero-initialized global. Also, the lwIP receive callback hands the parser
one receive buffer at a time, so a POST with separately delivered headers
and body can fail with `400 incomplete body`.

Pinned `chan.o:chan_ctxt_set_auth_assoc_req` stores a command at
`chan_env+0x80`, and `chan_pre_switch_channel+0x1de` releases it during a
STA channel activation. The state check in `sm_task.o:sm_connect_auth_assoc_req`
doesn't track binding lifetimes. Nim now captures the per-VIF link generation
as well as the attempt and context pointer. If an unlink invalidates a parked
command, channel teardown queues that command to SM rather than leaving it
waiting for an activation that may never come. SM reports one failure for
the still-current attempt and never sends using the retired binding. An
unlink and relink to the same context slot also invalidates the command.
The host tests use the production link/unlink and SM dispatch functions for
parked, queued, and reentrant cases, including same-slot reuse.

Pinned `sm.o:sm_assoc_rsp_handler+0x56` explicitly clears the response timer
when processing a response. Nim ignored truncated success IEs but advanced
the TX serial first, invalidating the timer without clearing or replacing
it. Nim now validates those IEs before claiming the response. Both truncated
IE regressions verify that the real timer ownership predicate still accepts
the original deadline; restoring the previous order fails that check.

The combined build also passed all six forced reconnects on the Ox64, using
peer slots 1, 2, 3, 4, 0, and 1 and reacquiring its DHCP lease each time.
See `build/hw-validation-allcore-wasm-http-deferred-bind-live/logs/`.
This is a reconnect regression run; the exact link-generation and ignored-IE
timing cases were driven by the host fixtures.
The non-bench build passed the DHCP/HTTP readiness check and was left in
flash. Direct HTTP checks again verified advancing heartbeats on M0, D0, LP,
and the enclave and `add(19,23) = 42`. See
`build/hw-validation-allcore-wasm-http-deferred-bind-release/logs/`.

Pinned `sm.o:sm_auth_send+0x3e` and `sm_assoc_req_send+0x40` read the
registered peer index from VIF offset 96. Both copy the station row's MAC
into the destination and BSSID and use that row for the TX descriptor.
Nim now requires a live peer row owned by the joining VIF and matching its
specific BSSID before either sender allocates a frame. The same snapshot
supplies the frame addresses and the SAE callback. A peerless TX could
reach the MAC but could not match the auth response ownership check;
an unclassified RX label still works for a correctly registered peer.

The pinned senders call `txl_frame_push` and then `ke_timer_set` without
branching on the TX return (`sm_auth_send+0x152/+0x176` and
`sm_assoc_req_send+0x12e/+0x148`). Nim keeps its response state and timer
publication before handoff for reentrancy, but no longer cancels the timer
on a lower-layer rejection that consumed the frame. The timer still controls
bounded retries. Tests exercise the actual deadline dispatcher with a
controlled clock for rejected handoffs and accepted requests with no reply;
neither retries early, leaks a frame, nor reports failure twice.

On the first Ox64 boot with both changes, the bench build joined Frog and
passed five forced reconnects. On attempt six, disconnect succeeded but the
host scan returned zero before the join call. That value doesn't distinguish
submit failure, timeout, and an empty result. After the board restarted,
following the same flashed image without another write captured the sixth
attempt returning 11 results, joining with peer ID 1 and recovering its
lease. The pass counter reached six. See
`build/hw-validation-allcore-wasm-http-join-peer-{live,follow}/logs/`.
The first scan failure is unresolved; neither run injected a stale TX peer
or a synchronous TX rejection on hardware.

The non-bench build passed after recovering the UART anchor and was left in
flash. Direct HTTP checks showed advancing M0, D0, LP, and enclave heartbeats
and `add(19,23) = 42`. See
`build/hw-validation-allcore-wasm-http-join-peer-release-retry/logs/`.
The host `bl_main_scan` wrapper, like the reference SDK wrapper, discards
the submission return from `bl_send_scanu_req`. An allocation or queue
failure can therefore enter the async wait as if a scan were accepted.
The initial failure snapshot doesn't identify that as the cause; a follow-up
trace should capture submission status and scan completion separately.

The host wrapper now returns the result of `bl_send_scanu_req`, so a
rejected submission never starts a 30-second async wait. SCANU completion
also preserves the status byte without changing the legacy callback event.
The async count is zero when the final status is nonzero, even if the scan
posted partial results. Pinned `scan_task.o:scan_start_req_handler+0xa0`
sets status 8 when busy; busy and other failed replies are not empty
successes. Host fixtures exercise both boundaries and confirm that invalid
fixed-channel lists do not reach submission.

For `bl808WifiDiagWarmScanCompact`, the bench freezes the first zero scan
in the eight-word `allcore_warm_scan_failure` symbol before starting another
operation. In order, the words are `0x5343414e` (published), elapsed ms,
signed manager submission status, scan/channel state, path deltas, dwell
deltas, completion, and frames seen. The low-to-high bytes of path are
SCANU admission, lower confirmation, slot admission, and host confirmation;
those of dwell are start post, start handling, end post, and end handling;
those of completion are lower status, host status, manager completion
count, and accepted-frame delta. Status bytes without a corresponding
confirmation delta may belong to the previous scan.

The instrumented Ox64 run passed ten forced reconnects and returned 8–13
scan results on each. Peer IDs rotated through 1, 2, 3, 4, and 0 twice.
A no-reset JTAG read after the run found all eight failure-snapshot words
zero. This verifies the changed paths on ordinary reconnects but does not
identify the cause of the earlier zero-result scan. See
`build/hw-validation-allcore-wasm-http-scan-outcomes-{live,post-run}/logs/`.

Pinned `scanu.o:scanu_confirm+0x64/+0x74/+0x8c` publishes the requester
confirmation and optional API notification before entering idle. The Nim
task had entered idle first, which can enqueue a saved scan ahead of the
station manager's reply. That scan can clear the BSS cache before the
manager consumes it. Nim now detaches the request before publishing, keeps
the task busy through publication, and only idles the same generation.

Pinned `scanu_task.o:scanu_join_req_handler+0xa4..+0xac` sets the pending
replay field only when replaying a cached frame, not when receiving a
live directed response (`scanu.o:scanu_frame_handler+0x82e`). Nim now
reserves a synthetic DONE before handing off the cache entry and uses
that exact message as the replay marker. A lower scan completion cannot
consume the replay, a stale synthetic DONE cannot advance a live scan,
and an allocation failure leaves the cached frame owned by its slot.

Pinned `scanu.o:scanu_frame_handler` uses request bit `0x100` for early
channel dwell completion. For a specific BSSID, that occurs before SSID
filtering (`0x04de..0x0546`); a wildcard BSSID needs a matching SSID slot
(`0x0638..0x066c`, `0x09d0..0x09e6`). A matching empty or named slot
also honors the whole-scan abort bit `0x40`. The ordinary host scan does
not set either flag, so this comparison alone does not explain the
earlier zero-result scan.

The Ox64 passed ten forced reconnects over the UART-anchor flow with
6-11 scan results per cycle. Each cycle restored WPA and the DHCP lease.
The host fixtures forced the exact FIFO, replay allocation, and stale
completion cases; the bench run did not inject those conditions or
reproduce the earlier spontaneous disconnect. See
`build/hw-validation-allcore-wasm-http-scanu-order-live/logs/`.
The normal image passed the DHCP and HTTP readiness checks and was left
in flash. Direct HTTP requests verified advancing M0, D0, LP, and
enclave heartbeats and `add(19,23) = 42`. See
`build/hw-validation-allcore-wasm-http-scanu-order-release/logs/`.

Pinned `scan_task.o:scan_start_req_handler+0x80` publishes a one-byte
confirmation after admission and `mm_scan_channel_end_ind_handler+0xb0`
posts a basic DONE. Pinned SCANU dispatches them by status and phase
(`scanu_task.o:scan_start_cfm_handler+0xa` and
`scan_done_ind_handler+0x96`). Nim keeps those sizes and routing, but records
the request identity and upper generation before enqueue. It rejects old
commands at SCAN and mismatched completions at SCANU. If the END envelope
cannot carry DONE, the retained lower request carries it without allocating.

Pinned `mm_timer.o:mm_timer_schedule+0x84` dispatches the popped timer,
and `chan.o:chan_ctxt_op_evt+0x14c` posts the scan slot's END. A changed
scheduled target alone no longer invalidates a live operating scan timer.
Allocation, reset, current channel, and channel definition checks still
gate expiry. The host fixture reproduced the old timer disappearing
without an END.

Pinned `chan.o:chan_conn_less_delay_prog+0x20/+0x60` reserves the gate and
arms the timer. Nim checks ownership around callbacks during preparation.
If the other connectionless slot legitimately joins during that interval,
the original gate owner now arms a timer for both pending requests instead
of dropping the reservation. The host fixture checks an actual MM timer
queue with a ROC admission during the scan-gate preparation.

The compact trace image omitted verbose console fields to fit below
the LP flash region; its eight-word failure snapshot was unchanged. It
passed ten forced reconnects on the Ox64, with 7-12 scan results and
WPA/DHCP recovery each time. A no-reset JTAG read found all eight
snapshot words zero. See
`build/hw-validation-allcore-wasm-http-scanu-exchange-live/logs/`.
The timer interleavings are proven host reproductions, not a diagnosis
of the earlier spontaneous disconnection or zero-result scan.
The normal image was then flashed and passed DHCP/HTTP readiness. Direct
HTTP requests verified advancing M0, D0, LP and enclave heartbeats and
an `add(19,23)` result of 42. See
`build/hw-validation-allcore-wasm-http-scanu-exchange-release/logs/`.

Pinned `mm.o:mm_ap_probe_cfm+0x0..+0x14` clears the missed-beacon count
on ACK bit 23 or reports local loss status 16. Nim now checks the frame
callback's original TX session first, as it already does for
`mm_ap_traffic_probe_cfm`. A host replay demonstrated that an old
completion could otherwise clear the replacement station's counter
or report loss against it.

Pinned `sm.o:sm_deauth_handler+0x108/+0x1be` reads a fixed reason
offset and reports firmware status 7 with the received reason.
Nim RX keeps the 28-byte management header when HT Control is present.
The SM dispatcher and handler use that header length for admission and
reason extraction rather than interpreting HT Control as a reason.
Host cases cover both subtypes, a truncated body, and the SA Query path.
The earlier hardware snapshot's status 7/reason 7 and absence of an MM
loss event establish the reported AP disconnect, not why it happened.

`bl808WifiDiagLinkDrop` keeps the first non-forced outage that reaches
the recovery debounce threshold. The M0 `allcore_link_drop` snapshot
captures the first observed edge before reconnect can overwrite it.
Its 14 words are: marker `0x4c494e4b`, uptime ms, status/reason
(low/high halfword), states/trigger flags, RX silence ms, unconfirmed TX
age ms, last enqueue flow-control flags, deauth handler calls, MM loss
producer calls, then five traffic-probe words (attempts, rejected
submissions, ACKs, other completions, last raw TX status).
The states word contains SM and WPA in bits 0-15 and 16-23; bits 24-27
are driver connected, manager IP set, RX stalled, and TX stalled.
A transient observation alone does not publish the marker. The counters
are cumulative since boot, and the snapshot does not survive a reset.

The UART-anchor diagnostic image joined Frog and passed DHCP/HTTP
readiness with no forced reconnect loop. Over a 70-second sample all
four WASM heartbeats advanced. A no-reset JTAG read found the snapshot
empty and counted four traffic-probe attempts, no rejected submissions,
three ACKs, and one other completion. The most recent status was
`0x80800000`; the other completion's raw status was not retained.
The image was left running to capture a future spontaneous outage.
See `build/hw-validation-allcore-wasm-http-link-drop-watch/logs/`.

The next audit distinguished local TX retirement from an over-the-air
probe outcome. Pinned `txl_frame.o:txl_frame_evt+0x62` passes the word
from hardware descriptor `+64`; the pinned internal release path can
instead call back with zero. `mm_ap_probe_cfm` used to treat either kind
of non-ACK as local status 16. The traffic path could also reach local
status 22 after rejected submissions or local retirements. Nim now spends
the corresponding link-loss budgets only on actual DMA completions (bit
31), keeps diagnostic retirement counts, and does not apply a late beacon
probe failure after a beacon has restored the watchdog count.

Pinned `sm.o:sm_issue_sa_query_request+0x36/+0x4e` sends the frame and
arms the timeout. `sm_task.o:sm_sa_query_timeout_ind_handler+0x1c/+0x2a`
retries and decrements the budget. Nim keeps the vendor's two retries and
100 ms interval but adds station/VIF generation, attempt serial and MAC
deadline ownership. An old untagged timeout cannot spend a replacement's
budget before its deadline, and a response retires the attempt before timer
cancellation. A timer allocation failure is not evidence of peer loss.
Station unregister also clears the intrusive keepalive timer at VIF `+140`
before reinitializing the VIF, under the same retirement guard as the
other watchdog timers.

The UART-anchor flash verified the new kernel and rebooted it on the Ox64
with the installed D0 and LP images left in place. The board joined Frog,
obtained a lease, and passed HTTP readiness. M0, D0, LP and enclave WASM
heartbeats advanced, and the HTTP manager returned 42 for `add(19,23)`.
The no-reset link-drop snapshot remained empty at ten traffic-probe attempts:
nine ACKs, no rejected submissions, one other completion, last raw status
`0x80800000`. The other completion is not classified by this snapshot. The
diagnostic image was left running. This validates boot and operation on the
bench; it does not identify the earlier spontaneous disconnect trigger.
See `build/hw-validation-allcore-wasm-http-link-drop-owned/logs/`.

Pinned `mm.o:mm_sta_tbtt+0x52/+0x70` arms the next TBTT and the
VIF `+140` watchdog. `mm.o:mm_check_beacon+0x25e` clears that watchdog
after a received beacon; `mm_sta_timer_bcn_timeout+0x2c..+0x36` counts
a miss and clears the listen flag. `mm_timer.o:mm_timer_schedule+0x84`
calls the popped timer. The Nim port releases IRQs for timer/log callbacks,
so the same VIF and station can still be current after their timer work
has been superseded.

Nim tracks popped MM timer deliveries until the callback returns. A clear,
rearm, or reset invalidates the old delivery for that timer even when its
node is no longer queued; operations on unrelated timers do not cancel it.
The STA TBTT and watchdog callbacks check this ownership. They also compare
the received-beacon counter across callback boundaries, so a TBTT callback
cannot rearm after a newer beacon has cleared the watchdog, and an old
watchdog callback cannot count that beacon as missed. Host cases reproduced
both false outcomes before the guards and check a same-address rearm, reset,
and beacon count rollover. This is a Nim ownership correction, not evidence
that either race caused the earlier AP-reported disconnect.

The guarded image ended at `0x0dff00` (exclusive), 256 bytes below the
installed LP image. The UART anchor verified flash and rebooted it. On the
Ox64, Frog association and DHCP completed, all four WASM heartbeats advanced,
and the HTTP manager returned 42 for `add(19,23)`. The first no-reset snapshot
was empty at one ACKed traffic probe with raw status `0x80800000`. The image
was left running for further observation. See
`build/hw-validation-allcore-wasm-http-beacon-watchdog-owned/logs/`.

Pinned `bl.o:bl_sleep_schedule+0x10..+0x26` clears the software sleep
state when PM stops without issuing an exit event. The same archive's
`wakeup_from_doze_pre+0x2e` clears its doze flag before polling for idle
at `+0x74..+0x78`, and `wait_mac_goto_prestate+0x48..+0x4c` polls until
the saved MAC state returns. The archive's state polls do not return a
software timeout. In Nim they are bounded, but the old dispatcher still
ran wake-done when either bounded poll failed.

Nim keeps wake pending until the callback chain succeeds. On STOP it
uses the capabilities saved at nap entry, even if the profile has changed;
deinit defers removing the callbacks while an exit is outstanding. Once
the MAC has reached idle, a failed pre-state restore doesn't reissue doze
exit. Firmware service does not consume queued work while wake is pending,
and the host drain does not immediately retry it in a tight loop. The host
test reproduces STOP while asleep and both timeout sites with the real Nim
scheduler, dispatcher, and MAC handlers. These are power-save recovery
fixes, not evidence for the reason-7 outage observed with power save off.

The UART-anchor build ended at `0x0dff00` (exclusive) and passed Frog
association, DHCP, and all-core HTTP/WASM smoke on the Ox64. All four
heartbeats advanced and the HTTP invocation returned `42`. Startup RAM
showed successful recovery/admission codes and zero hardware wait timeouts.
This image keeps power save disabled, so this run does not exercise MAC
doze on hardware. See `build/hw-validation-allcore-wasm-http-pm-wake-owned/logs/`.

Pinned `chan.o:chan_pre_switch_channel+0x150/+0x178` clears the MAC PM
bit on return to an operating channel and attempts one PM=0 Null frame
per eligible associated station. It does not wait for an ACK before
activating the channel. Pinned `txl_frame_get+0xc8/+0xde` can age
postponed descriptors or flush AC3. Nim used to skip the notification
outright on an empty free pool, avoiding the flush but losing the work.

Nim now attempts immediate admission and uses a per-VIF MM timer for up
to four 5 ms retries after an empty pool or local submission rejection.
It preserves channel activation, never invokes the allocator with an
empty pool, and retires a retry if its station, VIF, channel or reset
ownership has changed or a newer departure has been scheduled. A
successful submission can still be postponed; it is not an on-air ACK.
Host checks include the prior drop behavior as a negative control, a
descriptor becoming available, persistent failure, both VIFs, clock wrap,
and a replacement arriving between actual MM timer pop and dispatch.

The opt-in `bl808WifiBenchConnectedScan` all-core variant runs an extra
scan after DHCP. Require `[PASS] connected scan returned home`; it checks
that scan results were returned, a Null frame was admitted on the home
channel, WPA stayed up, and the DHCP address was unchanged. This tests
the normal return path on the board, not injected descriptor exhaustion
or over-the-air ACK delivery.

On the Ox64 that build passed the associated scan and retained its lease.
It recorded 11 home-return submissions and no attempts with an empty free
pool. All four WASM heartbeats advanced and the HTTP invocation returned 42
after the scan. The build ends at `0x0dfe90`, 368 bytes below LP, and was left
running with the original link-drop snapshot enabled. See
`build/hw-validation-allcore-wasm-http-home-null-connected-scan/logs/`.

The running manager answered HTTP at `192.168.1.114` while reporting
`0.0.0.0` in both `/` and `/wasm/net/status`. Live OpenOCD reads found
`0x7201a8c0` in lwIP's default netif and zero in the HTTP `httpIp`
global. The executable's CPS transform had turned the lease-renewal
assignment into a continuation field, so even initial DHCP publication
wrote that field instead of the global. Both CPS transforms now assign
the awaited result through the original lvalue. Host tests exercise
delayed and already-resolved futures, failed futures, and indexed
destinations. The running image was not replaced during this check.

Separate reconnect lead: `sm.o:sm_delete_resources+0xa8/+0xce` queues STA
deletion and ME deactivation in the same pass, and
`sm_task.o:sm_default_state+0x90` discards `MM_STA_DEL_CFM`. Nim instead
waits for its owned reply before starting ME deactivation so it cannot
reuse a slot that is still draining TX or deleting keys. The request
itself is reused for the reply, so reply allocation is not a failure point.
A held confirmation can nonetheless prevent scan/join admission, proven on
the host, not yet seen on the bench. On a subsequent real outage, compare
`sm_state`, the recovery stage/result, `smCleanup.step/awaiting`,
`mmStaDelRetryMask`, and hardware-wait counters from the matching ELF to
distinguish hardware cleanup retry from an already-queued confirmation.

The Nim delete retry now saves the request before arming the MM timer,
coalesces new retry bits without moving the oldest deadline, and ignores
a popped delivery canceled by reset and rearm. The host fixture runs
the real request handler and MM timer with a fake clock and reproduces
all three failures in the old code. An older forced reconnect was
observed blocked at ME deactivation instead; neither case establishes
why the original natural reason-7 disconnect occurred.

Radare2 shows the pinned `mm_task.o:mm_sta_del_req_handler+0x0c` call
to synchronous `mm_sta_del` before its confirmation at `+0x1c`. The
Nim retry batch must carry ownership across a boundary that the vendor
handler does not have. It now captures each station generation on
enqueue and rechecks it under the same IRQ lock as deletion entry.
Reinitializing MM aborts an in-flight batch without requeueing work or
waking saved requests for the new generation. Ordinary rearm after a
failed attempt still lets the other stations in the batch proceed.
Host timer replays cover slot replacement and MM reset both before
and during dispatch.

Vendor `sm.o:sm_disconnect_process+0x4a/+0x72` calls cleanup before
sending the disconnect indication; `sm_delete_resources+0xb8` unlinks
the VIF's channel synchronously. Previously, staged Nim cleanup could
publish link loss with the old channel still attached while waiting for
`MM_STA_DEL_CFM`. Nim now queues its first cleanup request, detaches
the original channel binding and then sends the disconnect indication.
It still requires the owned confirmations before admitting reconnect.
The binding generation is checked with IRQs disabled at detach entry:
a WPA callback that rebinds the same context address cannot make the old
cleanup detach the replacement. Host replays reproduce both ordering
faults before the fix. This does not establish that either fault caused
the original reason-7 bench outage.

The Ox64 UART-anchor run then passed ten forced reconnects in one boot.
Each disconnect and join returned success, each scan returned 1-9 results,
and WPA and DHCP recovered on each attempt. The station index rotated
through all five slots twice. The lean M0 build enabled
`bl808WifiDiagLinkDrop` and `bl808WifiDiagWarmScanCompact` without the
full warm-scan trace and ended at `0x0dfbe0`; LP and D0 were retained.
`/wasm/net/status` reported `192.168.1.114` before and after the cycles.
All four WASM heartbeats advanced and HTTP `add(19,23)` returned 42.
See `build/hw-validation-allcore-wasm-http-channel-detach-warm-lean/logs/`.
The image stays up after the tenth cycle; a reboot repeats the bench.

Pinned `sm_task.o:sm_disconnect_req_handler+0x14` saves a host
disconnect while SM is busy; at `+0x1e` it reads only the VIF index.
That index can refer to a different connection by the time a saved
request runs. Nim now captures the station VIF generation when it
enqueues the request. A request for that same generation still acts
after join completion; one for a replaced generation only retires.
The empty `SM_DISCONNECT_CFM` reuses the request allocation, so it
does not depend on the separate allocation at vendor offset `+0x44`.
It confirms command retirement, not that the link is down. The host
replay covers replacement before dispatch, saved replay, a completed
join without replacement, and confirmation with allocation disabled.
Removing the generation check makes the replay fail.

Pinned `mm.o:mm_sta_tbtt+0xbc/+0xc4` wraps the missed-beacon
byte and tests the result against 100 before submitting a null
probe. Its completion at `mm_ap_probe_cfm+0x0e` reports reason 16
on no ACK without retesting that byte. Nim now tags TBTT probes with
a per-VIF liveness epoch instead of using the current countdown to
decide whether the completion is stale. A beacon or a successful
probe can supersede an earlier queued failure; wrapping from 255 to
0 cannot. The TX session check and DMA completion bit still reject
retired work and local queue flushes.

Pinned `td.o:td_timer_end+0xd0/+0xd8` notifies PS and then stores
the traffic flags. It clears the counters and updates the active
latch before checking whether to rearm. A synchronous PS
confirmation in Nim could change the timer operation epoch and
prevent that accounting. The expiry handler now accepts exactly one
committed same-session confirmation without replacing its timer.
The host replay checks the next traffic-to-idle notification and
verifies that a replacement still prevents stale accounting.

The first M0 builds overlapped LP by one erase sector. The all-core
linker now puts the zero-initialized SD DMA scratch buffers in the
startup-cleared BSS, keeping their RAM addresses without storing 4,616
zero bytes in flash. The wrapped M0 image occupied 849,312 bytes from
`0x010000` and its erase-rounded exclusive end was `0x0e0000`, the
start of LP. The UART anchor wrote only M0; LP and D0 were unchanged.
The Ox64 ring showed three forced reconnect passes. The last cycle
recorded disconnect and join success, 12 scan results, WPA state 10,
and DHCP at `192.168.1.114`. HTTP reported all four WASM contexts
healthy, returned 42 for `add(19,23)`, and listed the SD repository.
Both natural-failure records were empty at the no-reset JTAG read.
See `build/hw-validation-allcore-wasm-http-disconnect-request-owned-beacon-td/logs/`.
Neither the host cases nor these forced cycles explain the original
spontaneous reason-7 outage.

Pinned `sm.o:sm_disconnect_process+0x38/+0x4a` clears the SA Query
timer before calling cleanup. In Nim, timer retirement can invoke
platform code. The disconnect path now captures the VIF/station
owner and SM state before the clear; cleanup checks that handoff under
its lock before accepting it. The host replay replaced the session
at timer clear, reproduced teardown of the replacement before the
fix, and verified that a current-session disconnect still completes.

Vendor `sm_deauth_handler+0x1be` and
`sm_task.o:sm_sa_query_timeout_ind_handler+0x94` both request status 7.
The latter reuses the reason saved from the peer frame. The
`bl808WifiDiagLinkDrop` build adds a separate six-word
`nimfw_dbg_peer_disconnect` record for the first SM teardown decision:

| Word | Contents |
| --- | --- |
| 0 | `0x50454552` (`PEER`), written last; zero means no decision captured |
| 1 | MAC clock at the decision |
| 2 | Reason, VIF index, station index (16/8/8 bits, low to high) |
| 3 | Frame Control and Sequence Control (16/16 bits) |
| 4 | RX frequency in MHz, signed RSSI, path (16/8/8 bits; 1 direct, 2 SA Query expiry) |
| 5 | Query submissions and local rejections (8/8 bits) |

The original frame metadata is kept with the owned SA Query, not
read from a later frame. Pinned `sm_send_sa_query+0x112/+0x11a`
calls the TX queue and returns zero regardless of queue rejection.
The exported Nim ABI still does that, but the internal submit path
keeps that result for the diagnostic. Admission to the TX queue is
not proof of transmission or an ACK. This record does not imply that
cleanup completed or the host accepted the disconnect indication;
the host-facing `allcore_link_drop` and `allcore_reconnect_failure`
records remain separate.

The Ox64 soak build disables the forced reconnect loop. M0-only
UART-anchor flashing passed (849,232 wrapped bytes, rounded end
`0x0e0000`); the image booted, acquired `192.168.1.114`, and served
HTTP with all four WASM contexts healthy. A no-reset JTAG read of
the running ELF's three records found them all empty. In this ELF
the peer, reconnect, and link records are respectively at
`0x62022ca0`, `0x6202acc0`, and `0x6202ad64`. See
`build/hw-validation-allcore-wasm-http-peer-disconnect-soak/`.

Pinned `sm.o:sm_send_sa_query+0x42/+0x52/+0xd2/+0x112` allocates
the frame, sets TX power, applies protection, then queues it. The Nim
builder now keeps the original peer, reset, and descriptor generations
across those calls. A pending request also retains its query serial:
an intervening response can retire the request before it queues a
frame or rearms the timer. Host replays cover peer and reset retirement,
same-slot descriptor reuse, and query completion during preparation.

Pinned `ps.o:ps_disable_cfm+0x36/+0x3e/+0x42` clears the TX-null
timer and reloads the outstanding confirmation count before finalizing.
Nim previously used the value from before the timer call. Both PS
confirmation paths now check the live count and the TX callback owner
after clearing the timer. The host replay failed before the fix and
checks both replacement and unaffected-owner cases.

The TBTT probe epoch check now extends to the private tail on
`MM_CONNECTION_LOSS_IND`. A newer beacon or ACK can invalidate
reason 16 after it was queued, including while SM has it saved.
The producer also checks for newer evidence after its allocation
callout. The message wire format and other loss reasons are unchanged.
Host replays cover allocator reentry, immediate dispatch, saved replay,
and a change to the other VIF that must not discard the loss.

The all-core build containing these three changes passed the UART-anchor
dry run. Its wrapped M0 image is 850,320 bytes at `0x010000`, with
erase-rounded exclusive end `0x0e0000`. It was staged, not flashed,
to preserve the earlier image's no-forced-reconnect soak. A follow-up
read of the running board still found all three outage records empty.

Pinned `mm.o:mm_sta_tbtt+0xb2..+0xc0` increments the miss count modulo
256; `+0xc4` only submits a probe when the new count exceeds 100.
After sustained misses and TX admission failures, this can suppress
probes for 101 more on-channel TBTTs even after the queue recovers.
Nim saturates the count instead. A replay of the production handler
keeps the queue unavailable through count 255, restores it off-channel,
and requires a probe at the next on-channel TBTT. A fresh beacon or
successful probe completion still clears the counter and advances the
evidence epoch. This is not a reproduction of the Frog reason-7 drop.

Pinned `sm_task.o:mm_connection_loss_ind_handler+0x42/+0x4a/+0x5c`
sets SM disconnecting, calls the TLV stub, and enters teardown.
Nim now carries the report's original peer, reset, and SM ownership
across that sequence and the SA Query timer clear. Pinned
`sm.o:sm_connect_ind+0x14e/+0x198` similarly publishes the failure
state before cleanup; Nim rechecks the original connection and
indication before reading or clearing the scan index and before
entering cleanup. Host fixtures made both old paths act after a
state-publication callback replaced the station or connection.

The [host loss-queue oracle](wifi_model_fuzzer.md) combines the
production loss producer and SM consumer with the real saved-queue
state transitions. It includes a mutation that restores dispatch
of a stale probe report after fresh liveness evidence. This is a
BL808 implementation contract, not an IEEE requirement.

The combined host cleanup tests now cover two progress gates. A
failed station deletion holds its own request and a later reconnect
in the saved queue. The fake clock reaches the retry deadline across
wrap, the real MM retry callback wakes only MM work, and cleanup
consumes one delete confirmation before waking the reconnect. The
real SM handler starts one scan and emits one terminal indication
for a simulated successful association. The separate MAC-idle case
starts with MM active and proves that a reply from a different
allocation cannot replace the reserved reply. The real
`mm_hw_idle_evt` releases the saved MM request; the final owned ME
confirmation reaches SM before the competing saved activation.

The combined image passed the Ox64 UART-anchor run. The wrapped M0
image was 851,552 bytes and its erase range stopped at LP's start;
D0 and LP were not rewritten. The three forced reconnects reached
the pass counter of three. The last cycle reported disconnect and
join success, 11 scan results, WPA state 10, and DHCP at
`192.168.1.114`. The captured ring holds the last cycle and the
second pass marker, not the full boot. The peer, link-drop and
natural reconnect-failure records were still empty. The board stays
in normal service after the third cycle; a reboot repeats the test.
See `build/hw-validation-allcore-wasm-http-sm-handoff-forced/`.

Pinned `ke_msg.o:ke_msg_send+0x38` calls the host E2A handler inline
and retires the message afterward. Cleanup-owned disconnect and
failed-connect indications now carry their original association
epoch through that call without changing the vendor wire payload.
The host checks the epoch and firmware VIF before capturing the
local station transition. The fixture rejects delivery after
same-slot association replacement and VIF rebinding, but still
accepts events after retirement of the original station slot.

Pinned `sm.o:sm_delete_resources+0x52/+0x7c/+0xa8/+0xce` queues
all four teardown commands for an active STA before the inline
disconnect indication at `sm_disconnect_process+0x72`. Nim queues
the commands one at a time and previously held its cleanup guard
through the host callback. A callback that pumped the scheduler
could consume the PS reply but could not start the next step.
After detaching the host indication, Nim now permits nested
cleanup progress during delivery; the outer service still checks
its original serial before continuing. Host link-down and IPv4
clear depend on the association owner, not continued existence
of its lower-MAC station slot. The normal manager callback does
not wait for cleanup and this does not establish the cause of
the spontaneous reason-7 event.

The resulting M0 image built and passed the UART-anchor dry run at
850,960 wrapped bytes, with its erase-rounded end at LP's start.
It was not flashed in this round. The earlier image remains in
service and its three outage records were still empty.

Pinned `me_task.o:mm_set_idle_cfm_handler+0x4c/+0x58` and
`mm_set_ps_mode_cfm_handler+0x4c/+0x58` send the ME confirmation before
entering idle. Nim previously entered idle first, moving saved ME work
ahead of the final SM cleanup reply. The host replay reproduces this
with a saved activation for another VIF. Nim now publishes the reply
first and rechecks the ME control generation before idling; a synchronous
host callback can reset and start a replacement exchange without losing it.

The `bl808WifiDiagLinkDrop` reconnect diagnostic adds a separate
nine-word `allcore_reconnect_failure` record without changing
`allcore_link_drop`. Read it with the running ELF. Word 0 is `RECN`
(`0x5245434e`), committed last; zero means no capture. The remaining words
are attempt, phase (1 disconnect, 2 scan, 3 join, 4 WPA, 5 DHCP,
6 link lost after lease), attempt start ms, elapsed ms, code, detail,
packed SM and recovery state (8/8/16 bits), and backend status/reason
(16/16 bits). In the scan phase, detail is 0 pending, 1 unavailable,
2 submission rejection, 3 timeout, or 4 confirmation. The code is the
raw return or confirmation status; confirmation with code zero and a
zero result count is an accepted empty scan. Vendor `scanu_confirm+0x6e`
stores an explicit status byte. The diagnostic records it before completing
the future, ignores forced attempts, and retains the first natural result.

### Warm STA DHCP Handoff

The pinned BL808 SDK lwIP path `netif_set_link_up → dhcp_network_changed`
immediately sends an INIT-REBOOT DHCP Request from a retained bound client.
The Nim host reports link-up on association, before the WPA keys are ready.
With real SDK lwIP and a fake link that rejects packets before WPA, the first
request is lost and the retry waits for two 500 ms fine-timer ticks. The
all-core manager now stops the old DHCP client at reconnect teardown and starts
a new one only after WPA completes. The real-lwIP fixture observes a Discover
on the first authorized send. A DHCP timeout is diagnostic: the manager keeps
polling a healthy association, accepts a late confirmed lease, and does not
restart the active client. The CPS fixture exercises the WPA gate, start
failure, and a lease arriving after the wait expires. In diagnostic phase 5,
detail 2 means DHCP start failed; details 0 and 1 describe WPA not ready or
still ready at the end of the wait.

Pinned `sm.o:sm_disconnect_process+0x46` clears
`sm_reconn_dominant_flag` after the SA Query timer clear and before cleanup.
Nim now clears it under the original disconnect handoff's ownership check.
`sm_delete_resources+0xd6` clears VIF offset `0x1e4` before the inline host
indication. Nim now clears that word before notifying the host, without
releasing its staged teardown or touching another VIF. The cleanup tests
verify both changes, including VIF replacement during timer cancellation.
Neither change identifies the source of the original spontaneous reason-7
disconnect.

The Ox64 diagnostic build used a 1 ms DHCP observation deadline and three
forced reconnects. Each reached WPA state 10, reported no lease at the
deadline, and published `192.168.1.114` on that same attempt. The first
and final JTAG reads together contain all three passes. HTTP status
returned the same IPv4 address after the final pass. The peer, link-drop
and natural reconnect records were empty at both reads. The UART anchor
verified the 851,920-byte M0-only image; the erase-rounded end was LP's
start and D0/LP were not rewritten. Artifacts are under
`build/hw-validation-allcore-wasm-http-reconnect-dhcp/`.

The normal-timeout image (851,216 bytes, M0 only) was then verified and
left running without forced reconnects. It joined Frog on the first
attempt, obtained the same lease, and returned 42 for HTTP WASM
`add(19,23)`. The M0, D0, LP, and enclave heartbeats advanced. The
startup snapshot still had no natural-drop evidence. Artifacts are under
`build/hw-validation-allcore-wasm-http-reconnect-dhcp-service/`.

### Cold STA DHCP Handoff

Pinned `sm.o:sm_connect_ind+0x10a` sends the firmware association
indication, not an IPv4 lease notification. The pinned SDK's
`wifi_netif_dhcp_start` guards duplicate starts, and the manager stops
DHCP on disconnect both before and after getting an IP. The raw lwIP
`dhcp_start` resets an existing client. On the old cold-start path,
each observation timeout restarted the client, and the separate
relink path discarded the WPA wait result before trying DHCP again.
The cold path now uses the same scan, join and WPA gate for each
association and keeps one DHCP exchange active across its three
observation windows before relinking.

The debug receive tap's `yiaddr` is not lease authority. The old
timeout fallback assigned it directly with a guessed /24 and .1
gateway. The manager now requires `dhcp_supplied_address`, a nonzero
IPv4 address, and current WPA readiness before serving; the tap stays
diagnostic only. The CPS tests cover WPA loss, start-allocation retry,
late leases and clock wrap. The pinned-lwIP replay shows that an Offer
and an ACK for a different transaction cannot bind the address. A
matching ACK installs the offered lease, /25 mask and router with
last octet 126.

The UART anchor verified the 849,936-byte M0-only image, with the erase
range ending at LP's start. The Ox64 joined Frog on its first attempt.
Its trace shows WPA state 10 before DHCP start, the lwIP receive code
`0x85` for ACK, and then publication of `192.168.1.114`. HTTP WASM
`add(19,23)` returned 42, and M0, D0, LP and the enclave reported OK.
The cold timeout/relink branches were exercised on the host, not forced
on the radio. Natural-drop diagnostics were empty; this image remains
in service. Artifacts are under
`build/hw-validation-allcore-wasm-http-boot-dhcp/`.

### Live IPv4 Lease Publication

Pinned SDK lwIP retains a valid lease during renewal, but a DHCP NAK or
expiration clears the netif address and runs discovery again without
requiring an 802.11 link transition. The manager previously kept its
last published IP until another Wi-Fi reconnect. It now follows the
confirmed netif address throughout the DHCP client's lifetime. Loss
of a lease clears the published IP without forcing a healthy radio
to reassociate. A changed address is announced and checked again before
publication. The host tests cover the real lwIP NAK, replacement lease
and T0 expiry, and withdrawal during the manager's announcement. The
wildcard TCP listener stays bound across those address changes.

### STA Activation Clock Samples

Pinned `mm_task.o:mm_hw_config_handler` uses separate MAC timer loads
for TBTT, `psLastTime`, and `beaconTimeoutBase` at object offsets
`0xae2`, `0xb24`, and `0xb40`. It also reloads the station interval at
`0xaf8` after arming TBTT. Nim no longer reuses the earlier values;
the additional clock load is followed by the same activation ownership
check as the other platform reads. A focused native replay fails on
the old two-read branch, then verifies all three timing values, the
interval reload, and replacement during the power-save timestamp read.
This difference affects initial timing, but is not proof of a reason-7
disconnect.

The 850,880-byte combined bench image was verified through the M0 UART
anchor without rewriting either peer. Two forced reconnects each
reached WPA state 10, reported no lease at the 1 ms diagnostic timeout,
then published `192.168.1.114` on the same attempt. The final receive
code was DHCP ACK (`0x85`), HTTP answered, and the natural-drop
records were empty. This is an association and DHCP smoke test, not
an on-air NAK, lease-expiry, or power-save timing measurement.
Artifacts are under
`build/hw-validation-allcore-wasm-http-lease-refresh-forced/`.
The 850,176-byte normal image was then verified and left running with
forced reconnects disabled. It joined Frog on the first attempt, received
a DHCP ACK for `192.168.1.114`, reported M0, D0, LP and the enclave OK,
and returned 42 from HTTP WASM `add(19,23)`. The startup records contained
no natural drop. See `build/hw-validation-allcore-wasm-http-lease-refresh/`.

### Wi-Fi Timer Polling And Peer Evidence

Pinned `arch_main.o:wifi_main+0x1e8` calls `ke_evt_schedule`; the
dispatcher selects a posted event before entering a handler. The 50 us
lookahead in `mm_timer.o:mm_timer_schedule+0x5a` and
`ke_timer.o:ke_timer_schedule` is used inside those handlers. Nim's
unposted polling fallback used the same lookahead as an admission
condition. As a result, a watchdog could run while its deadline was
still 25 us away, before a queued Beacon could take the
`mm.o:mm_check_beacon+0x25e` timer-clear path.

The pure Nim fallbacks now require an arrived deadline; dispatched
handlers retain their existing lookahead and bounded drain behavior.
The native replay runs the real service step, event dispatcher and
MM timer against a fake clock. An RX adapter performs the admitted
Beacon's watchdog clear. It reproduces the old delivery before RX,
then verifies cancellation, exact-deadline fallback without an IRQ,
posted timer handling, and wrap. It is not an RF timing test.

The manager's aggregate RX counter is only a whole-path fallback,
not a witness that the associated BSS is active. To distinguish the
two, the Nim diagnostic image samples the unique active STA and its
associated peer roughly every 250 ms while WPA is ready. The eight
words at `allcore_sta_rx_evidence` are a valid/index word (bit 31
valid, VIF and station in bytes 0 and 1), uptime ms, aggregate RX frame
count, admitted peer Beacon count, last Beacon MAC clock in us,
sample MAC clock in us, beacon/probe evidence epoch, and missed-beacon
probe count. The record is invalidated when starting a replacement
connection. The first natural drop record appends the latest
sample after its original 14 words, with the same validity bit.
The two clocks in the sample are
32-bit and their difference wraps. The sample doesn't drive recovery.

The Ox64 UART anchor verified the 850,896-byte M0-only image at
`0x010000`, with the erase range ending at LP's start. The startup
connected-scan check returned to Frog without changing its WPA
or DHCP state; HTTP stayed at `192.168.1.114` and WASM
`add(19,23)` returned 42. Two no-reset samples 16,467 ms apart
moved aggregate RX from 424 to 838 and admitted STA Beacons from
136 to 294. The missed-probe count was zero at both sample points,
and natural-drop records were empty. The image remains in service
without forced reconnects. See
`build/hw-validation-allcore-wasm-http-beacon-poll-deadline/`.

### Wi-Fi Event Priority With Timer Fallback

Pinned `ke_event.o:ke_evt_schedule+0x14` selects the highest set bit
through `__clzsi2`. Its table starts with reset, MM timer, KE timer,
and IPC. The pure Nim service loop previously called both due timer
handlers directly before selecting a posted event, and tried KE
before MM. Now it selects one event through the same table, considering
an arrived polling deadline at its normal priority. A polling fallback
is local to that selection and does not leave a synthetic IRQ bit set
after the chosen handler changes the queue. The native replay reproduced
both timers running before a posted reset, then verified reset first,
MM before KE, ordinary posted delivery, and a lower timer rearmed during
the higher timer's callback.

The timeout notification ABI is still the zero-length indication
published by the archive at `ke_timer.o:ke_timer_schedule+0x7c`.
The Nim timer additionally tracks the original exchange and timer
serial privately. The reference handler can use the current state
at `sm_task.o:0x410` and count an old queued auth timeout against
association at `0x432`. The replay dispatches the high-priority KE
timer while an authentication success is queued; the resulting
timeout stays behind the success in the FIFO. Nim ignores that old
timeout and spends one retry only when the new association timer
expires. This intentional ownership difference is not a claim about
the spontaneous reason-7 disconnect.

The UART anchor verified the 850,896-byte M0-only image without touching
LP or D0. Ox64 reached WPA state 10, received a DHCP ACK, and passed the
startup connected-scan return check with `192.168.1.114` unchanged.
HTTP WASM `add(19,23)` returned 42 and all core/enclave statuses were OK.
No natural drop was captured. The image remains running without forced
reconnects. Artifacts are under
`build/hw-validation-allcore-wasm-http-event-priority/`.

### Reset Priority And Power-Save Request Replay

The pinned `bl.o:bl_reset_evt` clears the reset event at object offset
`0x504`, then calls MAC, RX, TX, MM, and VIF recovery. The vendor event
table selects reset before timers and task messages. Nim now also gives
it precedence over local station service callbacks, including a reset
posted between two callbacks. A missing message-event bit is recovered
at the ordinary task-message priority rather than by making a second
direct call after a higher-priority event. Replays check a reset that
needs another attempt, work resuming after reset, and a recovered
message competing with RX.

The pinned `mm_task.o` power-save request handler calls `ps_set_mode`
at object offset `0x5fe` and consumes the command. Nim intentionally
retains the request so it can publish an owned confirmation. After a
TX reset increments its epoch, the previous null-frame callback cannot
complete that request. Previously this could leave the retained owner
blocking later MM power-save requests even after successful reset.
Now recovery clears the retired retry state and returns the original
command to the head of the sent queue, keeping the existing response
ownership. A failed reset does not replay it or emit success. After a
forced-idle reset, MM saves the replay until it hands the MAC back.
Native fixtures verify old-completion rejection, original request order,
later request progress, and one confirmation per completed command.

The UART anchor verified the 851,280-byte M0-only image with the
erase range ending at LP's start. On Ox64, WPA completed, DHCP ACKed
`192.168.1.114`, the startup connected scan returned home, and HTTP
WASM `add(19,23)` returned 42. All three cores and the enclave reported OK.
The reset and request-replay interleavings were exercised on the host,
not forced on the radio. No natural drop was recorded before the flash
or in the new startup read. See
`build/hw-validation-allcore-wasm-http-reset-priority/`.

### Power-Save Completion Ownership

Pinned `ps.o:ps_set_mode` increments the null-frame confirmation count
at object offsets `0x45e..0x468`, submits the frame at `0x47e`, and
decrements it for a local rejection at `0x486..0x490`. The Nim TX path
can complete the frame inline. Keep one count reserved until the VIF
walk finishes so only the last real confirmation or the end of the
walk can finish the mode change. A replaced request or reset invalidates
the old walk before it can change the replacement's count.

Pinned `ps.o:ps_enable_cfm_handle` calls the U-APSD logger at `0x68e`,
clears the global transition bits at `0x6a8..0x6aa`, and replays a
deferred mode at `0x6d8..0x6fc`. Retiring the VIF during a timer or
logging callback prevents writes to that VIF, but no longer skips the
global transition and deferred replay. Reset or replacement of the
global request still invalidates the old confirmation. Native regressions
reproduce both the duplicate completion and the missing replay before
the fix, then check the reset and replacement boundaries.

The UART anchor verified the 851,664-byte M0-only image. Ox64 reached
WPA state 10 on both startup attempts. The first attempt did not
establish a DHCP lease before the relink; the second received a DHCP
ACK for `192.168.1.114`. The connected scan returned home with that
lease, HTTP WASM `add(19,23)` returned 42, and M0, D0, LP, and the
enclave reported OK. The callback interleavings were tested on the host,
not forced on the board. No natural disconnect was captured in the new
startup read. See `build/hw-validation-allcore-wasm-http-ps-completion/`.

### Dynamic Power-Save Batch And Boot DHCP Evidence

Pinned `ps.o:ps_dpsm_update` sends the sleep null frame at `0x8d6`, stores
the VIF and arms its timer at `0x8e2..0x8f4`, and checks the total count
at `0x84c..0x850` after walking the VIFs. `ps_enable_cfm` clears the
timer at `0x790`. Nim can deliver a TX callback during submission, so
the dynamic walk now holds one count until admission ends, then arms a
single timer only when real confirmations remain. A non-final sleep
confirmation leaves that timer in place. Reset invalidates the walk, and
an MM command newly deferred by a callback does not invalidate the
dynamic transition. Host replays cover all inline/delayed combinations
for two VIFs, reset during both sleep and wake submission, and first
admission of a deferred MM command during completion.

`allcore_boot_dhcp_miss` preserves the first failed boot lease attempt
before DHCP stop or relink. Word 0 commits the current record format
(`0x44484332`). Word 1 packs start success (bit 0), backend connected
(bit 1), netif flags (bits 8..15), supplicant state (bits 16..23), and
the low byte of MAC SM state (bits 24..31), at the end of the attempt.
Words 2..10 hold Wi-Fi DHCP TX count, last TX metadata, hardware ACK
count, TX failure count, pre-lwIP DHCP RX count, lwIP callback count,
Offer count, last receive code, and lwIP message creation count. These
counters are cumulative since boot. A retry cannot overwrite the record.

On the first 851,776-byte image, the older `0x44484350` record packed
the combined WPA-ready predicate in bit 1. It showed one Discover and
one hardware ACK (`0x80800301` in the completion ring), zero DHCP RX at
both taps, and WPA readiness false while netif flags were still `0x2f`.
The retry received a DHCP ACK for `192.168.1.114`; the connected scan,
three cores and enclave passed, and HTTP WASM `add(19,23)` returned 42.
This boot retry was not caused by failure to transmit that Discover.
An 802.11 ACK does not prove that the AP decrypted or forwarded it.
See `build/hw-validation-allcore-wasm-http-dpsm-timer/`.

The 851,840-byte state-capture image received a DHCP ACK on the first
association after both the flash and a reboot-only run. The connected
scan passed both times and the miss record remained empty. The separate
supplicant/backend states at failure remain unobserved. The firmware
was left running without forced reconnects. See
`build/hw-validation-allcore-wasm-http-dpsm-dhcp-stage/`.

### DHCP During Key Exchange And TX-Null Timeout Ownership

The pinned supplicant enters states 7 and 8 during pairwise exchange and
state 9 during group exchange. In the state-capture M0 ELF, radare2 shows
the state-8 store in `wpa_supplicant_process_3_of_4+0x12`. These states
are not by themselves an association loss. The all-core DHCP wait now
keeps polling the already-started client within its original time budget
while the backend remains connected and WPA is exchanging keys. It still
requires state 10 to return a lease and stops on a genuine disconnect or
a non-key state. Host replays cover a lease arriving mid-exchange, no
publication before completion, expiry, and loss of association. This
does not establish which signal changed on the earlier failed board boot.

Pinned `ps.o:ps_tx_null_timer_handle` zeros the count at object offset
`0x728`, finalizes disable or enable at `0x734` or `0x74e`, and tail
calls the AC3 clear at `0x742`. Nim intentionally clears AC3 before
completion so a failed DMA halt cannot seal the request. Because the
clear can synchronously deliver TX callbacks, Nim now rejects a stale
completion or count restoration when the reset epoch or PS transition
serial changed during the handler. The host replay exercises both
reset and replacement during the flush, in addition to the unchanged
halt failure and inline completion paths. This guard does not change
how an already-armed timer identifies its original VIF.

The 851,968-byte wrapped image exactly filled the M0 slot; the UART
anchor verified it without touching LP or D0. Ox64 acquired
`192.168.1.114` on the first association, passed the connected scan,
and returned 42 for HTTP WASM `add(19,23)`. All cores and the enclave
reported OK. The miss and drop records were empty; neither callback
interleaving nor a mid-DHCP key exchange was forced on the device.
See `build/hw-validation-allcore-wasm-http-key-exchange/`.

### TX-Null Arm And Drain Ownership

The pinned `ps.o` timer zeros the pending count at `0x728`; the timer
argument comes from the environment word populated at `0x8e2`. Nim now
also records the PS transition serial and TX reset epoch when arming the
timer, and captures the VIF/station identity before the callback-bearing
submission. A superseded arm or a canceled MM timer delivery cannot
flush AC3 or take the replacement's count. On successful drain, a
retired VIF cannot receive peer-specific work; the still-current global
DPSM transition completes and can replay a deferred MM request.

Pinned enable and disable TX callbacks reach the no-ACK helper ahead of
their zero-count branches (`0x780` and `0x5be`, respectively), and that
helper tests the count at `0x2b8` after its retry side effects. Nim
intentionally drains AC3 before finalizing and now tests for an empty
count before the helper as well. A retired callback cannot change the
retry counter, signal PM or connection loss, or schedule another frame.
Live retry and last-completion paths still use the same count rules.
Host checks cover stale arms, canceled dispatch, same-address VIF reuse,
failed halt, and TX callbacks with and without a hardware confirmation.

The 851,472-byte M0-only image fit after omitting boot-only TZC register
prints from the lean connected-scan profile. UART-anchor flash verified
without touching LP or D0. The Ox64 obtained `192.168.1.114` on the
first association and passed the connected scan, all-core/enclave
checks, and HTTP WASM `add(19,23) = 42`. The boot DHCP miss and link
drop records were empty. The stale timer and drain interleavings were
host replays, not forced on the target. See
`build/hw-validation-allcore-wasm-http-ps-timer-owner/`.

### Wake Completion And Confirmation Ownership

Pinned `ps.o:ps_disable_cfm_handle` clears the U-APSD timer at `0x4ce`,
commits the global wake flags at `0x4fc`, posts PM at `0x500`, hands the
low byte of its result to the VIF's traffic detector at `0x512`, and
then runs optional peer work before replaying a deferred mode at
`0x56a..0x586`. The return value of one suppresses the caller's normal
TD rearm; it does not prove that the confirmation armed a timer.

Nim now preserves global wake and deferred-command progress if a callback
retires only the VIF. It skips stale peer work and reports a TD handoff
only for a current peer. Reset or a new global mode still invalidates the
whole continuation. The fixture retires or replaces ownership during
the timer clear, PM hook, TD handoff, and event publication, and checks
that an explicit request confirms once and a newly deferred request
keeps its requester.

Pinned `ps_disable_cfm` and `ps_enable_cfm` call the retry helper at
function offset `+0x5e` and clear the TX-null timer at `+0x36`. In Nim,
those calls can synchronously replace the PS transition without changing
the frame's VIF or station identity. Both callbacks now recheck the PS
serial and reset epoch as well as the TX frame session before decrementing
after retry and before finalizing after timer clear. The TX completion
fixture reproduces both boundaries on the same VIF.

The 851,664-byte M0-only image verified through the UART anchor. Ox64
obtained `192.168.1.114` on the first association; the DHCP TX completion
ring contained three retry-exhausted reports interleaved with three ACKs.
The connected scan and all core/enclave checks passed, and HTTP WASM
`add(19,23)` returned 42. No DHCP miss or link drop was recorded in
the post-boot snapshot. The callback interleavings were not forced on
hardware. See `build/hw-validation-allcore-wasm-http-ps-wake-owner/`.

### Power-Save Command Cancellation

Pinned `mm_task.o` calls `ps_set_mode` at `0x5fe` and consumes the
message. `ps.o:ps_set_mode` sets the deferred bit and saves the mode at
`0x384..0x38c` before returning without TX. Nim instead retains the MM
command so its reply stays owned. Canceling only that command now detaches
it and clears the deferred replay bit before freeing it, without changing
the active dynamic transition, count, or timer. Canceling an active
explicit command invalidates its generation and outstanding count.
The dynamic finalizers track their transition independently of the
parked command, so arrival or cancellation of that command cannot stop
global wake/sleep completion. The explicit enable finalizer now publishes
its global confirmation even when a VIF retires during U-APSD setup or
logging, without updating that VIF. The host fixtures cover both cancel
paths, cancellation during dynamic completion, and VIF-only retirement.

This invalidates in-flight continuations that already captured the PS
generation, not null descriptors whose callbacks have not started. Those
descriptors still need the generation stamped on submission to reject a
late completion on the same peer after a new explicit command begins.

The earlier wake-owner boot's companion TX metadata was still present
before this flash. It paired each of the three retry-exhausted DHCP
submissions with a successful repush numbered 1. The newest rate words
cannot be attributed to those older individual attempts. See
`build/hw-validation-allcore-wasm-http-ps-wake-owner/pre-cancel-with-meta/`.

The 851,664-byte M0-only cancellation image verified through the UART
anchor. It obtained `192.168.1.114` on the first association, with three
successful DHCP submissions and no host repush. The connected scan and
all core/enclave checks passed; HTTP WASM `add(19,23)` returned 42. The
boot miss and disconnect records were empty. Cancellation interleavings
were verified on the host, not forced on Ox64. See
`build/hw-validation-allcore-wasm-http-ps-cancel/`.

### Power-Save Null Frame Lease Identity

Pinned `txl_frame.o:txl_frame_send_null_frame` calls the pool allocator
at `0x5f4`, updates TX power at `0x618`, and stores the callback and
argument verbatim at descriptor offsets 208 and 212 (`0x692..0x696`).
`txl_frame_evt` loads those same fields at `0x584` and `0x58c` before
the callback at `0x592`. Pinned `ps.o` uses that callback interface
for explicit mode changes, dynamic sleep, and no-ACK retries.

Nim preserves the descriptor and callback ABI. A null carrying a PS
completion now records the PS serial in its private lease, using the
value from before allocation because pool recovery may run callbacks.
Preparation and queue-admission checks reject a retired serial; delayed
completion and release still settle TX accounting and reclaim the slot
without retrying or altering a replacement's PS state. Non-PS null
frames are not tagged. Host tests cover mode replacement in allocation
recovery, TX power and pointer-repair trace hooks, plus delayed delivery
through the confirmation queue and explicit release on the same peer.

For DHCP retry attribution, the existing IPv4-wide rate dump is not
enough. A future bench record should pair the descriptor's raw rate
words, MAC retry budget, completion status and host repush ordinal in a
single row, before the TX wrapper can be requeued or reused.

The 851,728-byte M0-only image verified through the UART anchor. The
Ox64 obtained `192.168.1.114` on the first association, with three
acknowledged DHCP submissions and no host repush. The connected scan,
all core/enclave checks, and HTTP WASM `add(19,23) = 42` passed. The
DHCP miss and link-drop records were empty. The PS replacement paths
were host replays, not forced on hardware. See
`build/hw-validation-allcore-wasm-http-ps-frame-owner/`.

### DHCP TX Policy Per Completion

Pinned `txl_cntrl.o:txl_payload_handle_backup+0xf6..+0xfa` points the
hardware descriptor at the packet's inline rate table. This pointer
survives normal completion even if `bufDesc` has been cleared. With
`bl808WifiDiagDhcpTxAttempts`, the host DHCP logger snapshots that table
from the still-owned IPC wrapper before the host can requeue the buffer.
It checks the matching host ID and status address, known inline hardware
and confirmation pointers, and both descriptor magics. Only bounded,
unfragmented IPv4 UDP client traffic on ports 68 to 67 is recorded.

`nimfw_dbg_dhcp_cfm_policy_log` has eight rows of eight `uint32` words:
four physical rate words, the policy word, PHY control, ACK control,
and the hardware confirmation word. Read each row with the existing
published status and metadata rings. Metadata bit 17 marks a valid
policy sample; bits 24..31 are the host repush ordinal. The row is
written before advancing the shared sequence. Software rejects and
unavailable policies have zero rows and a clear validity bit. The old
IPv4-wide rate snapshots remain in builds without this define.

Pinned `me_tx_cfm_singleton+0x8..+0x18` extracts the retry count from
bits 15..8; `txu_cntrl_cfm+0x8` sets bit 0 before host publication. Use
the raw word for RTS retry evidence. Only infer four attempts per slot
when the captured normal-ACK, eight-attempt policy and completion flags
match the validated firmware accounting profile. PHY control is not a
numeric retry cap, and a configured rate may never have been used.

The 851,472-byte M0-only image verified through the UART anchor. Both
the flash boot and a reboot-only repeat obtained `192.168.1.114` on the
first association and passed the connected scan, all core/enclave checks,
and HTTP WASM `add(19,23) = 42`. The trace captured six and five valid
DHCP submissions, respectively; all were MAC-ACKed without a host repush.
The outgoing message histograms were five Discovers / one Request and
three Discovers / two Requests. In both boots the first submission used
physical slots `0x80001207` and `0x80000400` with policy `0xffff0704` and
ACK control `0x2200`: the raw counts indicate four HT20 MCS7 short-GI
attempts followed by three or two 1 Mb/s CCK attempts, respectively.
These are firmware-accounted attempts, not an airtime measurement. Raw
and published status agreed apart from publication bit 0 in all eleven
rows. Both miss/drop records were empty. Repeated DHCP messages despite
MAC ACKs warrant matching outbound transactions to RX and lwIP acceptance;
the TX trace alone cannot distinguish AP forwarding from receive loss.
See `build/hw-validation-allcore-wasm-http-dhcp-attempt/`.

### DHCP Transaction Correlation

The pinned SDK rebuild (`b773b3f`, `bl_utils-short.o:tcpip_stack_input`)
selects the netif from the station's VIF and calls its input callback at
function offset `+0x474`. It does not route DHCP separately. The Nim
trace observes the owned Ethernet copy just before the final netif/lease
check; it does not change that decision, the pbuf layout, or ownership.
It reads at most 384 bytes across pbuf segments and derives the DHCP
offset from IPv4 IHL and the UDP length. It keeps no frame contents.

Under `bl808WifiDiagDhcpTxAttempts`, TX metadata bits 18..21 hold the
DHCP type, bit 22 marks a valid XID, and `nimfw_dbg_dhcp_cfm_xid_log`
holds the full XID in the same slots as status and policy. RX uses the
eight-slot `nimfw_dbg_dhcp_rx_trace_log`, published by
`nimfw_dbg_dhcp_rx_trace_count`. Each row is five words: XID, tag,
lwIP callback count delta, receive code, receive metadata. Tag bits
0..7 are type, bit 8 marks XID validity, bits 9..10 are delivery
(0 callback returned OK, 1 rejected, 2 stale before callback), and bit
11 marks a single receive-counter sample. Type zero means unknown.
The optional profile replaces the legacy first-segment RX details and
IPv4-wide TX descriptor dumps to fit the M0 flash slot.

The RX outcome uses the instrumented pinned SDK lwIP `dhcp.c` counters.
For a fresh SDK at `b773b3f4bf6154125304a328c72bf2aa7168a715`, apply
the trace and policy patches from the firmware repository root:

```sh
git -C build/bl_iot_sdk_b773b3f apply --check "$PWD/tools/bl808_lwip_dhcp_trace.patch"
git -C build/bl_iot_sdk_b773b3f apply "$PWD/tools/bl808_lwip_dhcp_trace.patch"
git -C build/bl_iot_sdk_b773b3f apply --check "$PWD/tools/bl808_lwip_dhcp_policy.patch"
git -C build/bl_iot_sdk_b773b3f apply "$PWD/tools/bl808_lwip_dhcp_policy.patch"
```

For the synchronous STA input, no increase means the DHCP callback was
not observed, even when netif input returned OK. A delta greater than
one is ambiguous. `0x82` is an OFFER received in SELECTING, `0x85` is
an XID-matched, parsed ACK before the state check, and `0x86` is an
eligible NAK. None proves the lease was installed; verify the assigned
IPv4 address separately. Retries and a selecting REQUEST can retain
the same XID, so the XID identifies a transaction, not an attempt.

The 851,216-byte M0 image was flashed through the UART anchor at
`0x10000`, leaving the LP and D0 images untouched. The flash boot
recorded two MAC-ACKed DISCOVERs and one REQUEST for `0xabcd0001`,
and one OFFER and ACK reached lwIP for that XID. On the reboot-only
repeat, `0xabcd0001` got an OFFER followed by a matching NAK in
REQUESTING state. lwIP restarted DHCP. For `0xabcd0002`, the first two
submissions of the next DISCOVER exhausted hardware retries, the
second host repush was MAC-ACKed, and lwIP received the OFFER and ACK.
Both boots acquired `192.168.1.114` on the first WPA association,
passed connected scan and the core/enclave checks, and served HTTP
WASM `add(19,23) = 42`. Neither boot recorded a link drop or DHCP
timeout. See `build/hw-validation-allcore-wasm-http-dhcp-correlation/`,
including `boot1` and `boot2` for the no-reset snapshots.

The linked DHCP translation unit initializes `xid.0` to `0xabcd0000`
and increments it for new transactions. Reusing an XID for a retry is
permitted; starting every boot from the same fixed seed does not meet
the collision-minimizing guidance in RFC 2131 sections 4.1 and 4.4.1.
The observed NAK shows the first REQUEST was refused, but these traces
do not establish why it was refused, or link it to the original WPA
disconnect. AP/server logs or a joined radio-side capture would be
needed to distinguish a server decision from delivery losses on other
attempts.

### DHCP Transaction ID Seed

In the unseeded BL808 HTTP image, radare2 shows the load, increment,
and store of `xid.0` in `dhcp_create_msg+0x62..+0x68`; its linked
initial value is `0xabcd0000`. The Nim real-lwIP build now compiles
that SDK translation unit through `lwip_wifi_smoke/dhcp_seeded.c`.
It uses the SDK's `DHCP_GLOBAL_XID` once-per-boot hook, backed by
`os_get_random` on the BL808 TRNG. On a failed entropy read, it mixes
the device's MAC and machine timer instead of using a fleet-wide
constant. This fallback is for DHCP collision avoidance, not secrets.
The build does not set `LWIP_RAND` for TCP or other protocols. New DHCP
transactions still advance the seed, and the selecting REQUEST and
retransmissions retain the transaction ID. In the optional DHCP trace
profile `nimfw_dbg_dhcp_xid_seed_source` records 1 for hardware RNG or
2 for the MAC/timer fallback.

The 851,408-byte M0-only seed image was UART-anchor flashed and then
rebooted without a second write. Both boots recorded source 1 and
different initial transaction IDs (`0x48fa9ae5`, `0x0c00c7b7`). Each
kept its XID through both DISCOVERs and the selecting REQUEST, and lwIP
received a matching OFFER and ACK. The reboot's first DISCOVER hit the
MAC retry limit and the first host repush was ACKed with the same XID.
Both boots acquired `192.168.1.114`, passed connected scan and all
core/enclave checks, and returned 42 from the WASM HTTP call. Neither
recorded a DHCP NAK, lease timeout or link drop. This verifies seeding
and retry continuity, not the cause of the previous NAK. See
`build/hw-validation-allcore-wasm-http-dhcp-seeded/boot1` and `boot2`.

These first-association boots did not exercise DHCP teardown or timer
restart at station disconnect.

### DHCP Retirement On Station Loss

Pinned `wifi_mgmr.o` has calls to `wifi_netif_dhcp_stop`. In
`wifi_netif.o:wifi_netif_dhcp_stop+0x0..+0xe`, radare2 shows the
`dhcp_stop` callback passed to `netifapi_netif_common`. A real-lwIP
Nim station now retires that same DHCP client after invalidating its
peer and before publishing the disconnect callback. Failed association
that tears down an existing link also stops DHCP. Each remaining netif
operation rechecks its generation and binding, so a callback can
replace the association without the old indication clearing its netif.
The application still starts DHCP only after WPA completion. The
ordinary app recovery retains its own stop for no-indication failures.

The NO_SYS timeout shim removes a disabled cyclic timer immediately
and rearms it at a fresh full interval. The callback checks timer state
again before periodic rearm, and a stop/restart from within the callback
leaves exactly one fresh timer. Each switchable built-in cyclic timer
uses one reserved queue node; on-demand TCP and arbitrary application
`sys_timeout` callbacks still use the SDK pool. This lets DHCP
fine/coarse timers survive a failed timeout allocation without changing
the SDK ABI.

`bl808WifiBenchStationDhcpRetire` skips the app's stop only for forced
cycles and exports `allcore_station_dhcp_retire`: completed probe
count, flags, DHCP message creation count after disconnect, and count
just before the post-WPA DHCP start. Flags 0..2 mean successful
disconnect, no supplied lease and zero IPv4, and WPA ready. Bit 3 is
sticky failure, including any pre-WPA increase in the create count.
This does not count a teardown RELEASE attempt inside `dhcp_stop`, or
prove what was on the air; it distinguishes a new-session DHCP request
created before WPA from ordinary DHCP after WPA.

The 851,664-byte M0 wrapper was UART-anchor flashed without erasing the
LP or D0 images. With two forced local disconnects, the probe returned
`[2, 7, 7, 7]` (all phase bits set, no sticky failure). Both re-joins
reached WPA state 10 and reacquired `192.168.1.114`. The trace shows one
matching OFFER/ACK pair for each of the three acquisitions, with a new
XID for each. After the second re-join the coarse timer node was queued
and the fine timer node was unqueued, matching the bound client state.
The live HTTP manager reported M0, D0, LP, and enclave OK and returned
42 for `add(19,23)`. The focused station and timer suites passed 32 and
14 cases respectively. See
`build/hw-validation-allcore-wasm-http-dhcp-retire/after-two-cycles/`.
Local forced cycles do not reproduce AP-initiated loss or a missing
station indication.

### DHCP Acquisition Backoff And NAK Retirement

Before the policy patch, radare2 shows two 500 ms ticks stored directly
as `request_timeout` in the linked pinned lwIP `dhcp_discover.isra.0`
at `+0xf6..+0xf8`, `dhcp_select.isra.0` at `+0x180..+0x182`, and
`dhcp_reboot.isra.0` at `+0x130..+0x132`. In the BL808 build the SDK
wrapper now calls the Nim backoff function at those three sites. The
nominal delays are 4, 8, 16, 32, and 64 seconds, with jitter selected
in 500 ms steps from the transaction ID, clock, attempt and phase. The
choice stays at or below 64 seconds. First transmissions, transaction
ID reuse, and renewal/rebinding are unchanged. See RFC 2131 section 4.1.

The pinned NAK handler previously cleared the interface address but
kept the old lease's coarse timers. It now clears those timers before
restarting DISCOVER, so an expiry or renewal from the rejected lease
cannot interrupt that replacement exchange. This does not explain
why any particular server sent a NAK. Both SDK patches applied to a
temporary index starting at the pinned revision reproduce the tested
DHCP translation unit exactly.

The deterministic real-lwIP fixture links the production Nim hook.
It drives the actual fine timer across successive retransmissions to
the cap, checks XID continuity and the selecting/INIT-REBOOT deadlines,
and injects a NAK one coarse tick before the old lease would expire.
The old deadline does not restart or retransmit discovery. All 15
selected TCP/DHCP timer cases passed, with the three changed DHCP cases
also passing with AddressSanitizer.

The 851,920-byte M0 wrapper was UART-anchor flashed at `0x010000`
without erasing LP or D0. Initial acquisition and two forced rejoins
each recorded one DISCOVER, OFFER, REQUEST and ACK with matching XID.
The station retirement probe ended at `[2, 7, 6, 6]`. The live HTTP
manager at `192.168.1.114` reported all three cores and the enclave OK
and returned 42 for `add(19,23)`. No DHCP retransmission, NAK, or natural
drop occurred in this run. The fake-clock fixture, not the device
run, exercises retry timing and a NAK adjacent to old lease expiry.
See `build/hw-validation-allcore-wasm-http-dhcp-policy/after-two-cycles/`.

### STA Keepalive And Supplicant Failure Ownership

Pinned `mm_task.o:mm_hw_config_handler` at object offsets `0xb40..0xb5c`
resets per-VIF beacon timing on activation, but not MM's shared
idle-probe miss budget. The completion handler restores that budget to
10 on ACK. Nim now also initializes it alongside the new association's
probe timestamp, after the activation ownership check. A host replay
starts with an exhausted budget, runs real MM activation, then sends
one no-ACK completion through the real probe callback. It leaves nine
misses in the budget and does not declare the new station lost.

Pinned `sm.o:sm_handle_supplicant_result+0x8a` transitions to
disconnecting and `+0x128` sets the TX callback. The callback at
`sm_supplicant_deauth_cfm+0x34` routes to `sm_connect_ind`, whose
entry loads and dereferences the pending connection at `+0xe/+0x24`.
Nim has no pending connection after publishing success, so that path
could instead do nothing and leave SM disconnecting. A nonzero result
on a current established peer now enters the owned local disconnect
path with the actual reason, without relying on a management TX after
the key failure. An initial association failure still uses the original
join-failure handling. The host replay verifies cleanup, stale/invalid
peer rejection, and replacement during state publication or timer
retirement. The real cleanup-queue fixture also reaches idle through all
four teardown stages and publishes one disconnect with status 8 and the
original reason, including when the result is repeated. The focused
host runs passed 33 cases.

The 851,904-byte M0-only image was UART-anchor flashed. Initial join and
both local reconnects reached DHCP and `192.168.1.114`; the retirement
probe read `[2, 7, 6, 6]`. All three cores and the enclave were healthy,
and WASM HTTP `add(19,23)` returned 42. JTAG read an idle-probe budget of
10 after the second reconnect, then one hardware-ACKed probe and budget
10 after the 30-second threshold (`0x80800200`, no rejected submissions).
The established-link supplicant failure and the earlier spontaneous
reason-7 drop were not exercised on the board. See
`build/hw-validation-allcore-wasm-http-station-owner/after-idle-probe/`.

### TX Descriptor Identity And PS Timing

The reference `txl_cntrl.o:txl_transmit_trigger` reads the pending
node's THD without testing an address prefix. The former Nim check
accepted the entire `0x22000000..0x220fffff` range but rejected CPU
pointers in the optional cached Wi-Fi layout. It now checks the linked
internal frame slots, host IPC descriptor members, and VIF beacon
slots exactly, without translating the pointer. The cached boot ELF
links its internal slots at `0x6204388c`, IPC storage at `0x62040fd8`,
and VIF table at `0x6203ef98`. This is a CPU pointer check, not a DMA
coherency or memory-map guarantee; that image was not run on Ox64.

Pinned `txl_cntrl.o:txl_cntrl_push` calls the backup drain at `+0x66`
before calling `ps_check_tx_frame` at `+0xb0`. Vendor `ps.o`
samples MAC TIMLO inside `ps_check_tx_frame` and writes VIF offset
100. Nim now passes the saved STA and TID after the drain, gated by
the original session epochs and independent of the descriptor. It
keeps traffic accounting, pending publication and the packet count
before the drain; synchronous completion can otherwise recycle the
descriptor first.

Host replays complete and recycle the same descriptor during the
drain while advancing the clock. The post-drain call uses the original
arguments only for the still-current peer; a mutation without that
gate fails on peer replacement. Separate tests check the exact slot
boundaries and the trigger's valid-node and invalid-address paths.
The selected TX and U-APSD/PS tests passed 27 and 36 cases respectively.

The uncached M0 wrapper was 851,968 bytes at `0x010000`, ending exactly
at the LP slot's start. The UART anchor verified the write and reboot.
The board got `192.168.1.114` on startup and after two local reconnects.
It served WASM HTTP `add(19,23) = 42`, and the subsequent idle probe was
MAC-ACKed (`0x80800000`). The invalid pending descriptor counter was
zero both after reconnect and after the probe. Power save was disabled
on this bench profile, so U-APSD timing was verified only in the host
replay. The natural link and peer-disconnect records were empty.
See `build/hw-validation-allcore-wasm-http-tx-ownership/after-idle-probe/`.

### U-APSD Service Budget And Trigger Lifetime

In the pinned `rxl_cntrl.o:rxl_cntrl_evt`, radare2 shows the local
postponed-frame drain at `+0x2fa`, subtraction from a finite service-period
budget at `+0x308`, and the remaining count written into the host traffic
indication at `+0x396`. Nim now hands off that remainder, preserving zero
as unlimited. The fixture checks a one-frame drain against a budget of
four, the unlimited case, and a second trigger during the same service
period.

Pinned `ps.o:ps_uapsd_timer_handle` clears its active byte when no eligible
STA is on-channel. Nim deliberately keeps the timer armed when a live
U-APSD STA is only temporarily off-channel, but sends no trigger until it
returns. Timer delivery and the active-byte update share the existing MM
timer cancellation rules, so a replaced delivery cannot overwrite the
new arm. Host regressions failed before the fixes, and the four focused
RX, U-APSD, PS dispatch, and MM timer suites passed 163 cases afterward.

The first all-core M0 wrapper was 128 bytes over its 851,968-byte slot.
Reusing the existing MM VIF-identity check and omitting the duplicate
startup URL on the compact diagnostic profile brought it to 851,648
bytes without dropping DHCP or link diagnostics. The erase boundary
was checked against LP at `0x0e0000` before the UART anchor verified and
rebooted the M0-only image. The board acquired `192.168.1.114` and
completed both local reconnects; the DHCP retirement probe was
`[2, 7, 6, 6]` and the invalid pending-TX counter was zero. See
`build/hw-validation-allcore-wasm-http-uapsd-compact-banner/settled/`.
Power save remains off on this profile, so the U-APSD paths still
need an on-air test. No spontaneous disconnect was seen in this run.

The opt-in `bl808WifiBenchStaUapsd` profile requests only the WMM voice
queue (TID 7), keeps the 3000 ms interval, and records submission, MAC
ACK, EOSP and off-channel counts separately. Startup configuration alone
installed the VIF bitmap `0x08` against an AP advertising `0x80`, but
power save remained disabled on the established WPA connection. Pinned
`sm_task.o:mm_set_vif_state_cfm+0x9e` likewise skips PS re-enable when the
initial controlled-port state is not open. The bench queues the existing
runtime PS command after the first DHCP lease and each local reconnect;
the production defaults are unchanged.

With the runtime command, the station enabled dynamic PS and completed
both reconnects, but it stayed awake with zero U-APSD trigger attempts.
The active TD deadline was `0x01d323b3` while MAC TIMLO had advanced to
`0x08b92f93`; the TD entry was absent from the MM timer list and its
traffic counters were growing. See
`build/hw-validation-allcore-wasm-http-uapsd-ps-enabled-post-lease/td-clock-proof/`.
Radare2 shows `ps_disable_cfm_handle+0x60` returning a handoff even when
the platform flag is zero, `td_cfm_set_timer+0x12` skipping the timer
arm on that flag, and `td_timer_end+0x114` skipping its periodic arm
on the handoff return. Nim now preserves an installed confirmation
deadline, but falls back to periodic sampling when no deadline was
installed for the same VIF. The regression reproduces the lost timer
and verifies the next idle notification; 48 focused host cases passed.

The fixed M0-only wrapper was 851,840 bytes and was flashed and verified
through the UART anchor. It acquired `192.168.1.114` and completed both
local reconnects (`[2, 7, 7, 7]` DHCP retirement probe). On the same
association after those cycles, two halted JTAG snapshots showed the TD
deadline advance from 65,736,213 to 81,377,720 MAC ticks with the TD entry
still on the MM timer list. The sampled TX counters were 3 and 17
instead of accumulating into the thousands. These snapshots establish
timer progress, not deadline jitter. All three cores and the enclave
were healthy; WASM HTTP `add(19,23)` returned 42. See
`build/hw-validation-allcore-wasm-http-uapsd-ps-enabled-td-rearm/`.
The station was awake and no U-APSD trigger or EOSP was recorded.

### U-APSD Trigger Access Category

Pinned `ps.o:ps_uapsd_timer_handle+0x86` checks whether the installed
bitmap is nonzero, but `+0xd0` always loads TID 7. The common QoS Null
builder also uses EDCA queue 3. A station without voice U-APSD can therefore
send a frame that the AP acknowledges without treating it as a trigger.
[IEEE Std 802.11-2012](https://mrncciew.com/wp-content/uploads/2014/10/ieee-802-11-2012.pdf)
10.2.1.6(d) calls for a trigger-enabled AC; 9.2.4.2 and Table 9-1 give
the UP-to-AC mapping. Nim now chooses from the installed VO, VI, BE,
and BK bits (TIDs 7, 4, 0, and 1, respectively), and its trigger builder
uses the matching EDCA queue. The push path rechecks the installed bit
after preparation callbacks. The ordinary QoS Null entry keeps the
existing VO queue, including AP-generated EOSP frames.

`AllcoreHttpGratuitousArpMs=0` suppresses periodic announcements only;
the lease announcement remains. With that single change and dynamic
PS still selected, the voice-only test completed both local reconnects
and recorded one QoS Null trigger and one MAC ACK but no EOSP. See
`build/hw-validation-allcore-wasm-http-uapsd-ps-enabled-quiet/quiet-soak/`.
The separate static bench can request BK only with
`WifiBenchStaUapsdQueues=4` and `AllcoreHttpBenchStaPsMode=1`.

The static BK-only M0 image completed WPA, DHCP, and both local
reconnects. Its VIF installed bitmap `0x01`, the prepared QoS Null
showed TID 1, and firmware recorded six trigger attempts, six MAC ACKs,
and six received EOSPs with no rejects. This verifies ordinary BK service
periods, not scan-end handling or delivery of non-U-APSD traffic. HTTP
connection attempts timed out with that profile despite the healthy
association and lease. See
`build/hw-validation-allcore-wasm-http-uapsd-ps-enabled-bk-compact-static/bk-after-cycles/`.

The normal profile was restored with the same firmware fixes and power save
off. Both local reconnects passed, and HTTP at `192.168.1.114` reported all
cores and the enclave healthy and returned 42 from `add(19,23)`. See
`build/hw-validation-allcore-wasm-http-uapsd-ps-enabled-normal-restore/normal-after-cycles/`.
The trigger and TX integration checks passed (82 selected plus 9 shared).

### RX Traffic Identifiers And Static Legacy Polling

The pinned `rxu_cntrl.o:rxu_cntrl_frame_handle+0xee` masks the QoS
TID with `0x07` before storing it. IEEE Std 802.11-2012 8.2.4.5.2,
Table 8-5 distinguishes EDCA user priorities 0--7 from traffic-stream
identifiers 8--15. Nim keeps the four-bit TID on raw upload and rejects
a traffic-stream ID in its EDCA-only associated receive path before
delivery, replay, or sequence handling. The checks cover raw upload and
three-/four-address, plain/protected data and distinct caches for ordinary
EDCA priorities. All 55 EDCA and decapsulation cases passed.

The pinned `ps_check_beacon+0xb4` notifies traffic detection on a
matching TIM but does not initiate a poll. In mode 1 the dynamic wake
callback is disabled; the `ps_check_frame+0x11a` poll can only continue
retrieval after a legacy frame has already arrived. IEEE Std 802.11-2012
10.2.1.8(b--d) describes polling after the matching TIM, and 9.2.4.2
specifies AC_BE for PS-Poll. Nim submits the initial legacy poll for a
current static-PS STA on its operating channel when that STA's AID is
indicated and at least one AC is not U-APSD enabled. It keeps the
existing dynamic wake path and only polls for the station's own AID,
not the multicast bit. The poll builder now queues on BE instead of
the reference's VO; its wire layout is unchanged. All 41 focused
power-save checks passed.

On the Ox64 with static mode 1 and only BK enabled for U-APSD, Frog
association, WPA, and DHCP succeeded, but HTTP requests from the wired
host still timed out. During those requests the station had 22 ACKs in 23
U-APSD trigger attempts, no queued legacy polls, and no inbound TCP/80
frames in the associated-RX probe. Four TIM samples (`05 04 01 03 00 00`)
had an empty unicast bitmap. The live VIF used STA slot 1, whose AID 3
matched the association response. These samples don't show that Frog ever
signaled a pending legacy frame during the failed HTTP attempts, so this
run did not exercise the new poll branch or identify the cause of the stall.

With station power save disabled and both changes retained, the same
board completed two forced reconnects to Frog and reacquired
`192.168.1.114`. Wired HTTP then reported M0, D0, LP, and enclave healthy
and returned `42` from `add(19,23)`. No peer link-drop or reconnect-failure
snapshot fired during this run; it did not reproduce the spontaneous drop.

### Power-Save Mode And Channel Ownership

Pinned `ps.o:ps_set_mode+0x62/+0xe8` writes the MAC PM bit at
`0x24B0004c`; `txl_frame.o:txl_frame_send_null_frame+0x64/+0x6a`
writes the software header as `0x0148` regardless of the requested mode.
The prepared header alone cannot establish the on-air PM value.
`chan_pre_switch_channel+0x12c` saves PM for scan/ROC and
`chan_ctxt_op_evt+0x11e` restores it. Nim now saves MM power-save
commands while that scan/ROC owns PM, rather than confirming a mode
whose register value can be overwritten at END. Existing MM channel
return or host-idle transitions requeue the command. An admitted
explicit mode now clears the prior dynamic awake flags in both PS
views before programming the MAC; the pinned enable path only ORs the
dynamic-enable flag, leaving old awake state behind. The host cases
cover modes 0--3, forced-idle and saved-queue release, reselecting a
mode from dynamic awake, and deferral while a dynamic transition owns PS.

Pinned `ps_uapsd_timer_handle+0x8e` calls `chan_is_on_channel`, which
accepts a scan/ROC with the same requester VIF. The timer sets the
pending bit at `+0xcc`, submits at `+0xd2`, and stamps activity at
`+0xde` without checking submission success. Nim uses the station's
operating context at dispatch and rechecks after TX power preparation.
For a rejected submission it rolls back only its own tentative bit
while the operation still owns the VIF, preserves earlier pending
state and unrelated flags, and leaves a retry deadline without stamping
activity. The host regressions reproduce both same-VIF reserved
contexts and a rejected send against the previous behavior.

The 851,968-byte normal M0 wrapper ends at LP's start (`0xE0000`,
exclusive). The UART anchor verified it without writing LP or D0.
With power save off, Ox64 joined Frog, obtained `192.168.1.114`, and
passed two forced reconnects (`[2, 7, 6, 6]` DHCP retirement probe).
Wired HTTP after the cycles reported M0, D0, LP, and enclave healthy
and returned `42` from `add(19,23)`. The separate static PS wrapper
also built and fit (851,856 bytes) but was not flashed. The new PS
interleavings were verified on the host, not over the air. Neither
the static HTTP stall nor a spontaneous disconnect was exercised on
this image. See `build/hw-validation-wifi-pm-dwell-and-uapsd/`.

### Peer Disconnect And Retired Cleanup

Pinned `ke_task.o:ke_task_schedule+0xe8` restores MIE before handler
dispatch at `+0x126`. `sm.o:sm_deauth_handler+0x1be` and
`sm_task.o:sm_sa_query_timeout_ind_handler+0x94` hand off status 7 and
the original peer reason without masking interrupts through teardown.
Nim now captures the VIF, station, connection, and reset owner under
the lock, restores the incoming IRQ state before logging, and carries
that owner into teardown instead of recapturing it by VIF address.
Only admitted cleanup publishes Disconnecting. Replacement during
unlock or logging neither changes the replacement nor sets that state.

Pinned `sm.o:sm_disconnect_process+0x38/+0x4a/+0x72` clears the SA
Query timer, starts cleanup, then publishes the indication. Nim now
detaches the old timer under the ownership lock before the allocator
callback can arm another timer under the same key. The detached timer
can still be freed with the dispatcher's IRQ state restored.

Pinned `sm_delete_resources+0xce` queues the ME deactivation;
`sm_task.o:me_set_active_cfm_handler+0x54` releases SM on confirmation.
Nim's separate epoch-cancellation path now releases its Disconnecting
state and saved requests when the VIF retires and no replacement owns
SM. Native regressions cover retirement with a PS command pending, a
replacement created during cancellation, both peer-disconnect paths,
and same-key timer replacement. The focused suite passed 400 cases.

The lean M0 image (851,840 bytes) was verified through the UART anchor
without writing boot2, partitions, LP, or D0. The first boot snapshot
showed WPA complete and a DHCP Offer followed by MAC-unacknowledged
Requests. DHCP recovered without reaching the boot-miss deadline and
obtained `192.168.1.114`. Both forced reconnects then passed
(`[2, 7, 10, 10]` DHCP retirement, two disconnect entries, two cleanups).
Wired HTTP reported all cores and the enclave healthy and returned `42`
from `add(19,23)`. No spontaneous drop was recorded. Peer callback and
VIF-retirement interleavings were host replays, not injected on air.
See `build/hw-validation-wifi-owned-peer-cleanup-lean/`.

The variant in the pinned `sm_task.o:sm_connect_abort_req_handler`
branches from `+0x6e` to its confirmation-only path when SM is
Disconnecting rather than calling `sm_handle_connection`. Nim cleanup
can report link-down before reaching Idle because it waits for owned
confirmations, including `MM_STA_DEL_CFM`. The public disconnect wrapper
now waits for that existing teardown instead of sending a connect-abort
or another disconnect. It also skips the command if cleanup finished
before the deferred issue. The completion still requires link-down and
SM Idle, or expires under the caller's timeout. This is host-verified
reconnect behavior, not an explanation for the original reason-7 event.

Pinned `arch_main.o:wifi_main` dispatches firmware events at `+0x1e8`
without testing the host link or public futures. In the merged Nim
host/firmware scheduler, the Wi-Fi pump skipped polling when the host
link was down and no future remained. A peer indication could therefore
strand its own cleanup. The pump now also runs while SM owns teardown.
The host replay uses the station and ME/MM handlers, fake MAC time, and
the production pump entry: a failed station delete parks until its
100 ms timer, retries exactly once after the hardware double recovers,
emits its confirmation, reaches Idle, and stops polling without a
second disconnect notification or a public waiter. The test fails on
the original pump guard.

The combined cleanup fixes passed 18 focused retry/admission checks and
linked in the all-core Wi-Fi/HTTP/WASM build. The UART anchor verified
the 851,952-byte M0-only update. On Ox64, the original join and both
forced reconnects each received a DHCP Offer and ACK; the retirement
probe was `[2, 7, 6, 6]`. The board served `192.168.1.114`, with all cores
and the enclave healthy, and `add(19,23)` returned 42. The peer-drop and
reconnect-failure markers were zero. The no-waiter key-delete timeout
was exercised on the host, not induced on the board. See
`build/hw-validation-wifi-peer-cleanup-poll/`.

Pinned `mm_task.o:mm_sta_del_req_handler+0xc/+0x1c` calls the
synchronous station delete then sends `MM_STA_DEL_CFM`. Nim parks
the same request on hardware timeout and retries at 100 ms. The timer
wakes all saved MM work; formerly, the resumed delete immediately polled
the still-busy MAC again. A saved delete now waits while the retry bit
still identifies its station generation. The retry callback clears the
bit before its owned attempt, so a successful deletion can still be
confirmed and release the waiting reconnect. The deterministic cleanup
model checks backoff, clock wrap, and a single terminal confirmation;
removing the guard reproduces the extra hardware attempt on the host.

The all-core example used two formatters for the same HTTP root body.
Reusing the existing append formatter in the fallback path preserved the
response and reduced the M0 wrapper from 852,016 to 851,408 bytes, leaving
560 bytes before the LP slot. The exact prebuilt write was dry-run,
verified through the UART anchor, and rebooted without touching boot2,
partition tables, LP, or D0. Both the fast `/` and fallback `/?formatter=1`
responses matched the previous image after normalizing live counters.
Boot and both forced reconnects each received a DHCP Offer and ACK;
the retirement probe was `[2, 7, 6, 6]`, and the board resumed serving
`192.168.1.114`. M0, D0, LP and the enclave reported healthy and
`add(19,23)` returned 42. No spontaneous disconnect or forced MAC
timeout occurred. See `build/hw-validation-wifi-station-delete-backoff-compact/`.

### Management RX Admission

Pinned `sm_task.o:rxu_mgt_ind_handler+0x7e/+0xc0/+0xf6` routes
SA Query, peer disconnect, and authentication restart. Pinned
`sm.o:sm_sa_query_handler+0x64/+0x92` submits a response or clears the
matching timer using live slot state. Nim already stamps RX messages
with the harvested station and VIF generations. The scheduler check
alone did not cover slot reuse before SM used the message. Nim now
rechecks the tag under the disconnect and SA Query admission locks,
and also checks it on the authentication restart branch. Connect
indication preparation inherits that lock without holding it through
scan removal or host delivery. A matching SA Query response detaches
the timer under the lock and restores the caller's IRQ state before
freeing it.

The host regression first admits a tagged message at the scheduler
boundary, then replaces the station or VIF without changing the
addresses or slot indices. The old disconnect, SA Query request, and
matching response do not affect the replacement. The focused RX and
SM suites passed, as did the IEEE 802.11-2012 SA Query response oracle.
The compact bench variant was build-checked at 851,760 bytes with
an exclusive erase end of `0xE0000`, unchanged boot/partition data,
and a UART-anchor dry run. It was not flashed. The previous image
remained on the Ox64, with wired HTTP and `add(19,23) = 42` and no
recorded spontaneous drop. See
`build/hw-validation-wifi-mgt-owner-admission-lean/`.

At this gate the scheduler still sent a basic SA Query timeout without
an attempt serial. The peer/VIF guard alone could not distinguish
queries on the same association. The follow-up below covers that case.

#### Receive Protection Verdict

Pinned `rxu_cntrl.o:rxu_mgt_frame_check+0x88` calls MFP policy before
publishing a management indication. The previous `PEER` record kept
Frame Control and the SM decision path but not the actual protection
verdict. The original reason-7 snapshot left the saved SA Query reason
at zero, which favors direct teardown if no reset intervened. It does
not prove the protection class of that frame or why the AP sent it.

With `bl808WifiDiagPeerRxAdmission` and `bl808WifiDiagLinkDrop`, the
private RX ownership metadata carries the verdict for deauth and
disassoc indications. Word 5, bits 16..23, of
`nimfw_dbg_peer_disconnect` records 0 unknown, 1 accepted without
PMF validation, 2 accepted by the pairwise CCMP hardware and management
replay checks, or 3 accepted by BIP MIC and replay checks. Bits 0..15
retain the query counters. An SA Query expiry records the initiating
frame's copied verdict. No receive policy or wire fields changed.

The same metadata now aligns its absolute address after the
12-byte RV32 message header, payload, and copy slack. Aligning only
the payload-relative offset could misalign the private tag.
Host checks cover both protection paths, descriptor reuse, station
retirement, the RV32 header offset, and the SM evidence copy.
The initial diagnostic build linked at 852,208 bytes, 240 over the M0
partition. Reading the verdict during the existing ownership check and
copying the contiguous TX rate snapshot groups preserved the evidence
and reduced the M0 wrapper to 851,952 bytes (16 bytes of headroom).
The snapshot words matched in a host check, and 34 focused tests passed.

The UART anchor verified and rebooted the M0-only image without writing
boot2, partition tables, LP, or D0. WPA and DHCP completed at boot and
after both forced reconnects. Wired HTTP at `192.168.1.114` reported
all cores and the enclave healthy and returned `42` for `add(19,23)`.
No spontaneous disconnect was recorded, so the verdict has not been
exercised over the air. The follow-up peer-cleanup image retained this
diagnostic. See `build/hw-validation-wifi-peer-rx-admission-fit/`.

### SA Query Timeout Ownership

Pinned `ke_timer.o:ke_timer_schedule+0x66/+0x7c` pops the timer and
sends a basic zero-length message. `sm_task.o:sm_sa_query_timeout_ind_handler`
retries at `+0x1c` or calls disconnect at `+0x94` using the live query.
Nim now stores the attempt serial in a private tail after the BL808
timer-entry prefix and carries it in a four-byte internal SM message.
The receiver checks the message source, destination, length, serial,
and wrapped deadline before claiming it. A fresh retry gets a new
serial. An exhausted attempt carries that serial through logging,
timer detachment, and cleanup admission. Allocator failure while
posting an expiry retires only the current query; it does not claim
peer nonresponse or disconnect a replacement. Timer guards are now
checked under the mutation lock before an old operation can remove an
existing entry. No over-the-air formats changed.

Host replays exercise production timer publication and dequeue across
a rearm, a delayed expiry after a valid response and same-link
replacement, same-link replacement in the logger or timer-free
callback, and expiry-message allocation failure. The combined focused
SA Query and timer/cleanup suites passed 259 cases.

The 851,504-byte M0 wrapper was verified through the UART anchor without
writing boot2, partitions, LP, or D0. With power save off, Ox64 obtained
`192.168.1.114` and passed both forced reconnects (`[2, 7, 6, 6]` DHCP
retirement and two disconnect cleanups). Wired HTTP reported all cores
and the enclave healthy and returned `42` from `add(19,23)`. No natural
drop was recorded. The same-link SA Query timeout races were host
replays, not exercised over the air. See
`build/hw-validation-wifi-sa-query-timeout-serial-lean/`.

#### Reset Boundaries

Pinned `bl.o:bl_reset_evt+0x16/+0x1e/+0x26/+0x2e/+0x36` resets
MAC, RX, TX, MM, and VIF state without calling `ke_flush`.
`ke_event.o:ke_flush+0x12/+0x26/+0x42` drains the sent, saved,
and timer queues before clearing events. Nim retires SA Query at entry
to kernel init, kernel flush, and full MAC recovery. New SA Query work
cannot start during those calls, including inside nested callbacks.
Successful recovery removes the retired timer; a timeout from an
earlier attempt cannot act after failed recovery either. Ordinary
channel forced-idle does not retire a live query.

Both the typed SA Query expiry and ordinary kernel timer expiry
recheck ownership before enqueueing if message allocation crosses a
flush. An SA Query response cancels its local TX build if a flush
occurs during preparation. Host replays cover the stale publications,
successful and failed recovery, nested flush, and a same-ID timer
armed again after flush. These are implementation lifetime invariants,
not IEEE timing requirements or evidence of the spontaneous Frog drop.

The focused replays passed, and the bounded CI model run
(`--seed 808 --steps 256`) passed without skips. On Ox64,
the UART anchor verified the 851,824-byte M0 image without writing boot2,
partition tables, LP, or D0. With power save off, the boot and both
forced reconnects received DHCP Offer/ACK pairs. The board regained
`192.168.1.114`, and wired HTTP reached M0, D0, LP, and the enclave
and returned `42` from `add(19,23)`. There was no spontaneous drop
in this run and no on-air SA Query reset replay. See
`build/hw-validation-wifi-sa-query-reset-lean/`.

### WPA Key-Install Result

Pinned `mm.o:mm_sec_machwkey_wr+0x146` polls the write trigger until
completion. Nim bounds that wait and returns failure on timeout. The
SDK supplicant used to discard the driver's return value, allowing a
failed PTK or GTK install to be reported as WPA complete. In the
pre-fix all-core M0 ELF, `wpa_sm_set_key+0x20` calls the key installer
and `+0x26` overwrites the result with zero.

The SDK adapter now passes the Nim driver's result through to the
existing supplicant failure path. The patch is required by the WPA
overlay, like the existing lwIP SDK patches:

```sh
git -C build/bl_iot_sdk_b773b3f apply --check "$PWD/tools/bl808_wifi_wpa_key_result.patch"
git -C build/bl_iot_sdk_b773b3f apply "$PWD/tools/bl808_wifi_wpa_key_result.patch"
python3 tools/check_wifi_wpa_key_completion.py
```

The host check links the production WPA and deauthentication glue.
It covers successful installation, PTK and GTK rejection, and a
duplicate TX completion. A key-install failure must produce one
failure notification and no successful WPA completion. The legacy
station confirmation still uses a generic handshake status; it does
not distinguish a local hardware failure from an AP or network error.

The 851,952-byte M0 wrapper built, fit its partition, and was written
and verified through the UART anchor without writing boot2, partition
tables, LP, or D0. On Frog, the Ox64 recorded three WPA completions
and a DHCP Offer/ACK pair at boot and after each of two forced
reconnects. Wired HTTP at `192.168.1.114` reported M0, D0, LP, and
enclave healthy and returned `42` for `add(19,23)`. No spontaneous
drop or missed reconnect was recorded. The key-write rejection
cases were host injections; no hardware failure was forced. See
`build/hw-validation-wifi-wpa-key-result-lean/`.

#### Key-RAM Timing

Pinned `mm.o:mm_sec_machwkey_wr+0x13a` writes the trigger and
`+0x146/+0x14a/+0x14c` polls it without a timeout. Nim bounds both
the idle and completion polls by read count. The 200 ms cooperative
host-command budget is separate and cannot interrupt a running callback.

With `bl808WifiDiagKeyWriteTiming`, M0 records CLIC timer deltas
outside the polls. The total is measured from entry to the hardware
wait outcome; it excludes key publication and the caller's work.
The counters record timing and timeout counts, not key data.

| Write | Samples | Max idle | Max trigger | Max total | Timeouts |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pairwise | 3 | 10 us | 6 us | 350 us | 0 |
| Group | 4 | 7 us | 6 us | 297 us | 0 |

The 851,824-byte M0 timing image was verified and rebooted through the
UART anchor. Ox64 joined Frog at boot and passed both forced reconnects
with DHCP and wired HTTP intact. These are normal-path samples, not a
wall-clock limit on the timeout path or a repeat of the AP-start
measurement. The 57 focused key-driver checks, including timer rollover
and both timeout cases, and the WPA host fault replay passed.
See `build/hw-validation-wifi-key-write-timing-fit/`.

### Traffic-Probe Loss Freshness

Pinned `mm.o:mm_ap_traffic_probe_cfm+0x12/+0x1c` resets the miss budget
and records the MAC time after an ACK; `+0x30` queues a reason-22 loss
report once the no-ACK budget is exhausted.
`txl_frame.o:txl_frame_evt+0x64/+0x70` can call several completions in
one drain before SM handles the report. The vendor path does not retract
the queued report if a newer completion shows the link recovered.

Nim now snapshots a per-VIF traffic-ACK generation for the private
loss metadata and rechecks it at publication and SM dispatch. Beacon
reception and an ACK for another VIF do not invalidate a traffic
loss; the existing TBTT beacon freshness check remains independent.
The host replay covers a matching ACK during allocation, in the sent
queue, and in the saved queue, plus the no-ACK controls. The focused
host suite passed 98 cases and the bounded model gate passed all
14 cases at seed 808 and 256 steps. This is a local queue-lifetime
fix, not a reproduction of the reason-7 Frog drop or an over-the-air
change.

The all-core diagnostic build linked, but its 852,080-byte M0 wrapper
exceeds the current partition by 112 bytes. Disabling
`bl808WifiDiagDhcpTxAttempts` reinstates older TX diagnostics and did
not recover flash space. Writing the existing peer diagnostic labels
directly to UART instead of concatenating temporary strings saved
256 bytes with identical D0/LP output in a host transcript check.

The 851,824-byte wrapper fit with 144 bytes to spare and was written
through the harness's UART anchor, without writing boot2, partitions,
LP, or D0. Frog WPA and DHCP completed at boot and after both forced
reconnects. Wired HTTP at `192.168.1.114` reported M0, D0, LP, and the
enclave healthy and returned `42` for `add(19,23)`. A post-reconnect
snapshot recorded one traffic probe with a MAC ACK (`0x80800000`),
no misses, and no spontaneous drop. No queued reason-22 loss was
exercised on air. See `build/hw-validation-wifi-traffic-probe-freshness-fit/`.

### TX Completion And Link Evidence

Pinned `txl_cntrl.o:txl_transmit_trigger` routes internal management frames to
`txl_frame_cfm` after observing the DMA completion bit. `txl_cfm.o:txl_cfm_flush`
can take the same retirement path without a hardware result. Nim still counts
both as retirement events but only counts ACK outcomes when bit 31 of the
confirmation word is set. The regression covers both auth and assoc frames.

Pinned `sm.o:sm_auth_send+0x1e4` and `sm_assoc_req_send+0x19c` report
statuses `1` and `4`, respectively, with reason `0xffff` when the TX frame
allocation fails. Nim now uses those statuses before submitting a frame or
arming a timer. Pinned `sm_task.o:sm_rsp_timeout_ind_handler+0x74` and the
Nim response handler still report `11` when response retries are exhausted.
Older snapshots using `11` for allocation failures are ambiguous.

Pinned `mm_task.o:mm_force_idle_req_handler+0x1e` requests hardware idle;
the live switch path reaches `chan.o:chan_pre_switch_channel+0x1ba`
and `mm.o:mm_active+0x8` to reactivate it. A canceled Nim switch can now
retire the idle request without leaving a still-current home binding
inactive. The restore uses the saved MAC/MM state and requires the
original context and VIF bindings, no scheduled replacement, and no
reset or committed idle handoff. It does not retune or run the canceled
switch callback.

Pinned `vif_mgmt.o:vif_mgmt_register+0x28` calls `mm_hw_info_set` only
for the first VIF; the compatible additional VIF path jumps past it at
`+0x13e`. Nim now preserves the shared address registers when a second
VIF fits the mask, regardless of the first VIF's role. The second VIF
retains its own address and the shared RX filter is extended. These
cases do not explain a completed retry-limit report on a single STA.

Pinned `mm_task.o:mm_hw_config_handler+0x174..0x19e` saves an EDCA entry
and writes the shared bank based only on VIF state. Pinned
`chan.o:chan_pre_switch_channel+0xc8/+0xcc` publishes the new context
but proceeds to wake and postponed TX without restoring the bank.
The native code requires an exclusive active owner of the current
operating context for any EDCA publication. A single internal MM
request sends all four words after the hardware is idle, or the normal
channel return loads them before resuming TX. A stale VIF, binding, or
reset generation cannot publish the request. AP startup keeps its own
queue profile rather than copying the bank from a running STA. A
co-channel AP and STA cannot independently program the shared bank;
an ambiguous owner defers publication. See the [IEEE discussion of the
EDCA update timing](https://www.ieee802.org/11/email/stds-802-11-tgm/msg00890.html).

The UART-anchor build passed the HTTP/WASM/UDP manifest. A breakpoint
at the MM refresh entry caught an admitted Frog beacon in operating
context state 5 at 2462 MHz. Its update count was still zero and all
four hardware words matched the BSS and VIF copies; the AP did not
change settings during this test. Applying a changed count, retrying a
failed allocation, and returning to independent channel profiles are
covered by the host regression. See
`build/hw-validation-wifi-native-wmm-beacon/logs/live-accepted-wmm-beacon.json`.

The same bench's live UART readback had GPIO14/15 at `0x40400717`,
the UART route nibbles at `0x32`, and UART TX/RX/period registers
`0xf05/0x701/0xac00ac`. Together with the RAM anchor accepting verified
UART writes, this leaves the board-to-host TX path unverified at the
electrical level, not a demonstrated console configuration mismatch.
See `data-post-run/logs/console-uart-readback.m0.openocd.log`.

The pinned `phy_trpc.o:trpc_get_power_idx` accepts two unsigned rate bytes
and a signed dBm byte and returns an unsigned index. It ignores the rate
bytes and maps signed powers at or below 10 to `0xE8`, with distinct encodings
for 11, 12 and 13. Nim now preserves that ABI and signed comparison;
the active default per-rate lookup is unchanged. The four ret-only RFC
power/DVGA exports now accept the pinned `rfc_helper.o` parameter types.
The Nim rate-table getter still returns the active rates for callers even
though the pinned native `trpc_power_get` is ret-only. The MAC timing/power
setup does not use those readback values as its programmed power indices.

RFC VCO replay
(`rfc_init+0x246..0x74a`) publishes eight frequency bits and five IDAC bits
separately, preserving the other bits in each halfword and the upper half of
RF[0x164]. The HAL's internal LO record byte order has not changed.

The WL capcode-get callback takes two byte pointers. `wl_init` passes the
same temporary byte through both arguments, matching the selected vendor
object. It reloads the live configuration after the parameter, capcode-set,
capcode-get and modem calls, and publishes completion to the current storage.
A configuration invalidated by a callout stops locally with -1; the vendor
object assumes valid storage. Callback ordering, capcode range checks,
parameter status and cold/restore selection are retained.

The local `wifiRfCoreInitMode` and `rfc_init` wrappers configure all WL
callbacks to nil, then use a guarded no-callback modem/publication step.
That step rejects unexpected callback slots and returns false if its live
configuration disappears; both wrappers require success and the current
`0xACDE` completion marker before publishing RF readiness. `rfc_init` also
skips `phy_init` on failure. The public `wl_init` keeps the archive's
callback order, ABI, and parameter-callback return byte, calling the shared
modem/publication step after those callbacks. Native failure/recovery and
callback cases cover both paths, and the scan-only M0 image links. These
local guards are not behavior claimed for the archive.
Both local firmware startup callers now check that state before MAC/IPC setup.
The embedded entry logs the RF failure and returns; the backend returns false
without setting `fwStarted`, allowing a later retry. Native tests cover both
stop paths and the backend retry in checked, release and ASan modes. The
vendor `arch_main.o` proceeds after its RF call, so this is a local fail-closed
boundary for incomplete initialization.

The pinned WiFi `mm_task.o` passes the MM start payload directly to
`phy_init`, then selects channel 2412 and TX power 16. The Nim payload has
the same zero-offset PHY config and fields at byte offsets 64 and 68.
`mm_force_idle_req_handler` is a separate channel-switch handoff: its vendor
body does not mask interrupts around `hal_machw_idle_req` or the completion
callback. Nim no longer adds an outer IRQ mask there; its request-ownership
checks remain. Focused tests verify that callbacks observe the incoming IRQ
state, including when interrupts are enabled.

Radare2 of the same `mm_task.o` also resolves seven assertion call sites that
previously reported `"mm_task.c"` instead of the vendor condition and `"module"`
file string. They cover the MM-start state, three MAC-idle checks, the default
HW-config branch (`"0"`), the saved next-state field, and non-STA PS options.
The next-state assertion uses vendor line 1465, not 1580. Focused native tests
check the corrected diagnostics and unchanged fail-closed behavior; this does
not validate the corresponding hardware fault paths.

The saved channel index is a byte initialized to channel 1, matching vendor
data and loads/stores. Public function argument types remain unchanged;
the existing out-of-range argument guard remains a local defensive boundary,
not evidence of a broader vendor ABI for arbitrary word-sized inputs.

### Crystal Selection And PLL

`rf_pri_xtalfreq` selects latched private state without touching registers.
Unknown flags preserve the previous selection. Initialization calls it after
efuse setup and before fixed defaults, and LO calibration/channel programming
uses the matching 24/26/32/38.4/40/52 MHz table banks rather than a fixed 40 MHz
bank. LO consumers wait for a valid table selection.

PLL programming uses the selected reference-divider state and the vendor's
separate frequency-flag priority. Its finite lookup retains float32 rounding,
including the two-count difference at 38.4 MHz with divider ratio 2, without
introducing FPU operations. WB03 uses its 26 MHz special branch, its 40 MHz
generic branch, and twelve final settling reads in vendor order.

### LO Calibration Search

LO ACAL starts at 32 and searches with steps 16/8/4/2/1, then applies the
vendor's final comparator correction only for results up to 30. It retains
the measured six-bit result instead of substituting an FCAL-based guess.
The search does not rewrite the comparator configuration in RF A4.

LO FCAL setup clears RF B8 bit 4, enables calibration after the synthesizer
settles, and waits 200 microseconds before searching. Both LO paths select
their mode once before saving state. FCAL samples set and clear START without
software-clearing READY. It polls until READY without inserted delays, matching
the vendor. The existing FCAL timeout counter now records each 5000 unsuccessful
polls as a stall diagnostic; it does not permit a stale result to be consumed.
Coarse search repeats the synthesizer reset/retry sequence until it finds an
accepted code, rather than returning a fabricated code after four attempts.

FCAL sweeps at most 40 codes, measuring at least two samples before checking
the stop count, including code zero when reached. Selection uses the nearest
bracketing count, favors the higher count on a tie, and adds the vendor's final
one-code publication bias with byte wrapping. It restores RF state before
publishing the 21 packed results. Full calibration retains those measured results for every
crystal; initialization no longer seeds a fixed 40 MHz table into empty LO
records.

Local and public calibration snapshots both preserve RF90, not RF8C, in the
vendor's 27-register order. Local snapshots retain independent stack storage.
Out-of-range measurement guards and incomplete saved-record handling remain
local differences from vendor assumptions. These corrections do not establish
RF hardware readiness; a nonresponsive FCAL unit now keeps initialization
waiting, as the vendor does.

### ROSCAL

ROSCAL programs the I/Q candidate fields in RF80. Its coarse search retains
a candidate on a nonpositive signed 25-bit measurement; refinement preserves
the vendor's history termination and byte-sized result wrapping.

Setup preserves the vendor's RFBC/RFB8 enables, two DFE gate writes, RX-mode
write order, and RF48 tone value. READY polling has no inserted delay and does
not return unfinished samples; the existing timeout counter records stall
intervals instead.

I results are published before Q search. Each branch updates one byte in
calibration words 24/22/20/18 and the matching six-bit RF16C/RF168 fields in
vendor order. RCCAL's word 2 and all unrelated record/register bits are
preserved. RXCAL and its full-calibration follow-up retain those measured
bytes, including zero and `0x2023`, instead of replacing them with a fixed
restore record. Full calibration clears the RX DFE mode fields at entry and
exit in vendor write order. These changes do not establish RCCAL or full RF
calibration parity.

### RXCAL

RXCAL setup reads WLAN TXCAL record 8 from calibration storage, not WLAN
configuration. Its tone-gain fields use the active power-table slot 8 row.
The setup keeps individual vendor RX-mode writes and the recovered RF600,
RF74, RF618, and Singen field masks and shifts.

The search initializes measurement control once, waits for READY without
inserted delays, and skips the right candidate when the left strictly
improves the current result. Ties retain the current result. Each returned
code is programmed by the caller before the next search. Saved results retain
their signed low 16 bits; only physical replay masks them to 11/10-bit fields.

RXCAL restores its temporary state before clearing RF88 bit 28, marking the
stage done, and publishing four records/registers once. The unmatched fixed
idle writes and RXCAL-local board latch calls are removed. Later TXCAL,
initializer and scan/TX reviews remove the corresponding fixed replays.
These checks do not establish complete lifecycle parity or physical radio
readiness.

### RCCAL

RCCAL searches the two RF84 lanes, not RF80, and publishes calibration word 2
from the last programmed hardware fields before restoring temporary state.
Its four six-bit saved fields preserve the upper byte shared with TXCAL.
RF90 bit 12 is cleared after restore, followed by the vendor done/fail mode.
Late fixed-result seeds in full calibration and initialization are removed.

Reference/tone setup preserves the vendor DFE gates and write order, RF80,
RF88, RF90 and RF60C ownership, Singen fields, and measurement-control words
`0x600`/`0x16A00`. Priming reads only I; power samples read both I/Q. READY
polling does not return unfinished data or insert delays.

The target is the low 32 bits of `power * 81`, divided by 100. Zero reference
power still follows the search; the unmatched low-power fallback is removed.
Refinement keeps a signed accumulator beyond the physical six-bit range,
with vendor history and 63-attempt limits, and retains the last measured code.
The initializer also restores the vendor synthesizer bit-5 enable (`0x4021`).
Later reviews cover TXCAL and the fixed board replay/latch calls. Full RF
lifecycle closure and physical radio readiness remain unproven.

### TXCAL Search And Records

WLAN and BZ TXCAL searches use measurement frequencies `0x49`/`0x92`.
Each search programs its raw center and initializes measurement control once;
subsequent candidates only retrigger it. READY polling has no inserted delay
or incomplete-data return. The existing counter records stall intervals.

Search endpoints use the vendor's one-sided bounds, including one iteration
for zero delta. Strict left improvements skip the right sample; ties retain
the current result. Both callers program each returned code before starting
the next search. Physical encoders mask raw values without clamping them.

Saved TXCAL records retain byte-sized parameters 0/1 and signed low-halfword
parameters 2/3. Record publication preserves the two padding bytes, and local
index guards run before address calculation. The 48-entry sample trace
remains bounded. This search pass alone does not establish full TXCAL parity
or hardware validation. A nonresponsive measurement unit keeps initialization
waiting, as in the vendor binary.

### TXCAL Setup And Row Power

WLAN/BZ setup preserves the vendor TX/RX DFE gates and individual mode writes,
including channel 9 for both paths. Initial WLAN tuning starts at amplitude
256 with the Singen profile `0x000B0000`. Amplitude changes clear RF21C's
measurement-preparation bits, program both amplitude fields, start TX DFE,
then toggle Singen. The post-RF70 stage precedes OSDAC selection and uses
RF90, not RF8C, with the recovered RF64 field masks.

OSDAC selection searches RF64's five-bit code from 16 toward signed ADC mean
-250, with the vendor side-selection thresholds and software fallback code
10. It retains the last physical candidate, publishes a separate software
code, and does not sweep RF6C or rewrite RCCAL's saved word. Legacy `tmxcs`
diagnostic export names remain available; their samples now describe this
signed-mean search.

Per-row target amplitudes use the decoded little-endian vendor table words.
WLAN gain setup reads live power rows; BZ reads its immutable table. Gain
setup programs RF60 rather than RF6C, uses the selected OSDAC code, and clears
RF68 bit 25. Duplicate frozen calibration power tables are removed.

Row amplitude tuning derives its bounds from the target, can retry with a
halved OSDAC code after negative readings, and returns zero on the recovered
failure/exhaustion paths. Zero skips parameter searches and stores the vendor
default record. Successful rows take one finished I-only priming sample in
mode `0x10000000` before searching. Broader radio lifecycle parity still
requires review.

### RF70 And TXCAL Completion

Each RF70 window measures all 16 candidates without added delays, leaves the
last physical candidate programmed, and starts both scores at -2048 with
candidate indices 5. Strict improvements update the two scores; adjacent
indices select the lower index even when the runner-up remains at its initial
floor. Measurements read I once after READY, then clear the trigger. Diagnostic
capture reuses that sample rather than reading I again after clearing it.

Windows publish individually before the next channel change: word 3 bits
27:24, then word 4 bits 11:8, then bits 7:4. Other bits remain unchanged,
including word 3's upper nibble. Zero is valid. Searches run on every board
and crystal, regardless of existing saved values. The legacy
`bl808WifiRfWb03ApplyMeasuredRf70Replay` define is compatibility-only.
After returning to channel 9, WLAN TXCAL reloads the low-band saved nibble
before the post-window stage.

Both TXCAL coordinators publish their domain's calibration table before
clearing RF1C bits 12/13, setting RF64 bits 26:24 to 3, restoring temporary
state, and OR-ing the done bits. WLAN then programs active record 3 into RF74
and RF600 using the vendor masks, without forcing enable bits. BZ has no
additional active-record writes.

Full calibration runs WLAN TXCAL, BZ TXCAL, and RXCAL for every board/crystal.
It finishes with the two RX DFE stop writes, without an extra general restore
or fixed RF70/TOSDAC patch. Warm initialization no longer applies a second
fixed RF70 replay. The separate initialization/restore review removes
content-based saved-data validity checks and the other initializer patches.
The channel-entry and scan/power reviews remove the PHY baseline calls and
remaining fixed scan/TX replay calls. These static checks do not execute the
vendor binary or validate physical radio behavior.

### LO Lookup And CW

The VCO getters use wrapped 32-bit subtraction before shifting and capping
the LO index at 20. Inputs below 2402 MHz therefore select the last record,
not the first. IDAC returns the whole saved low byte; physical ACAL writes
still own only their six-bit field. RFC packing preserves both saved bytes.

CW uses compensation slot 0 below 2412 MHz and slot 13 above 2472 MHz.
Its power index first combines channel and temperature compensation, divides
toward zero, wraps the adjusted target to a signed halfword, and clips it at
zero. After calibration completes, it reads gain compensation separately,
divides it by four, and adds the table offset 2.
The local bounds check remains for the vendor's unchecked table reads.

CW preserves RFBC bits outside 23:20, clears both RF21C bits 28/12, and runs
the three TX DFE-enable writes once. Its strobe loop waits until both RF B4
status bits clear; the existing timeout counter records stalls without
reporting completion. Crystal precedence is 24, 26, 32, 40, 52, then 38.4 MHz.
Fixed-point divider values match the recovered double constants for all 83
supported physical frequencies on each crystal.

The existing physical-frequency guard remains stricter than the vendor's
low-halfword admission check, whose wider aliases can index outside its LO
storage. Missing calibration storage is a local no-op, not vendor behavior.
The existing no-crystal 40 MHz fallback is not claimed equivalent to the
vendor's zero-divisor path. Bracketed nonmonotonic FCAL traces retain the
first-crossing adjacent-pair selection; nonbracketing vendor stack reads do
not define a fallback contract. These checks do not establish radio readiness.

### RF Measurement And Signal Generator

The pinned `rfc_helper.c.o` `rfc_get_power_level` maps rate class 0, 1, and
other values to gain groups 0, 1, and 2, then shifts the returned index by
two. Its `rf_pri_get_txgain_index` callee is not in the BL808 RF archive; the
local threshold scan is adapted from the available BL602 helper and remains
unverified for BL808. A symbol scan of the pinned local BL808 WiFi, RF, and BLE
archives found only the undefined RF call. The local BL616, BL616D, and BL616L
RF archives also reference the callee without defining it, so they provide no
independent threshold implementation. The local lookup now widens the CCK
30-tenths subtraction
and threshold addition, so the minimum signed request cannot wrap into a
highest-power selection. A focused native test covers group dispatch and
threshold boundaries in checked and firmware-like modes.

A fresh scan-only M0 build with `bl808WifiNimFw`, `bl808WifiUseBl808Rf`, and
`WifiScanOnly` retains `phy_init` and `rfc_config_channel` but does not retain
`rfc_get_power_level` or the local gain-index lookup. This narrows the current
scan-image risk; it does not validate power selection in another build profile.
The BL602 reference helper uses two separate power-offset globals, while the
local BL808 fallback has only a single gain compensation input, so the BL602
object is not evidence of BL808 threshold parity.

The pinned `rfc_helper.c.o` disassembly shows that `rfc_power_meas` tests the
unmasked frequency result for its presence bit, then stores only its low 20
bits. Its READY poll waits for a finished measurement without returning zero
samples after a fixed count. The Nim path now preserves both behaviors; the
existing counter records each 10,000-poll stall interval without treating it
as completion. The conversion adds the selected 160/40/16 MHz carrier clock
to the signed offset before double-precision division, multiplies by 524288,
adds 0.5, and truncates to a signed word. Zero offset therefore produces
`0x80000` with the presence bit set; negative one-clock offset produces zero.
Signed negative results retain their wrapped 32-bit representation.
The archive's `PKBB16` at offset `0xe0` also places the low 16 bits of
`sampleCount` in RF `0x61c` bits 31:16 before its presence-bit update. Nim
now performs that intermediate write; bit 20 is then set or cleared by the
frequency result, as in the archive. The epilogue multiplies the signed Q
sample by itself, then adds the signed I square to the low return word. Nim
now returns that low 32-bit squared sum, including wraparound; the RF archive's
sole caller ignores this return and reads the output pointers instead.

`rfc_sg_start` uses the vendor's signed RV32 absolute-value sequence (including
its minimum-integer wrap), float32 conversion and multiplication, then double
division before truncating the frequency field. Exact integer division can
differ by one at float32 rounding boundaries. The pinned object's two field
clears between the frequency and amplitude writes target RF `0x210`; Nim had
targeted RF `0x21c`. The typed `0x210` slot now receives both writes, and the
test checks their order and confirms that `0x21c` remains unchanged. The
third argument enables the high-path phase branch; the sign of `frequencyHz`
selects `0x40000000` for negative frequencies and `0xC0000000` otherwise.
Radare2 shows the frequency sign captured in `s2` at `+0x4` and combined with
the phase constant at `+0xf4`; the third argument is only tested for zero at
`+0xdc`. The focused native test varies those inputs independently
and covers frequency-rounding boundaries, delayed READY, and signed I/Q samples in
checked, AddressSanitizer, and firmware-like modes. The normal M0 WiFi HAL
profile compiles, but dead-strips these two exported helpers; neither a target
execution nor physical RF behavior is established by this pass.

The same archive's `rfc_config_bandwidth` writes its initial bit-24 bandwidth
selector to RF `0x220`, not RF `0x80`. Both branches clear RF `0x228` bit 2
before programming RF `0x88`; the final RF `0x7c` clear precedes the
`rf_pri_set_bandwidth` call. The Nim path now follows that register ownership
and order. A focused native matrix checks the ordered writes and callback for
zero, 20 MHz, and non-20 MHz inputs. It does not model analog settling.

The adjacent `rfc_helper.c.o` control bodies were also checked with radare2.
`rfc_rf_fsm_force(15)` clears RF `0x26c` bit 3 immediately; other values
write the low three state bits, wait 20 us, then set bit 3. The RC variant
does the same at RF `0x04` bits 10:8 and 11, but waits even when releasing
mode 15. WLAN mode forcing accepts 0 through 4 at RF `0x228` and `0x220`;
other values clear those fields. Signal-generator stop clears RF `0x20c`
bit 31, and dump selects two RF `0x220` windows, reading `0x224` after each.
The focused native test checks those write masks, delay positions, and dump
read order. `coex_wifi_rf_forece_enable` in the pinned `arch_main.o` is a
two-byte return-only function, so the Nim no-op is intentional. This is
static register-sequence evidence, not physical RF validation.

The `rf_pri.c.o` `rf_pri_config_mode` body is not a mode-variable setter: it
clears RF `0x04` bit 1, zeros RF `0x2c`, sets RF `0x30` bit 1, then writes a
mode-dependent RF `0x30` field profile. Modes 3, 4, 5, and 6 have distinct
mask/value pairs; modes 7 and 8 take the default pair, as do other values.
The default pair is mask `0xCF09_00FF` and value `0xCF00_0000`, from the
`lui 0xcf09; addi 0xff` and `lui 0xcf00` sequence at offsets `+0x34..+0x44`.
The earlier Nim pair did not match those immediates, and the test repeated
that error. The Nim implementation now reproduces this four-write sequence;
a focused native trace covers every branch. The archive references this entry from
`fdiq_search`; no on-device mode transition is established by the static test.

The same `rf_pri.c.o` object has single-`ret` bodies for
`rf_pri_update_param` and `rf_pri_set_bandwidth`. Nim now leaves both entry
points side-effect free; their former channel/bandwidth assignments only fed
unused local variables. A focused native check covers representative inputs
in checked and firmware-like modes.

The pinned `rf_pri_manual_incremental_cal_start` copies three fields into RF
`0x10b4` before triggering calibration. Nim previously omitted the middle
copy: source bits 0:2 into destination bits 11:13. Radare2 locates the
`0xffffc7ff` clear and `0x3800` insert at object offsets `+0x7a..+0x90`.
The focused native check now covers all eight source values, retry states 0
and 3, both coarse directions, delay counts, and the adjacent stop routine
in checked, AddressSanitizer, and firmware-like modes. These checks model
MMIO and status; they do not establish on-device calibration behavior. The
normal M0 WiFi HAL profile compiles, but dead-strips both manual-calibration
entry points, so this pass does not establish a linked runtime path.

### Modem Late Init Register Phases

Radare2 of the pinned `rfc.c.o:modem_init_core` late-init body shows two
consecutive RF `0x260` writes at `+0x308..+0x326`: clear bit 30 then set it,
followed by clear bit 29 then set it. The local port previously made two
no-op writes. At `+0x36c..+0x390`, the vendor masks RF `0x26c` with
`0xFFF003FF` and inserts `0x00014000`, then masks RF `0x268` with
`0xC00FFFFF` and inserts `0x0F000000`. The local port used `0x00028000`
and `0x05000000` for those insertions. A native trace checks the complete
late-init write sequence from `+0x1a2..+0x3b6`, including the RF, auxiliary,
PHY, and BBA register addresses, with varied starting words in checked and
firmware-like modes. This establishes the register sequence only; it does
not validate analog behavior or a booted device.

The same `modem_init_core` entry classifies 24, 26, 32, 38.4, and 40 MHz
directly. For other inputs it subtracts 52 MHz, initializes the table index
to 5, then uses `th.mvnez` at `+0x5c` to replace that index with zero when
the subtraction is nonzero. Thus 52 MHz selects row 5, but unsupported
frequencies select row 0 (24 MHz), not row 5. The shared Nim selector now
matches this behavior; a native test covers all six supported frequencies
and several unsupported values. This is the vendor fallback, not an
endorsement of operating the radio with an unsupported crystal.

The same late-init body stores `0xC8` to PHY `0x200028A8` at `+0x32a..+0x332`,
after both RF `0x260` sequencer writes at `+0x308..+0x326` and before the
RF `0x2c4` latch writes. Nim previously set the timer before the RX-mode,
bandwidth, and sequencer phase. The port now preserves the vendor order, and
the full native trace checks the timer's position among the RF writes. The
M0 WiFi HAL image compiles with
`-d:bl808WifiNimFw`; physical settling remains unverified.

The pinned `rf_pri.c.o:rf_pri_get_vco_{freq,idac}_cw` bodies subtract
2402 MHz, shift by two, and clip the resulting index at 20 before reading
calibration halfword `14 + index`. The `rfc.c.o:modem_init_core` loop packs
the resulting bytes for 2404..2480 MHz into ten consecutive words at RF
`0x13c..0x160`, then writes the 2484 MHz word at RF `0x164`. A focused
native test checks every calibration entry, clipped inputs, the nil-storage
guard, and all eleven ordered stores in checked and firmware-like modes.
Both inspected objects were verified byte-for-byte against the pinned RF
archive. This is static handoff evidence, not a calibration or radio test.

### Channel Departure Deadline

In the pinned `chan.o`, `chan_upd_ctxt_status+0x28..+0x30` retains the
operation timer when entering status 3. `chan_ctxt_op_evt+0x22..+0x5e`
sets the timeout flag; with multiple operating contexts and no pending
idle request, it clears both protection counters and calls the idle
callback. The STA/AP completions do not advance a zero counter.

Nim now carries the original departure deadline across the switch's
initial TX reset only while the timer serial, destination allocation,
channel definition, and current/scheduled contexts still match. On
timeout it also retires the pending protection tickets before forcing
idle, without canceling the scheduled switch. The reset drain can
deliver those old callbacks synchronously.

The host regressions cover deadline delivery across an expected reset
and epoch wrap, cancellation and replacement, and one modeled PHY
retune when old completions arrive during or after the timeout reset.
Removing either fix from the test build reproduced its corresponding
failure. The M0 connected-scan manifest built; the patch was not flashed.
This is a separate failure path, not evidence that scans caused the
original spontaneous reason-7 disconnect.

### TX reset and the station state machines

The pinned SM, SCANU and channel code has no TX reset epoch: `txl_reset`
flushes frames and every timer, expected response and control exchange
carries on. The port had tied those owners to the epoch as well, so a
reset left SM waiting with no completion. A 2026-11-24 audit found the
cases below; reachability was argued from code, not reproduced on
hardware.

`smTxSessionCurrent` now checks the connection attempt without the reset
epoch, and `smTxOwnerCurrent` adds the epoch for frames only. The
auth/assoc response deadline, the expected auth response, the BSS
parameter batch, the activation exchange and the SM scan/join exchange
use the session check. The deauthentication confirmations end their wait
with any status, as pinned `sm.o:sm_connect_abort_deauth_cfm` and
`sm_supplicant_deauth_cfm` do (see "SM teardown" below). `bl_reset_evt` carries the TBTT,
connectionless and context deadlines and the scan and registration
exchanges across its `txl_reset` through `chanPreserveAcrossRecovery`.

Three deliberate differences from the archive:

- `sm_init` clears the parked connect indication. Pinned `sm_init` leaves
  `sm_env[4]` set and `sm_connect_req_handler+0x110` then asserts; the
  port had answered every later connect with busy. The parked messages
  are still not freed there.
- `MM_SCAN_CHANNEL_END_EARLY` has no payload. Pinned
  `scan_task.o:mm_scan_channel_end_early_handler` asserts at line 186 when
  TASK_SCAN is idle and otherwise ends whichever dwell is running. The
  port records the request, epoch and channel index when SCANU asks, sends
  nothing when no dwell exists, and ends only that dwell. No caller in
  this tree sets the quick-connect flag (bit 8) that produces the message.
- `scanu_default_state` has a fourth entry. The archive has no
  `SCANU_RAW_SEND_REQ` handler while scanning or joining, so the kernel
  frees the request and the host waits out its command timeout. The
  request points at a host buffer, so it is not saved; it is refused with
  `SCANU_RAW_SEND_CFM` result 1, and `bl_send_scanu_raw_send` returns
  `-EBUSY`. That wrapper's confirmation buffer was one byte for a
  four-byte payload and is now a `uint32`.

Host tests are in `tools/test_wifi_sm_audit_sm_connect.py` and
`tools/test_wifi_sm_audit_scan.py`. The M0 HTTP server manifest built;
none of this was flashed.

#### Channel switch

`chan_switch_start` begins a switch and `chanSwitchFinish`
(`channel_switch.nim`) is its only end: `chan_pre_switch_channel` calls it
when it publishes the target, and every abandonment calls it too. A
context is identified by its slot and `chanCtxtEpochs[slot]`; a retired
context redirects a switch to it at `chan_ctxt_del`, so the callbacks carry
no other identity. This fixes audit items MMCHAN-1 to MMCHAN-4, MMCH-S1,
MMCH-S2, MMCH-S6 and SCAN-N1. Differences from the archive:

- The switch's `MM_FORCE_IDLE_REQ` is one static message, never freed:
  `mm_force_idle_req_handler` returns `KeMsgNoFree` for it and `ke_msg_free`
  ignores it. `chan_switch_start` therefore cannot fail; pinned
  `chan.o:chan_switch_start` uses `ke_msg_alloc`, which asserts on failure.
  While the message is queued or saved, a new switch reuses it.
- When MM runs it, `chanSwitchLanded` serves what the switch needs then
  (start the departure, or a deferred departure) and always leaves
  `HW_ACTIVE` through `mm_back_to_host_idle`. A message that lands after
  its switch was abandoned only hands MM back. Pinned `chan_goto_idle_cb`
  returns at +0x30 when no context is scheduled, leaving MM in `HW_ACTIVE`.
- Protection confirmations count with any status, as in `chan.o`. The
  frames carry the departure attempt's generation as their callback
  argument instead of 0, so a confirmation from an earlier attempt (flushed
  by a timed-out departure's forced idle, or late) counts for nothing.
  Frames are counted before submission and uncounted if refused; frames
  that finish during submission only count. The blob stores the counts
  after both loops.
- When the last confirmation comes from a TX reset's drain (`bl_reset_evt`),
  the departure is not run inside the reset: it is re-posted to MM in the
  same message. The blob calls `mm_force_idle_req` and
  `chan_pre_switch_channel` from inside the flush; the port refuses a
  nested `txl_reset`.
- A forced idle that fails (a HW poll timeout; the blob's waits have no
  timeout) does not retune. The switch asks MM again after the recovery it
  posted. A MAC that is not idle in MM_IDLE still hits the 1013 assert, but
  the request stays saved instead of being dropped; `bl_reset_evt`
  reschedules MM's saved messages.
- Retiring the destination redirects the switch with the rule of pinned
  `chan_ctxt_unlink+0xb4..0x144`: with more than one operating context
  left, CDE event 1 picks the next one; with one left, the switch goes to
  it, even when it is the current context; with none left, the switch is
  abandoned. The port applies the rule in `chan_ctxt_del`
  (`chanSwitchRetire` -> `chanSwitchRedirect`) for every retirement, so
  `chan_ctxt_unlink` no longer re-points `scheduledCtxt` itself and a
  direct `chan_ctxt_del` of a destination redirects too. Pinned
  `chan_ctxt_del` leaves `chan_env+36` pointing at the freed slot. If CDE
  picks nothing (it returns while a scan or ROC dwell is claimed), the port
  abandons the switch; the blob would keep the freed slot as the target.
  The operation timer is not moved to the new destination, as in the blob;
  a departure then waits for its protection frames, which always complete.
- An abandoned switch (no context left to go to, or its message dropped)
  puts the destination back to status 1, clears the operation timer and the
  departure-timeout flag 0x20, clears the PM bit that its protection set,
  and leaves `HW_ACTIVE`. A scan or ROC dwell that was never entered goes
  from 0x08 back to 0x02 (0x04 to 0x01) and the connectionless gate is
  armed again, so TASK_SCAN, waiting in state 2 for START, gets its dwell
  later. No END is posted for a dwell that was never entered. The blob
  never abandons a switch and clears 0x20 only in
  `chan_pre_switch_channel`; a stale 0x20 would let the next departure skip
  its PM=1 protection.
- Retiring the source context only clears `currentCtxt`; the switch
  continues, as in the blob. The port used to cancel it.
- `chan_pre_switch_channel` with no target ends the switch; the blob
  returns at +0x21c with MM in `HW_ACTIVE`. The port-only RX drain is kept;
  if it retires or replaces the target, the switch is abandoned. The
  vendor tail after the retune runs without re-checks and always reaches
  `mm_active`.
- In-place TPC or bandwidth edits no longer invalidate the switch, the
  operation and TBTT timers, or a beacon-detect ROC request. The blob has
  no such checks; the port's had compared the whole channel definition.
- `chan_scan_req` no longer cancels a switch to slot 3 (none can exist
  while the slot is free), the connectionless gate calls
  `chan_switch_start` directly (its allocation retry is gone), and MM no
  longer tracks the switch's idle wait: MM is restored when the message
  lands.
- The per-VIF EDCA shadow is port-only; the hardware bank is written for
  the VIF of the current operating context while no switch is in flight
  (`mmEdcaOwner`). That predicate also required context status 4 or 5. A
  lone context is left at status 1 by its operation timer (pinned
  `chan_ctxt_op_evt` with one context: status 1, then a no-op
  `chan_switch_start`), so after an AP stopped, every `MM_SET_EDCA_REQ` and
  WMM refresh for the remaining STA stayed in the shadow until the next
  switch (MMCH-S6). The status is no longer part of the predicate.

The write-only `chan_*` shadows (`chanCtxtCount`, `chanCtxtFlags`,
`chanCurrentCtxt`, `chanPendingCtxt`, `chanScanPending`,
`chanConflictDetected`) were removed; nothing read them. The switch keeps
its own serial and phase rather than the `Op` record of `op.nim`: its
phase already says whether it is live, so an `Op` would only duplicate it.

Host tests: `tools/test_wifi_switch_request.py`,
`tools/test_wifi_channel_protection.py`,
`tools/test_wifi_sm_audit_mm_chan.py`, `tools/test_wifi_sm_audit_scan.py`
and `tools/test_wifi_switch_table.py`, which drives a switch to an AP
channel, the scan slot, the ROC slot and an AP channel with a scan claimed
through each phase and each disturbance (protection confirmation with
each status, unlink of destination, source, other or all contexts,
operation deadline, MAC recovery) and checks that MM never stays
`HW_ACTIVE`, that `scheduledCtxt` is set exactly while a switch is live,
and that 0x08/0x04 are set only while their dwell is pending or running.
The M0 HTTP server manifest built; none of this was flashed.

#### Replies, message retirement and the firmware step

The blob's MM handlers answer every request they run; an `assert_err`
there halts. Here an assert posts a MAC recovery and returns, and the port had
consumed some requests without their reply, which left an SM BSS batch or
cleanup waiting for good (audit SMSTRUCT-N1). Differences from the archive:

- With TASK_MM idle but the MAC not idle, `mm_hw_config_handler` (line
  1527) and `mm_set_idle_req_handler` (line 946) assert as in `mm_task.o`
  and keep the request saved. The recovery leaves the MAC idle and
  `bl_reset_evt` reschedules MM's saved messages, so the request then runs
  and is confirmed. `mm_force_idle_req_handler` already did this (1013).
- `mm_set_ps_options_req_handler` answers a request for a VIF that is out
  of range or not a station (assert 1680) without changing any VIF; the
  blob indexes the VIF unchecked and halts on the assert.
- `MM_SET_EDCA_REQ` with a queue above 3 or a VIF out of range is answered
  without effect. The blob writes the unchecked index and answers.
- A kernel timer expiry whose message cannot be allocated is retried on the
  same entry 1 ms later. The blob's `ke_timer_schedule` uses `ke_msg_alloc`,
  which halts; the port had posted a recovery and dropped the expiry. The
  optional scan probe repeat is still dropped.

`ke_msg_send` now retires a message it delivered to the host with
`ke_msg_free`, as the blob's tail call to `g_bl_ops_funcs[0xBC]` does. The
port's own copy of the owner hooks there had lost three of them (KTX-5).

The blob's firmware is its own task and is never reentered. Here a host
callback runs synchronously inside a handler and can poll the firmware
again through `osSleepUs` or an OS wait. `wifiMainServiceStep` and the
facade's TX service are firmware steps: the facade now calls
`wifi_nimfw_service_tx` instead of `wifi_nimfw_service_sta_postponed`,
`txl_transmit_trigger` and `txl_frame_evt`. While a step runs, a poll
(`vendorPollOnce`) still services MAC interrupts and OS timers, but it
neither dispatches firmware work nor drains the host queue until the step
returns. The blocking idle wait (`wifi_main`) releases the step. Built with
`-d:bl808WifiOpCheck`, `nimfw_dbg_nested_pump` counts refused entries. A
host callback that waits inside a step for the firmware to answer now
waits until its own timeout; the counter is there to show whether that
happens. `examples/m0_allcore_wasm_cps_live_test.nim` still calls the
three TX entries directly.

`op.nim` adds the operation serial (`Op`) that later state-machine work
stamps into timers, frames and indications. The Nim tail of a kernel timer
entry is now its stamp (`KeTimerEntry.stamp`); SA Query keeps storing its
serial there.

Host tests: `tools/test_wifi_mm_idle_readiness.py`,
`tools/test_wifi_mm_ps_options_assert.py`,
`tools/test_wifi_message_routing.py`, `tools/test_wifi_timer_lifetime.py`,
`tools/test_wifi_pump_guard.py`,
`tools/test_wifi_op.py`, `tools/test_wifi_sm_audit_sm_connect.py` and
`tools/test_wifi_sm_audit_txrx_reset.py`. The M0 HTTP server manifest
built, also with `-d:bl808WifiOpCheck`; none of this was flashed.

#### SM teardown (state 10)

`station_sm.nim` holds TASK_SM's state. `smGo` is its only `ke_state_set`,
and each state it writes starts a new `Op` serial. Every end of an attempt
or link goes through `smTeardown`, after `smDeauthWait` when a
deauthentication is sent first. They are the only ways into state 10, which
has two phases. In the deauthentication wait, the frame carries the current
serial.
In the cleanup, `station_cleanup.nim` runs unchanged and ends with
`smGo(SmIdleState)`. The disconnect handoff (`SmDisconnectHandoff`,
`smDisconnectOwned`), the flushed-frame claims, the SM owner fields of
`TxFrameIdentity` and the lock passing of `smConnectIndLocked` and
`smReportApDisconnectLocked` are gone. Differences from the archive:

- `sm_handle_connection` and `sm_handle_supplicant_result` enter state 10
  (`smDeauthWait`) once the frame is built, just before the push. The blob
  sets it before `txl_frame_get`. A failure before the push therefore comes
  from the original state, with the same failure function and status.
- The frame's confirmation argument (frame+212) is the wait's serial, not
  the VIF. As in `sm.o`, the three confirmations end the wait whatever the
  status: sent, not acknowledged, flushed by `txl_reset`, aged out after a
  reset, or released after the VIF session moved on (SMCONN-F3, SMCONN-F4,
  KNOWN-TXRX-F1-SM). A confirmation whose serial is not the live wait's
  changes nothing.
- The deauthentication wait has a 3 s guard timer, which the blob does not
  have. A postponed frame whose context never returns is not aged on a
  STA-only device. On expiry the guard runs the frame's own callback with
  `0x40000000`, as a flush would. The frame's later confirmation is stale.
- `sm_connect_ind` does nothing once a teardown has started, so a late
  activation reply or response timeout cannot end the attempt twice. A
  deauthentication wait ends through its frame's confirmation
  (`sm_connect_abort_deauth_cfm`, `sm_supplicant_deauth_cfm`, which in
  `sm.o` tail-call `sm_connect_ind`, or `sm_disconnect_deauth_cfm`, which
  tail-calls `sm_disconnect_process` as here), a refused push or the guard.
  `smDeauthWait` refuses to start while a teardown is running.
- Every teardown ends SA Query when it starts, the deauthentication wait
  included. The blob clears it in `sm_disconnect_process`, after the
  confirmation, so an SA Query timeout during the wait could start a second
  teardown.
- `sm_handle_connection` sends no second deauthentication while a teardown
  is in progress. The blob would send another frame and set state 10 again.
- `mm_connection_loss_ind_handler` publishes state 10 after the cleanup has
  claimed the link (blob: before `sm_connection_tlv_set`). The handoff had
  carried the loss's TX reset epoch. A loss queued across a channel switch
  was dropped with state 10 already set, which left SM there (PSK-2).
- If the cleanup finds no STA VIF (the slot was re-registered as another
  type), the attempt ends unreported and SM goes idle (`smTeardownUnclaimed`).
  The blob indexes the VIF regardless.
- `me_set_active_cfm_handler_sm` no longer has the blob's state-10 "set
  idle" branch. It was unreachable: only a state-4 batch reply gets that far,
  and the cleanup goes idle by itself.
- After the AP-disconnect log, the SA Query timer clear and the failed
  attempt's scan-result removal, the handlers no longer re-check the peer or
  the attempt. None of these calls can re-enter the firmware step (pump
  guard), and the free hooks only forget tags.

Host tests: `tools/test_wifi_sm_table.py` drives each teardown entry
(failure in states 1-9, abort in 6/8/9, handshake failure, user disconnect,
link loss) through each wait ending (confirmed, refused, guard, late) over
the real cleanup. It calls `smDeauthWait` directly; the real frame builders
and retirement kinds are driven by `test_wifi_sm_audit_sm_connect.py` and
`test_wifi_deauth_lifetime.py`. It checks that state 10 always has its phase and
carrier, that each end is reported exactly once, and that every serial is
stale at quiescence. It also lints that `smGo` is the only TASK_SM state
writer. Further tests: `tools/test_wifi_sm_audit_sm_connect.py`,
`tools/test_wifi_sm_audit_ps_keepalive.py` (PSK-2 no longer xfail),
`tools/test_wifi_sm_cleanup.py`, `tools/test_wifi_deauth_lifetime.py`,
`tools/test_wifi_disconnect_tx.py` and `tools/test_wifi_supplicant_result.py`.
The M0 HTTP server manifest built; none of this was flashed.

## BLE

- Local controller path: `src/bl808/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Local RF path: `src/bl808/librf_bl808.a`
- SDK source: `bouffalolab/bouffalo_sdk`
- Controller source commit: `a05d70b0`
- Controller source path:
  `components/wireless/bluetooth/btblecontroller/lib/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Controller SHA-256: `802780e9e6ad158ae124012415e1af97514ac14738ee103e91783d81a26b427a`
- The BL808 controller archive was removed from the SDK in commit `7e7b5642`.
- RF source path:
  `drivers/soc/bl616/rf/lib/librf.a` from the same `bl808_fw` SDK branch
- RF SHA-256: `5808ffe3bfdcf8c7f1b0f46b2e287fa6d99130c7a1a385ccb8ab7fb538b9d864`
