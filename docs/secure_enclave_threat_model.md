# BL808 enclave threat model

The repository's reversible developer mode validates the enclave in firmware.
The boot ROM does not authenticate the initial flash stage in this mode and
debug can remain open. The hardware tests use reversible configuration
without burning eFuses.

## Protection boundary

| Asset or boundary | Mechanism and scope |
| --- | --- |
| Root and derived keys | The [vault](../src/bl808/enclave/vault.nim) holds material in secure OCRAM. Locked TZC group assignments separate supported untrusted bus masters from secure regions. PMP restricts the M0 U-mode application. |
| Application calls | The [enclave](../src/bl808/enclave/enclave.nim) uses a length-bounded `ecall` request ABI and shared buffers. Peripheral access follows the secure-stage policy. |
| Application images and attestation | The secure stage verifies signed application images and can bind the measured state to an attestation under a vault-derived key. These guarantees assume the executing secure stage is trusted. |
| Sealed data and rollback | Sealing authenticates flash contents under a device-bound key. A MAC protects the stored rollback record against modification. Full flash replacement or replay can remove or roll back that record. |

TZC and PMP cover different access paths. Hardware probes verified OCRAM
region grant and DMA0 group readback, and that the expected E907 PMP slots
were available. Unrestricted debug and a programmer who can replace the
initial flash stage remain outside this mode's trust boundary. Physical
invasive attacks and general resistance to remote compromise were outside
the bench tests.

## Hibernation

Enclave initialization clears the boot ROM's retained warm-entry magic
and pointer once the secure stage is running. The explicit measured-resume
path authenticates a retention descriptor carrying the resume entry,
application PC, boot measurement, and nonce. It re-establishes the secure
configuration and validates the descriptor before yielding the app PC.
See [hibernate.nim](../src/bl808/enclave/hibernate.nim).

A measured resume needs a reproducible root, either `rkPufDerived` or
`rkEfuseHwKey`. The `rkSoftDev` root reseeds for each boot. Clearing stale
state in enclave initialization does not protect an earlier boot ROM
decision against an attacker who can already write retention registers.

## Validation

The [hardware test manifest](../tools/hardware_validation.json) includes
`m0_enclave_services_test`, `m0_enclave_measure_bind_test`,
`m0_hbn_bypass_test`, and `m0_hbn_resume_test`. The HBN test checks a valid
descriptor and rejection after entry, PC, or tag changes. Use the standard
[hardware harness](hardware_validation_harness.md) and keep the test scope
with each result.

A production trust chain depends on authenticated boot, explicit debug
policy, and a hardware-backed rollback policy suited to the deployment.
The reversible bench results do not establish that production posture.
