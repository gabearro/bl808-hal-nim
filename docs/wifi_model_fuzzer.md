# BL808 Wi-Fi Model Fuzzer

Run the required host cases with Nim 2.2.6 and the repository test venv:

```sh
make venv
.venv/bin/python tools/run_wifi_model_fuzzer.py --seed 808 --steps 256
```

For a longer run, increase `--steps` and vary `--seed`. Preserve both values
from a failure report, along with the failing scenario and its reduced trace
or failing prefix. The corresponding `BL808_WIFI_MODEL_SEED` and
`BL808_WIFI_MODEL_STEPS` environment variables also work when running a
single domain directly with pytest. The step budget controls the number of
seeded scenarios or events per domain; it does not remove the short cases.

## BL808 Implementation Oracle

The queue, lower scan, timer, station loss, and cleanup suites compile selected production Nim
handlers into host binaries. A fake clock, allocator, message delivery and
radio/channel callbacks make schedules repeatable without a device or
network. These invariants are local implementation contracts, not IEEE
requirements:

| Suite | Properties checked |
| --- | --- |
| Queue | One terminal outcome per accepted request; host confirmation before saved work is released; FIFO ordering under callback reentry, allocation failure and reset. |
| Lower scan | A retired request cannot be admitted; held START and confirmation deliveries cannot alter a replacement; duplicate and early radio notices produce one START/END pair; fair delivery terminates each admitted scan, including cancellation and failure to allocate the next dwell. |
| Timer and channel gate | A live scan dwell reaches END even with a different scheduled context; a pending scan/ROC gate retains a path to progress; clock wrap, overlap, OOM, reset and cancel/replacement at real pop and preparation boundaries. |
| Station link loss | A stale TBTT probe loss cannot start teardown after newer liveness evidence, even from the saved queue. A current loss still reaches teardown; replacement, reset, OOM, and callback reentry during allocation retire only the affected reports. |
| Station cleanup | An accepted disconnect keeps making progress without a public waiter. A task-wide wake cannot spend the reserved station-delete retry early. Busy hardware, timer wrap, and eventual hardware recovery yield one disconnect indication and one delete confirmation. |

Short legal schedules are explored from cold and already-active states;
longer seeded schedules are drained under fair delivery (no new faults or
requests and pending timer/radio work is delivered). This checks bounded
progress in the explored schedules, not a proof of system-wide liveness.
Mutation controls restore early saved-work release, admission of retired
lower requests, loss of active dwell END, stale TBTT loss dispatch, and
the cleanup pump and retry-pacing bugs. Queue, link-loss, and cleanup
traces are reduced by deleting events.
Timer traces are cut at the first divergence and reduced
by replaying legal action deletions. Lower scan reports the first violated
invariant and reduces ordering perturbations where replay can restart from
a drained fixture. The seed and failing case remain in the output.

The link-loss suite uses the real producer, queue state transitions, and SM
handler through admission to cleanup. It compares queued owner identities,
allocation lifetime, and the teardown decisions against a bounded FIFO
model. The driver supplies simulated station replacement and observes
cleanup admission, not ME/MM completion or actual liveness over the air.

The cleanup suite starts with one admitted peer disconnect. It runs the
production public pump, cleanup transaction, dispatch handlers, and
station-delete retry callback against an independent deadline and terminal
count model. The fixture supplies the MAC clock, delete result, and
message delivery; it does not simulate RF or key RAM. The 100 ms retry
cadence is a BL808 implementation invariant, not an IEEE requirement.

## IEEE 802.11-2012 Oracle

