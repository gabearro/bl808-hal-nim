# Wi-Fi model fuzzer

Run the deterministic host suite with the [project toolchain](getting_started.md):

```sh
make venv
.venv/bin/python tools/run_wifi_model_fuzzer.py --seed 808 --steps 256
```

The [runner](../tools/run_wifi_model_fuzzer.py) requires a passing case in
every domain and treats any skip as an error. Preserve the seed, step budget,
scenario, and smallest available trace when reporting a failure. The
`BL808_WIFI_MODEL_SEED` and `BL808_WIFI_MODEL_STEPS` environment variables
also apply when invoking a domain directly with pytest.

## Production code under test

The test fixtures compile selected Nim Wi-Fi handlers for the host and
supply deterministic clocks, allocation, message delivery, and radio events.

| Domain | Contract exercised |
| --- | --- |
| Queue | One terminal reply per accepted request and FIFO handling of saved requests under reentry, reset, and allocation failure. |
| Lower scan | Stale generations cannot affect replacements. Each admitted scan ends under fair delivery, including cancel and allocation-failure cases. |
| Timer and channel gate | Live scan dwell and pending gate work can progress. Cases cover rollover, cancel or rearm between timer pop and publication, and a dropped optional repeat probe. |
| Station loss | Newer liveness evidence suppresses a stale loss report. A current report can still admit teardown. |
| Station cleanup | Accepted disconnects progress independently of caller polling. Station-delete retries preserve the deadline and produce one terminal indication and confirmation. |

Long schedules drain under fair delivery with no new faults. That establishes
bounded progress for the explored schedules.

## IEEE 802.11-2012 checks

The independent [reference model](../tools/wifi_ieee2012_model.py) covers
passive infrastructure scanning and SA Query responses. It uses
802.11-2012 clauses 6.3.3 and 10.1.4 for scan selection and result projection,
and clauses 8.5.10.2–8.5.10.3 for the response action and transaction ID.
[IEEE Std 802.11-2012](https://doi.org/10.1109/IEEESTD.2012.6178212).

The scan adapter observes the production SCANU result cache for a single
legacy channel and valid non-hidden beacon. Where beacon and dwell-end
ordering is ambiguous, the fixture exercises both concrete orders. The
SA Query adapter supplies a verified request on an established protected
link and observes the response at TX handoff. Data rates, RF timing,
cryptography, DMA and actual AP behavior need the
[hardware Wi-Fi tests](wifi.md).
