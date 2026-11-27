# BL808 Wi-Fi channel state information research

The goal is one complex channel estimate `H[k]` per received OFDM frame
with a packet identifier and timestamp. The evaluated BL808 paths have
produced provisional estimates from raw RF samples. A direct,
packet-linked hardware coefficient readout remains open.

## What the bench established

| Capture path | Observed behavior |
| --- | --- |
| RF SRAM snapshot | Both tested taps produced changing I/Q samples in OCRAM at `0x22028000` with fresh completion. Channel 6 captures contained legacy short and long training fields. |
| Offline estimation | Two captures yielded 52-tone provisional estimates with normalized magnitude correlation of 0.936. Absolute sample clock, orientation, and physical channel response still need a known RF reference. |
| Snapshot cadence | Fifteen one-second sound-control runs yielded 2–18 decoded records per second. This is too sparse to resolve the 300 Hz and 330 Hz controls. |
| Candidate direct modem registers | The forced-RF probe saw zero control and status readback and an unchanged coefficient-window hash. This result applies to the forced-RF conditions. |
| Dedicated CSI DMA | QCC743 and BL616 provide comparison implementations. A BL808 packet trigger, ready event, descriptor or window, and coefficient format remain unverified. |

## Repeat the capture

Use [the Wi-Fi guide](wifi.md) to record antenna, channel, traffic pattern,
firmware build, and simultaneous on-channel evidence. Choose the manifest
test for the question being measured:

| Test | Evidence |
| --- | --- |
| `m0_wifi_csi_snapshot_ram_probe`, `m0_wifi_csi_snapshot` | RF capture setup and raw sample words. |
| `m0_wifi_csi_cadence`, `m0_wifi_packet_csi_trace` | Packet and capture timing, plus useful records per second. |
| `m0_wifi_direct_csi_scan_probe`, `m0_wifi_direct_csi_data_probe` | Candidate modem registers during scan or normal data reception. |

Build first with `tools/hw_validate.py --test NAME --build-only`, then
use the matching board transport in [hardware validation](hardware_validation_harness.md).
Use the repository's [sample estimator](../tools/wifi_csi_estimate.py)
and [packet trace analyzer](../tools/analyze_wifi_packet_csi_trace.py).
Report trigger and completion counts, timestamps, decoded records, gain
changes, and the corresponding over-the-air observations.

The [prior CSI notes](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/bl808_wifi_csi_research.md)
contain the register cross-checks, captures, and negative controls.