The reference is [IEEE Std 802.11-2012](https://standards.ieee.org/ieee/802.11/4523/),
[DOI 10.1109/IEEESTD.2012.6178212](https://doi.org/10.1109/IEEESTD.2012.6178212),
the 2012 base revision as published, without subsequent amendments or editions.
`tools/wifi_ieee2012_model.py` derives results from the clauses below, without
importing the Nim port, its ABI, or the vendor oracle. The adapter supplies
decoded radio observations and compares only projected protocol outputs.

| Modeled transition or invariant | 2012 reference |
| --- | --- |
| A passive infrastructure scan selects a channel and a named or wildcard SSID and BSSID. | 6.3.3.2.2, `MLME-SCAN.request` parameter table (`BSSType`, `BSSID`, `SSID`, `ScanType`, `ChannelList`); 8.4.2.2, SSID element. |
| A received matching Beacon contributes a result; a missed or nonmatching observation does not. Passive reception is limited to the channel's listen window. | 10.1.4.1, named and wildcard scan paragraphs; 10.1.4.2, passive listen window. |
| Compare an unordered set of BSSID, SSID, and advertised channel. | 6.3.3.3.1 and 6.3.3.3.2, `BSSDescriptionSet` and `BSSDescription` tables; 8.4.2.5 and Figure 8-85 for the DSSS channel field. |
| An SA Query Response carries the SA Query category, the response action, and the corresponding request's 16-bit identifier. | 8.5.10.2/.3, Figures 8-465/8-466; Table 8-38 (category), Table 8-227 (actions); 8.2.2 (numeric octet order). |

Scope: a non-AP infrastructure STA, one 2.4 GHz legacy channel, one valid
non-hidden Beacon or no observation, and an SA Query responder with an
already-established protected link and a verified request from the current
AP. The scan observation point is the production SCANU result cache, not
a full end-to-end `MLME-SCAN.confirm`. A matching Beacon that definitively
arrives in the listen window must contribute the projected record. If only
its order relative to dwell end is unknown, the oracle permits either the
record or an empty set, and the adapter exercises and checks each concrete
ordering. The adapter decides whether the fake radio delivers the Beacon;
this does not measure dwell duration or test real RF channel isolation. The
SA Query observation point is a successful TX handoff, not an on-air frame
or a cryptographic verification. Negative controls reject a scan result for
the wrong SSID and a response with the wrong identifier.

Not modeled: AP or mesh roles, active scan/CCA timing, measurement pilots,
hidden SSIDs, multi-BSS aggregation, authentication and association state
machines, RSN negotiation, SA Query initiation/retry/timeout policy, or later
amendments. Channel gate delays, message IDs, allocator policy and the BL808's
vendor-derived SA Query retry interval/count are not 2012 assertions.

## Validation

The `BL808 Wi-Fi model fuzzer` CI job pins Nim and runs the bounded schedule.
The runner fails if Nim is missing, a domain has no passing tests, or any
required test skips. The ordinary hardware-free host job does not substitute
for this job.

### Scan Probe Timer Publication

The pinned `ke_timer.o:ke_timer_schedule+0x66/+0x7c` pops the timer and
posts a basic message. In `scan_task.o`, the dwell END handler relocates
`ke_timer_clear` at `+0x38`, and the probe handler relocates
`scan_probe_req_tx` at `+0x14` after checking only that SCAN is running.
The Nim timer dispatcher allocates a message between the pop and publication,
so a clear or rearm from that callout used to leave the old expiry eligible
to post even though its timer had been retired.

The scheduler now keeps that unpublished expiry's message ID and task under
the same lock as the pop. A same-key clear or replacement invalidates it.
The timer lifetime replay reproduces both cases at the allocation boundary,
checks that a replacement expires once at its own deadline, and confirms
that clearing a different ID or task leaves the current expiry alone.

Posting the optional repeat probe also uses fallible allocation. Dropping
that repeat does not stop the separate channel timer from ending the dwell,
so allocator pressure no longer triggers a firmware reset on that path.
The same-deadline replay checks that a following timer still posts; other
basic expiries retain their existing allocation policy. These are local
scheduling checks, not an explanation for the observed Frog retries.

### Station Cancel During a Public Scan

Pinned `sm_task.o:sm_connect_abort_req_handler+0xA6/+0xAE` sends a
zero-length lower abort and clears the scan cache. Pinned
`scan_task.o:scan_abort_req_handler+0x20` can then terminate the current
dwell. Nim can save a station scan behind an unrelated public scan, so
the bare command could stop that public dwell and clear its results.

Nim now attaches the current lower request generation to an internal
station abort only when the station owns that lower scan. Publication
and dispatch both recheck ownership. A canceled station scan that has
not acquired SCANU completes through its reserved reply on replay,
without allocating another message or starting a dwell. Host replays
cover address reuse, replacement during allocation or publication, and
independent public scan state with both busy and idle admission.

These models do not emulate RF, MAC DMA timing, received beacon cadence, or
access-point policy. Use the Ox64 UART-anchor flow in [AGENTS.md](../AGENTS.md)
and a simultaneous on-channel capture for those checks. A host replay that
reproduces a timer or queue race does not identify the trigger of an earlier
spontaneous hardware disconnect.
