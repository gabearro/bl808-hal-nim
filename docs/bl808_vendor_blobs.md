# BL808 Vendor Blobs

This file records the provenance for vendor archives that are used as hardware
validation references or temporary bridges while the native Nim paths are being
corrected.

## Stack Audit Status

The core-entry review corrected instruction parsing in `tools/audit_wifi_stack.py`:
raw objdump encoding columns had been treated as mnemonics, hiding call and
stack-pointer instructions. Earlier raw-byte audit results require revalidation.
The corrected audit completes 87 selected RF/delay/LO roots in the HAL image
and 90 in a separate build retaining CW, without overrides. The CW chain
uses at most 144 bytes within that scoped audit. Generic `wl_init` and
RF-core initialization still have three
unresolved callback calls; their direct-chain estimates are not stack bounds.
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
LDPC TX/RX use bits 26/27, beamformee/beamformer use bits 28/29, and MU-MIMO
RX/TX use bits 30/31. Bandwidth bits must not stand in for LDPC support.
Station TX policy enables LDPC only when both the local TX capability and the
peer's HT LDPC capability are present.

`phy_get_antenna_set` uses the TX-chain count at bits 7:4, not the RX count at
bits 3:0, and returns the low byte of the resulting chain mask.
`phy_set_group_id_info` reads an 8-byte membership bitmap and 16-byte user
position array as little-endian byte sequences without requiring word alignment.

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
reporting completion. Crystal precedence is 24, 26, 32, 40, 38.4, then 52 MHz.
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
