import CircuitShape
import SlotShape
import ByteCompileShape

open ZkBuild ZkBuild.CircuitShape

def hex64 (coefficient : Int) : String := Id.run do
  let mut n := (coefficient % Int.ofNat scalarModulus).toNat
  let mut chars := []
  let digits := "0123456789abcdef".toList.toArray
  for _ in [:64] do
    chars := (digits[n % 16]?.getD '0') :: chars
    n := n / 16
  return String.ofList chars

def linearLine (linear : Linear) (cache : Std.HashMap Int String) : String × Std.HashMap Int String := Id.run do
  let mut output := toString linear.length
  let mut cache := cache
  for (wire, coefficient) in linear do
    let hex := match cache[coefficient]? with
      | some value => value
      | none => hex64 coefficient
    cache := cache.insert coefficient hex
    output := output ++ s!" {wire}:{hex}"
  return (output, cache)

def main (args : List String) : IO Unit := do
  let (mode, path) ← match args with
    | [path] => pure ("bytes", path)
    | [mode, path] => pure (mode, path)
    | _ => throw (IO.userError "usage: check_circuit [bytes|validate|compile] MATRIX")
  let input ← IO.FS.Handle.mk path .read
  let shape ← match mode with
    | "bytes" => pure byteShape
    | "validate" => pure SlotShape.validateShape
    | "compile" => pure SlotShape.compileShape
    | "compile-bytes" => pure ByteCompileShape.shape
    | _ => throw (IO.userError "unknown matrix mode")
  let header := s!"ZKR1CS1 {shape.wires} {shape.publicCount} {shape.gates.size}"
  if (← input.getLine).trimAscii.toString != header then
    throw (IO.userError "circuit dimensions differ from the Lean specification")
  let mut cache : Std.HashMap Int String := {}
  for i in [:shape.gates.size] do
    let gate := shape.gates[i]!
    for side in [gate.a, gate.b, gate.c] do
      let (expected, nextCache) := linearLine side cache
      cache := nextCache
      if (← input.getLine).trimAscii.toString != expected then
        throw (IO.userError s!"matrix differs from Lean at constraint {i}")
  if (← input.getLine) != "" then throw (IO.userError "trailing circuit data")
  IO.println s!"zkbuild {mode} matrix conformance: PASS ({shape.gates.size} constraints, {shape.wires} wires)"
