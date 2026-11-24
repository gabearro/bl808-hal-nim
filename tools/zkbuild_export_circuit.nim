## Export the production matrix, never a witness, for independent Lean checks.
import std/[os, strutils]
import cps/zk/[field, r1cs, wasm_bytes_circuit, wasm_circuit, wasm_compile_bytes]

proc main() =
  if paramCount() notin [1, 2]:
    quit("usage: zkbuild_export_circuit [bytes|validate|compile] OUTPUT", 1)
  let mode = if paramCount() == 1: "bytes" else: paramStr(1)
  var circuit: Circuit
  if mode == "bytes":
    circuit = buildByteCircuit(encodeByteModule([Operation(kind: opParam0)]))
  elif mode == "compile-bytes":
    let wasm = encodeByteModule([Operation(kind: opParam0)])
    var program: Program
    if not decodeByteProgram(wasm, program): quit("invalid sample", 1)
    circuit = buildByteCompileCircuit(wasm, encodeNative(program), program)
  else:
    var sample: Program
    sample[0] = Operation(kind: opParam0)
    let proofMode = case mode
      of "validate": pmValidate
      of "compile": pmCompile
      else: quit("unknown matrix mode", 1); pmValidate
    circuit = buildCircuit(proofMode, sample, encodeWasm(sample), encodeNative(sample))
  let output = open(paramStr(paramCount()), fmWrite)
  defer: output.close()
  output.writeLine("ZKR1CS1 ", circuit.values.len, " ", circuit.publicCount, " ", circuit.constraints.len)
  for gate in circuit.constraints:
    for side in [gate.a, gate.b, gate.c]:
      output.write($side.len)
      for term in side:
        output.write(" ", term.wire, ":")
        for b in encodeScalar(term.coefficient): output.write(toHex(b, 2).toLowerAscii())
      output.writeLine("")

main()
