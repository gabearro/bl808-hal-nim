# BL808 SRAM PUF — Findings

Goal: derive a device-unique root key from uninitialised on-chip SRAM power-up
state, with no eFuse burn. Capture firmware: `examples/m0_puf_capture.nim`
(built with `-d:bl808puf` so all firmware data/stack live in WRAM and OCRAM is
read back pristine). Collector/analyzer: `tools/puf/puf_collect.py`,
`tools/puf/puf_analyze.py`. Fuzzy extractor: `src/bl808/puf/{helper,reconstruct}.nim`.

## Region selection (measured on hardware)

OCRAM (0x2202_0000, 64 KB) is powered with M0 and readable at the earliest boot,
but not all of it is usable — per-8KB-chunk popcounts across cold boots:

| chunk | addr | behaviour |
|---|---|---|
| 0 | 0x22020000 | first 4 KB = deterministic boot scratch (RISC-V code remnants); upper half varies |
| 1 | 0x22022000 | uninitialised SRAM, ~50% popcount, varies cold-to-cold → **PUF window chosen here** |
| 2 | 0x22024000 | uninitialised |
| 3 | 0x22026000 | uninitialised |
| 4 | 0x22028000 | constant ~0 (zeroed/deterministic) — avoid |
| 5 | 0x2202A000 | varies, biased ~39% |
| 6 | 0x2202C000 | uninitialised |
| 7 | 0x2202E000 | uninitialised |

So most of OCRAM is genuine uninitialised SRAM; avoid the first 4 KB and the
0x28000 chunk. The chosen PUF window is **0x22022000, 4 KB**.

## Stability (6 cold boots, ~3 s power-off each)

- Per-bit noise vs majority reference: **0.000 %** (0 of 32768 bits flipped
  across all cold boots).
- Window bias: **30.2 % ones** (biased but well clear of 0/100 %).
- Full 64 KB hash **changed every boot** → there is fresh power-up randomness in
  OCRAM (it is not pure whole-chip retention).
- Fuzzy-extractor verdict: GO (a 256-bit key needs ~2816 strongly-stable bits;
  32768 are available, and at ~0 % noise the repetition code is barely needed).

## Bias vs remanence — RESOLVED (valid test): genuine power-up bias

A first "long power-off" attempt was INVALID — the collector grabbed the still-
running firmware's looping frame instead of waiting for an actual power cycle, so
it trivially matched the prior boot (same full hash). Fixed with
`puf_collect.py --cycle-first`, which waits for the serial port to drop (power
off) and reappear (power on) before capturing.

The corrected test, after a genuine ~60 s fully-discharged power-off:
- collector trace confirms it observed power-off then boot before capturing;
- the **full 64 KB hash is new** (0xdba1fa37, distinct from every short-cycle
  boot) → a genuinely fresh cold boot, not a stale frame;
- yet the **PUF window is bit-for-bit identical** to the short-cycle reference —
  0 of 32768 bits differ, same 30.2 % bias.

So the window's stability survives a full discharge: this is intrinsic power-up
bias, **not** remanence. Genuine SRAM PUF.

Remaining check (needs a second board, not blocking): inter-device uniqueness
(different BL808 → different pattern, ~50 % fractional Hamming distance).
Per-device reproducibility — the harder property for key derivation — is proven.

## End-to-end key derivation — MEASURED stable across cold boots

Beyond the raw-response reproducibility above, the full extraction was run on
the device: `m0_puf_root_test` (enrolled helper data from `puf_enroll.py`)
reads the real SRAM window, runs the repetition-decode fuzzy extractor + HKDF to
a 32-byte root, and prints SHA-256(root). Across **4 genuine cold boots**
(collector confirmed power-off then boot before each), the derived root hash was
**identical every time**:

    rootsha = F1FC431D 36AFB465 32DC2026 987F4403 14E2F6FF 53143A68 67E21E1A CFB5A379

So the *extracted vault root*, not just the raw SRAM, is empirically reproducible
across power cycles — the inference is now a measurement. (It also matched the
warm/SWRST boot, confirming the chosen window is untouched by the anchor/boot.)

## Practical use in the framework

`reconstruct.nim` reads the chosen window at early boot (before OCRAM bss init,
guaranteed by the PUF/secure-stage linker), majority-vote decodes via public
helper data, and HKDF-SHA256s the result into a 32-byte vault root
(`vaultInstallPufRoot`). With the measured ~0 % noise the error correction has
ample margin. Helper data is public by design; PUF is cold-boot only (warm/HBN
wake reuses the cached root). See `docs/secure_enclave_threat_model.md`.
