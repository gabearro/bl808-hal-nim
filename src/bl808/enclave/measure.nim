## Boot measurement: a SHA-256 over the enclave + application image, captured
## once at boot before the partition is locked and the app runs. The digest
## feeds attestation and seal key derivation, binding sealed data to the exact
## firmware that produced it.

import sha256

type Measurement* = Sha256Digest

var bootMeasurement*: Measurement   # secure OCRAM (.bss); set once at boot
var measured = false

# Image extent from the enclave link map: flash .text/.rodata.
{.emit: """/*TYPESECTION*/
extern char __enclave_flash_start[];
extern char _sidata[];   /* end of .text/.rodata in flash (start of .data load) */
static unsigned long __img_start(void){return (unsigned long)__enclave_flash_start;}
static unsigned long __img_end(void){return (unsigned long)_sidata;}
""".}
proc imgStart(): uint {.importc: "__img_start", nodecl.}
proc imgEnd(): uint {.importc: "__img_end", nodecl.}

proc measureRegion*(startAddr, length: uint, dig: var Measurement) =
  let p = cast[ptr UncheckedArray[uint8]](startAddr)
  var ctx: Sha256Ctx
  sha256Init(ctx)
  # Hash in chunks to bound stack openArray sizes.
  var off = 0'u
  const chunk = 1024'u
  while off < length:
    let n = min(chunk, length - off)
    sha256Update(ctx, toOpenArray(p, off.int, (off + n - 1).int))
    off += n
  dig = sha256Final(ctx)

proc measureImage*(): Measurement =
  ## Hash the enclave's flash code/rodata image. Captured once; subsequent
  ## calls return the cached digest.
  if measured:
    return bootMeasurement
  let s = imgStart()
  let e = imgEnd()
  if e > s:
    measureRegion(s, e - s, bootMeasurement)
  measured = true
  bootMeasurement

proc setBootMeasurement*(m: Measurement) =
  ## Publish a measurement computed elsewhere as THE boot measurement that
  ## attestation and seal bind to. The secure stage calls this with its combined
  ## measurement over the verified image set (securestage.combineMeasurement), so
  ## "what you attest / seal to" is the whole booted image set, not just the
  ## enclave's own code hash. Must be called before measureImage()/enclaveInit so
  ## the published value wins (measureImage() returns it once `measured` is set).
  bootMeasurement = m
  measured = true

proc bootMeasurementAddr*(): uint = cast[uint](addr bootMeasurement)
  ## Address of the boot measurement in secure RAM — for the coverage audit.

proc bootMeasured*(): bool = measured
