import ByteCompileWitnessRefinement

open ZkBuild

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
  let [source, destination] := args | throw (IO.userError "usage: export_byte_compile_witness INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let ["ZKBCW1", countText] := (← input.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid byte-compilation witness header")
  let some count := countText.toNat? | throw (IO.userError "invalid module count")
  if count > 128 then throw (IO.userError "too many modules")
  output.putStrLn s!"ZKBCW2 {count} 21277"
  for _ in [:count] do
    let wasm ← match parseBytes (← input.getLine) with
      | .ok bytes => pure bytes
      | .error message => throw (IO.userError message)
    let some witness := ByteCompileWitness.construct wasm | throw (IO.userError "unsupported byte compilation")
    if witness.size != 21277 then throw (IO.userError "incorrect witness size")
    for value in witness do output.putStrLn (scalarHex value)
  if (← input.getLine) != "" then throw (IO.userError "trailing module input")
