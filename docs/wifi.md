# Native Wi-Fi on BL808

The M0 host API lives in [wifi.nim](../src/bl808/wifi.nim). The native MAC
and PHY firmware is assembled by [wifi_fw.nim](../src/bl808/wifi_fw.nim).
The station and AP examples select `bl808WifiNimFw` and the native BL808
calibration profile. The WPA and lwIP application builds use C sources
from the [pinned SDK checkout](bl808_vendor_blobs.md). The vendor MAC and RF
archives serve as comparison inputs.

## Service and DMA

Wi-Fi service pumps posted firmware work and handles host completions.
Deferred station TX wakes on work publication or a channel becoming
eligible. Periodic reconciliation checks for work that still needs
service. Keep the scheduler, channel gate, and DMA completion stages
separate when tracing a delayed reply.
[Wi-Fi service](../src/bl808/wifi/facade_parts/service_futures_parts/scheduler_hook.nim) ·
[Deferred TX work](../src/bl808/wifi/fw/postponed_tx_work.nim).

The native RX DMA ring defaults to 41 slots and accepts
`WifiRxRingSlots` values from 8 through 41. FreeNetRadio defaults to eight
to leave Wi-Fi RAM for the TX pools. When comparing ring sizes under the
same workload, track ring exhaustion, packet receipt, and audio underruns
together.
[RX configuration](../src/bl808/wifi/rx_ring_config.nim) ·
[FreeNetRadio build defaults](../examples/freenetradio/freenetradio.nims).

FreeNetRadio requires separate pools for host slots and MAC DMA records.
The default software capacities are 16 host slots, 16 DMA records, and
32 packet buffers. The build overrides are `WifiTxHostSlotCount`,
`WifiTxDmaRecordCount`, and `WifiTxPacketBufferCount`.
With both TX pools at 16, a 16-slot RX build fits the 115 KiB Wi-Fi RAM
region with `--nim-define WifiRxRingSlots=16` and
`--nim-define WifiTxPacketBufferCount=28`.

- A host slot is a submission credit. The driver can return it when that
  frame's own DONE is observed.
- The MAC-visible descriptor, next pointer, and reachable packet memory
  live until the safe successor-DONE or end-of-chain reclaim point.
- Packet storage has its own capacity. Treat host-slot, MAC-record, and
  packet-buffer stalls as separate counters.
  [Pool layout](../src/bl808/wifi/ipc_host/layout.nim) ·
  [DMA ownership](../src/bl808/wifi/ipc_host/tx_dma_pool.nim).

## Rate feedback

For the normal eight-attempt singleton policy, the initial transmission and
up to four retries use the primary rate. The sixth attempt can first use
fallback. Confirmation accounts against the submitted DMA policy and
advances a fallback rate trial only once the hardware reached that rate.
A stale station or sample-table generation cannot credit a replacement
trial. The compatibility ABI still handles reports without a submitted
singleton policy.
[TX confirmation](../src/bl808/wifi/fw/tx_layer.nim) ·
[Rate counters](../src/bl808/wifi/fw/rate_control.nim).

## Validation

The [hardware manifest](../tools/hardware_validation.json) defines the
expected markers, credentials, and build flags for these bench cases.

| Case | What to check |
| --- | --- |
| `m0_wifi_nimfw_scan_hal_test` | Native init, scanning, and AP start/stop |
| `m0_wifi_hal_test` | Association with the configured bench network, status, and disconnect |
| `m0_wifi_ap_channel_sweep` | AP channel coverage on a bench with matching clients and credentials |
| `m0_wifi_connected_scan_ab` | Scanning while associated, with host and firmware observations |
| `freenetradio` | Playback, application replies, and optional profiling under load |

Begin with `--build-only` or `--dry-run`; use the
[hardware guide](hardware_validation_harness.md) for the live transport.
The [model fuzzer](wifi_model_fuzzer.md) checks scheduling and protocol
ownership cases on the host.

```sh
.venv/bin/python -m pytest -q \
  tools/test_wifi_frame_rate_feedback.py \
  tools/test_wifi_ipc_host_lifetime.py tools/test_wifi_rx_dma_ring.py
```

For the AP sweep, use a provisioned bench client and set
`BL808_WIFI_AP_BENCH_PASSWORD` in the harness environment. The test uses
the US channel plan, channels 1–11. Host tests for other frequency
encodings establish that the request can be constructed. On-air evidence
requires a permitted setup and a matching peer.

For the connected-scan test, supply `BL808_WIFI_SSID` and
`BL808_WIFI_PASSWORD`. Keep a fixed-rate HTTP or UDP echo workload running
across the control, scan, scan, control windows. Check scan confirmations,
traffic counts, and whether the run ended on a disconnect or error. The
`event=finished` marker also appears after early termination.
See the [original connected-scan protocol](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/wifi_connected_scan_ab.md).

## Measure packet loss

Compare the same board and AP, channel, workload, firmware options, and
receive deadline across runs. Retain the number of offered probes, host
replies, and underruns for each run. A MAC ACK is link-layer feedback.
The host can still miss the corresponding reply if forwarding or delivery
occurs past its receive window.

For TX, correlate software queue admission, MAC submission and DONE,
retry count, and host reception. For RX, record the ring depth together with
overflow and delivery counters. Use an on-channel monitor and match uplink
sequence number, QoS TID, and timing when distinguishing missing AP
responses from local ACK handling. A monitor can miss frames, so use fully
captured chains when making claims about individual retry sequences. Use
[Profiling](profiling.md) for CPU and playback measurements.
