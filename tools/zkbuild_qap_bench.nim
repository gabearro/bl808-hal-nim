## CPU-time comparison of QAP construction only, on the current host.
import std/[times, json]
import cps/zk/[field, fft, qap, wasm_bytes_circuit]
import zkbuild_qap_reference

const Iterations = 12
let sample = encodeByteModule([Operation(kind: opParam0), Operation(kind: opParam1),
  Operation(kind: opAdd), Operation(kind: opConst, immediate: 7), Operation(kind: opMul)])
let circuit = buildByteCircuit(sample)
let domain = powerOfTwoCeil(circuit.constraints.len)
let reference = referenceQuotient(circuit, domain)
let current = qapQuotient(circuit, domain)
if current.len != reference.len: quit("QAP benchmark length mismatch", 1)
for i in 0..<current.len:
  if not current[i].equals(reference[i]): quit("QAP benchmark coefficient mismatch", 1)
var checksum = scalar(0)
let referenceStart = cpuTime()
for _ in 0..<Iterations: checksum += referenceQuotient(circuit, domain)[0]
let referenceSeconds = (cpuTime() - referenceStart) / Iterations.float
let cosetStart = cpuTime()
for _ in 0..<Iterations: checksum += qapQuotient(circuit, domain)[0]
let cosetSeconds = (cpuTime() - cosetStart) / Iterations.float
echo %*{
  "platform": "host", "iterations": Iterations, "domain": domain,
  "constraints": circuit.constraints.len,
  "reference_2n_seconds": referenceSeconds, "coset_n_seconds": cosetSeconds,
  "qap_speedup": referenceSeconds / cosetSeconds,
  "reference_polynomial_buffer_bytes": 5 * domain * sizeof(Scalar),
  "coset_polynomial_buffer_bytes": 3 * domain * sizeof(Scalar),
  "checksum_zero": checksum.zero()
}
