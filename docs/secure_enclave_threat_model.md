# BL808 Secure Enclave — Threat Model

Status: reversible (soft) mode. No eFuse is burned and secure boot is not
BootROM-enforced. This document states exactly what the framework protects and,
crucially, what it does **not** protect until a production eFuse provisioning is
performed.

## Assets

| Asset | Where it lives | Protected by |
|---|---|---|
| Device root key | secure OCRAM (vault) | TZC (group 0) + PMP (U-mode deny) |
| Derived keys / AEAD material | secure OCRAM (vault) | same |
| Application authenticity/integrity | flash (NSB1 signed) | ECDSA-P256 + SHA-256 verify |
| Rollback floor | flash ping-pong + MAC | downgrade *detection* only |
| Sealed blobs | flash | AES-CTR + HMAC, device-bound key |
| Attestation key | derived from root | vault + PKA ECDSA |

## Isolation layers (enforced, HW-validated)

1. **TZC** assigns every bus master to an auth group. Untrusted masters
   (DMA0/1, WiFi, USB, SDH, EMAC, D0, LP, …) → group 1; secure OCRAM, the
   key-bearing SEC_ENG blocks, EF_CTRL, TZC and DBG → group 0, then locked.
   This is the only thing that stops a DMA master reaching secure RAM (PMP does
   not constrain DMA). *Validated: OCRAM region grant + DMA0→group1 readback.*
2. **PMP** (E907, 7 usable entries 1–7; entry 0 BootROM-locked) gives the
   U-mode application default-deny: execute its own flash text, read/write its
   own RAM and the shared copy buffer, nothing else. Secure OCRAM and all MMIO
   are denied by omission. *Validated: 8 entries, NAPOT, entries 1–7 free.*
3. **Ecall boundary** — the U-mode app reaches services only via `ecall` with
   pointer-free, length-bounded requests copied through the shared buffer.

### Warm-boot fast-path (HBN) closure

The BootROM, before running flash, reads the word at `HbnRsv0` (`0x2000F100`)
and, if it equals `EHBN` (`0x4E424845`) or `WHBN` (`0x4E424857`), takes a
warm-boot fast path that jumps to a retained pointer — *skipping the secure
stage entirely* (no verify, no measure, no TZC lock). Verified against
`bootrom.dis` @`0x9000003a`/`0x9000004a`. A stale value from a prior HBN sleep,
or an attacker-planted magic, would otherwise let the next reset bypass the
enclave. `enclaveInit` calls `pds.hbnClearWarmBootMagic()` on every cold boot
(zeroing `HbnRsv0` and the `HbnRsv1` retained pointer), so a stale or hostile
magic can never make a *cold* boot bypass the secure stage. In enforced mode
this matters more — secure boot prevents an attacker from gaining the code-exec
needed to plant the magic, so clearing stale state on cold boot is the
load-bearing hygiene that keeps the fast path from being a bypass.
*Validated: `m0_hbn_bypass_test` — planted EHBN/WHBN cleared by both the helper
and `enclaveInit`.*

### Measured hibernation resume

The fast path is not only defanged — it can be used *safely* (`enclave/
hibernate.nim`). Before HBN sleep, `enclaveArmHbnResume(resumeEntry, appPc)`
writes a resume descriptor (entry, app PC, boot measurement, fresh TRNG nonce)
to HBN retention RAM, MACs it with `HMAC-SHA256` under a key derived from the
vault root (`vaultExpand`), and arms `HbnRsv0=EHBN` / `HbnRsv1=resumeEntry`. On
wake the secure resume path re-establishes the locked posture, re-derives the
key, and calls `enclaveValidateHbnResume()`, which resumes the app **only if the
descriptor MAC verifies** — any tamper (resume entry, app PC, or tag) is
rejected and the resume refused. The MAC key derives from the vault root, so a
measured resume is sound only with a *reproducible* root: `rkPufDerived` (SRAM-
PUF, reconstructed on wake) or `rkEfuseHwKey`; `rkSoftDev` reseeds per boot and
is for single-boot logic tests only. *Validated: `m0_hbn_resume_test` — genuine
descriptor validates and yields the verified app PC; tampered entry / PC / tag
all rejected; clear disarms.*

## Adversaries and coverage

- **Remote / online (no physical access).** Cannot reach secure RAM (no code
  path exposes it); AEAD-sealed data is confidential + authenticated; signed
  images reject tampering and wrong keys. **Covered.**
- **Local with UART/flash programmer.** Can reflash the whole device, including
  the secure stage, because in soft mode the BootROM does **not** verify the
  stage's signature. Can erase the flash rollback counter. **NOT covered in soft
  mode** — needs eFuse `sboot_en` + pubkey-hash burned.
- **JTAG-capable.** JTAG is enabled (eFuse `dbg_mode = open`, confirmed on this
  chip). Full memory read including the reconstructed root. **NOT covered** —
  needs eFuse JTAG-disable / debug-password burn.
- **Physical / invasive.** Out of scope for this framework.

## What reversible mode explicitly does NOT protect against

- **No hardware root of trust:** the BootROM runs whatever is at flash 0x0
  unsigned. Soft mode provides *measurement, integrity, and a
  production-compatible artifact pipeline*, not an enforced chain of trust.
- **JTAG-readable secrets:** with debug open, anyone with the FTDI can dump
  secure RAM. The PUF/derived root is only as secret as JTAG access.
- **Erasable rollback:** the flash counter is MAC'd (unforgeable) but erasable;
  true anti-rollback needs an eFuse monotonic counter.
- **Public PUF helper data:** by design (standard fuzzy-extractor assumption).

## Production provisioning (to convert soft → enforced)

Generated but never executed in this repo (see `efuse.computeProvisionPlan` and
`sbtool.py gen-efuse`, both `applied:false`). A production burn would set, in
`ef_data_0`:

1. `ef_sboot_en = 1`, `ef_sboot_sign_mode = 2` (ECC-secp256r1).
2. SHA-256 of the signing public key (so the BootROM enforces this stage).
3. JTAG disable (`ef_dbg_jtag_0/1_dis`) and/or `dbg_mode = closed`, plus a debug
   password if field repair is needed.
4. Optional: AES key slot(s) + read-lock for the hardware-key AES path; SF AES
   mode for encrypted XIP.
5. eFuse monotonic counter for true anti-rollback.

All of these are **irreversible**; the descriptors are produced for review and a
deliberate operator burn, never by this framework.
