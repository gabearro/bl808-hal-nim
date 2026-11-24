## General WASM validation witness frontend. This is private prover input,
## not a proof and not a kernel-admission certificate.
import ../wasm/[types, binary, validate]
import bl808/enclave/sha256
import wasm_trace_check

type FullValidationWitness* = object
  moduleDigest*: Sha256Digest
  bytes*: seq[byte]
  module*: WasmModule
  events*: seq[ValidationEvent]
  labelChecks*, catchChecks*: bool

proc buildFullValidationWitness*(bytes: openArray[byte], labelChecks = false, catchChecks = false): FullValidationWitness =
  ## Preserve original instruction boundaries; optimization belongs after
  ## validation and must eventually carry its own translation proof.
  result.module = decodeModule(bytes, optimize = false)
  result.labelChecks = labelChecks
  result.catchChecks = catchChecks
  result.events = traceModuleValidation(result.module, labelChecks, catchChecks)
  let checked = checkValidationTraceStructure(result.module, result.events, labelChecks, catchChecks)
  if not checked.accepted:
    raise newException(ValidationError, "validation transcript rejected at event " &
      $checked.eventIndex & ": " & $checked.error)
  result.moduleDigest = sha256(bytes)
  for value in bytes: result.bytes.add value
