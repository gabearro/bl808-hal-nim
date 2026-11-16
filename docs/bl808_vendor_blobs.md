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

## WiFi

- Local path: `src/bl808/libwifi_fw.a`
- Reference path: `tools/ref/libwifi_bl808.a`
- SDK source: `bouffalolab/bl_iot_sdk`
- Verified source commit: `b773b3f4bf6154125304a328c72bf2aa7168a715`
  (`[BL808] [APP] add bl808_demo_event support wifi`, 2023-04-21)
- Source path: `components/network/wifi/lib/libwifi.a`
- SHA-256: `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7`
- The source archive at this commit and both local copies are byte-identical.
  This is a BL808 reference, not the later `wifi6` archive in `bouffalo_sdk`.

### Pure Nim TX Policy

The default firmware copies the station's complete rate, retry, and RF power
policy into each host TX buffer, matching the vendor allocator.

`-d:bl808WifiBootstrapRetryWorkaround` opts into the earlier bench workaround:
fixed retry rates and power for EAPOL and all IPv4/ARP traffic. It is not limited
to DHCP or the period immediately after association. This is a diagnostic
override, not the vendor-parity configuration. The existing
`bl808WifiKeepEapolRcPrimary` and `bl808WifiForceEapolPrimaryLegacy` options only
modify this explicitly enabled workaround; the latter takes precedence.

Authentication and association requests keep the internal-frame allocator's
rate policy and TPC-selected power by default. Their earlier fixed rate/power
and retry-limit workaround is available with
`-d:bl808WifiMgmtRetryWorkaround`. The `bl808WifiMgmtOfdmFirst`,
`bl808WifiMgmtLegacyFirst`, and `bl808WifiKeepMgmtRcPrimary` options only adjust
that explicit workaround, in that precedence order. The separate
`bl808WifiForceTxPwr20`, `bl808WifiForceTxPwr30`, and `bl808WifiForceTxPwr70`
diagnostic options still override management TX power independently.

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

### BIP Initial Replay Floor

Fresh IGTK installation now initializes the next-IPN representation to
`KDE IPN + 1`, including a KDE IPN of zero. Previously the vendor-derived
zero-value shortcut left the counter at zero, allowing a correctly tagged
counter-zero management frame once. IEEE 802.11-2012, 11.4.4.4 and 11.4.4.6,
requires initializing from the KDE and rejecting received IPNs at or below
that value. This is an intentional correction to the vendor behavior;
radare2 locates its zero shortcut at `vif_mgmt_add_key + 0x1b4`.

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

### PHY Interrupt Ownership

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

The selected RF channel getter samples both aligned channel words before either
output store. The backing storage is explicitly word aligned, avoiding byte
loads through its packed halfword view. Its index argument remains unused.
The gain-index helper clamps
signed input to -10 through 22 and writes back only when clamping; valid input
is not rewritten. The output always receives the resulting low byte.

The writable 50-byte `txpwr_vs_rate_table` starts with value 20, not 19, at
indices 24 and 44 (MCS 4 in rows 2 and 4). These are initialization defaults;
later configuration and table updates retain their existing ownership. This
comparison uses `phy.c.o` and `phy_trpc.c.o` from the separately documented RF
backend, not the older WiFi archive as evidence for a newer ABI. The compact
WiFi table adapter remains unchanged. Native contract tests and linked-image
checks do not establish over-the-air behavior or readiness to flash.

### TPC Channel-offset Callbacks

The pinned WiFi channel-offset updater narrows each scaled offset to a signed
byte before passing it through C varargs. Its two messages contain real CRLF
bytes. The printer slot is read again for each of the 14 channel messages and
for completion, so a callback replacement is observed on the next message.
The Nim adapter retains its existing cached-offset readback and nil-printer
guard. Its final PHY hook remains a no-op, matching the pinned SDK helper;
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
readiness. Multitask scheduling, workqueue/timer stubs and mutex scheduling
remain outside this batch. Timeout objects and task notifications are reviewed
separately below.

### Timeout Objects And Task Notifications

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

`tools/test_wifi_element_notify.py` and `tools/test_wifi_notifier_next.py` cover
the callback ABI, result values, traversal and cleanup. Compiled RV32 unit checks
exercise the exported C entry points with non-throwing callbacks. These checks
do not establish complete callback bounds or hardware readiness.

### TX Snapshot Boundaries

The pinned `txu_cntrl_frame_build` builds MAC/security/SNAP headers backwards
from its second argument. Payload addresses and lengths are separate descriptor
arrays at offsets 52/68; the end of the inline header is not a payload pointer.
The builder's address mapping, sequence handling, SNAP boundary and untouched
Duration/ID match the reviewed vendor path and are unchanged here.

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

The modem channel helper programs the inverse-carrier divider at modem 84C
and the full low-16-bit center/primary ratio at 8EC as separate values. Its
sideband selectors and bandwidth-specific modem/AGC profiles follow the
selected RF object's individual stores and masks. Returning-assert tests
retain raw field values and model RISC-V division behavior for zero divisors;
they do not change the firmware's assertion policy.

PHY channel setup has no extra RFC-entry fixed baseline or modem 888 pulse.
Initial channel programming also does not add a rate-power load after the
RF call; rate initialization occurs earlier in the vendor PHY sequence.
Descriptor caching and type-change power updates keep their existing order.

RFC channel programming retains the five vendor delays and its consecutive
strobe set/clear stores. It does not add notch-register writes. Channel-power
index arithmetic preserves the vendor's low-halfword range test, signed
division and byte-sized result. These ABI details include wrapped inputs;
they do not establish hardware support for arbitrary frequencies.

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

### Scan And Power Compensation

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
compensation into a four-unit coarse step and residual in [-2, 1], adjusts
all 18 rows and all 13 indices, and publishes WLAN power fields only. It does
not replay TXCAL or touch BZ fields. The existing index-validation guard
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
Initialization does not open a latch-service window around `wl_init`.
Elapsed-time waiting and caller diagnostics remain unchanged; the legacy
latch-enable function only records its diagnostic argument. Busy/READY state
is not manufactured by delay handling.

The WL capcode-get callback takes two byte pointers. `wl_init` passes the
same temporary byte through both arguments, matching the selected vendor
object. It reloads the live configuration after the parameter, capcode-set,
capcode-get and modem calls, and publishes completion to the current storage.
A configuration invalidated by a callout stops locally with -1; the vendor
object assumes valid storage. Callback ordering, capcode range checks,
parameter status and cold/restore selection are retained.

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
