## Secure stage: the first firmware the BootROM runs (flash slot 0). It verifies
## and measures the application image(s) before handing control over, and gates
## the release of secondary cores on a clean verification.
##
## In soft mode the trusted public key is embedded here; in production the same
## key's SHA-256 is burned in eFuse and the BootROM verifies this stage too —
## the inner verification logic is unchanged, which is the point of the design.
##
## Full boot-chain bring-up runs on hardware; this module is the orchestration
## the on-device test drives.

import container, verify, rollback
import ../enclave/sha256
import ../enclave/measure

type
  StageImage* = object
    flashAddr*: uint32          ## XIP/flash address of the NSB1 image
    maxLen*: uint32             ## bound for the payload read
  StageResult* = enum
    stageOk, stageVerifyFailed, stageRollbackBlocked, stageNoFloor

  BootMeasurements* = object
    count*: int
    digests*: array[4, array[32, uint8]]   ## per accepted image

proc verifyImageAt*(img: StageImage, pubx, puby: array[8, uint32],
                    floor: RollbackRecord, hdr: var Nsb1Header): StageResult =
  ## Read the NSB1 image from flash, verify its signature + payload hash, and
  ## enforce the rollback floor. The caller supplies the winning floor record.
  let p = cast[ptr UncheckedArray[uint8]](img.flashAddr)
  if parseNsb1(toOpenArray(p, 0, Nsb1HeaderSize - 1), hdr) != nsbOk:
    return stageVerifyFailed
  # Overflow-safe: bound (header + payload) against maxLen in uint64 so a
  # payloadLen near 0xFFFFFFFF can't wrap `total` to a small accepted value.
  if Nsb1HeaderSize.uint64 + hdr.payloadLen.uint64 > img.maxLen.uint64:
    return stageVerifyFailed
  let total = Nsb1HeaderSize.uint32 + hdr.payloadLen
  if verifyNsb1(toOpenArray(p, 0, total.int - 1), pubx, puby, hdr) != vrOk:
    return stageVerifyFailed
  if not accepts(floor, hdr.imageType, hdr.secVersion):
    return stageRollbackBlocked
  stageOk

proc combineMeasurement*(m: BootMeasurements): array[32, uint8] =
  ## A single boot measurement = SHA-256 over each accepted image's payload
  ## hash, in order. Binds attestation/seal keys to the full booted set.
  var ctx: Sha256Ctx
  sha256Init(ctx)
  for i in 0 ..< m.count:
    sha256Update(ctx, m.digests[i])
  sha256Final(ctx)

proc publishBootMeasurement*(m: BootMeasurements) =
  ## After the stage accepts the full image set, publish the combined measurement
  ## as THE enclave boot measurement, so attestation quotes and seal keys bind to
  ## exactly the verified set. Call before enclaveInit (which then reuses it).
  setBootMeasurement(combineMeasurement(m))
