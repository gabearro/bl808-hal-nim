# SRAM PUF

The BL808 M0 experiments use early OCRAM power-up state to derive a
reproducible key with helper data. The selected experimental window is
4 KiB at `0x22022000`. Build the capture firmware with its PUF linker
profile so code, data, and stack leave the sampled OCRAM available.

## Bench evidence

On one Ox64, the selected window had 0 differing bits out of 32,768 against
the majority template across six cold boots after roughly three seconds
without power. The measured one-bit population was 30.2%. The selected
bits also held across the longer power-off check of roughly a minute.
Four cold-boot derivations produced the same root digest. Other OCRAM
contents changed across boots. These measurements establish repeatability
for that board and leave inter-device uniqueness, aging, temperature
range, and population-level entropy unmeasured.

Early boot uses the first 4 KiB of OCRAM as scratch, and the observed
`0x22028000` region was deterministic. Use the selected window or measure
a replacement from scratch. A target reset, UART reboot, or adapter
reconnect can preserve the SRAM state and cannot substitute for a cold
power cycle.

## Capture, enroll, and check

```sh
.venv/bin/python tools/hw_validate.py --test m0_puf_capture --build-only
.venv/bin/python tools/hw_validate.py --test m0_puf_root_test --build-only
```

Use the [hardware harness](hardware_validation_harness.md) to install the
appropriate capture or root-check image. Use [puf_collect.py](../tools/puf/puf_collect.py)
for captures, [puf_analyze.py](../tools/puf/puf_analyze.py) for stability
analysis, and [puf_enroll.py](../tools/puf/puf_enroll.py) for per-device
helper data. The [Nim reconstruction code](../src/bl808/puf/reconstruct.nim)
consumes the helper data. Keep raw samples, device-specific material, and
run output in ignored local storage.

See the [enclave threat model](secure_enclave_threat_model.md) for the
isolation assumptions around a reconstructed root.
