import BinaryCompleteness

open ZkBuild ZkBuild.BinarySoundness ZkBuild.BinaryCompleteness ZkBuild.BodyCompleteness

instance (wasm : List (Fin 256)) : Decidable (SupportedWasmBinary wasm) := by
  unfold SupportedWasmBinary HeaderSoundness.HeaderValid
  infer_instance

/- Independent executable witness construction from the proved model. Decimal
   input bytes avoid relying on the Nim binary parser or hex decoder. -/
def parseBytes (line : String) : Except String (List (Fin 256)) := do
  let mut bytes := []
  for token in line.trimAscii.toString.splitOn " " do
    let some value := token.toNat? | throw "invalid byte"
    if bound : value < 256 then bytes := bytes ++ [⟨value, bound⟩]
    else throw "byte outside range"
  return bytes

def scalarHex (value : Int) : String := Id.run do
  let mut n := (value % Int.ofNat scalarModulus).toNat
  let mut chars := []
  let digits := "0123456789abcdef".toList.toArray
  for _ in [:64] do
    chars := (digits[n % 16]?.getD '0') :: chars
    n := n / 16
  return String.ofList chars

def main (args : List String) : IO Unit := do
  let [source, destination] := args | throw (IO.userError "usage: export_witness INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let header ← input.getLine
  let ["ZKWASM1", countText] := header.trimAscii.toString.splitOn " " | throw (IO.userError "invalid input header")
  let some count := countText.toNat? | throw (IO.userError "invalid module count")
  if count > 256 then throw (IO.userError "too many modules")
  output.putStrLn s!"ZKWIT1 {count} 6096"
  for _ in [:count] do
    let wasm ← match parseBytes (← input.getLine) with
      | .ok bytes => pure bytes
      | .error message => throw (IO.userError message)
    if !(decide (36 ≤ wasm.length ∧ wasm.length ≤ 156)) then throw (IO.userError "unsupported module length")
    if !(decide (SupportedWasmBinary wasm)) then throw (IO.userError "unsupported WASM binary")
    let bytes := paddedBytes wasm
    let states := statesFor bytes
    let inputs := publicValues (F := Int) wasm.length bytes
    for wire in [:6096] do output.putStrLn (scalarHex (moduleValues inputs bytes states wire))
  if (← input.getLine) != "" then throw (IO.userError "trailing module input")
