import ByteCompileSoundness

open ZkBuild ByteCompileSoundness

def operationText : Op → String
  | .nop => "0:0"
  | .get i => s!"{i.val+1}:0"
  | .const value => s!"3:{value.toNat}"
  | .binary op => s!"{ByteCompileQueue.binaryToken op}:0"

def sampleInputs : List Word := [0, 1, 0x7fffffff, 0x80000000, 0xffffffff]

def main (args : List String) : IO Unit := do
  let [source, destination] := args | throw (IO.userError "usage: export_byte_decoder INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let ["ZKBDEC1", countText] := (← input.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid decoder input header")
  let some count := countText.toNat? | throw (IO.userError "invalid decoder count")
  if count > 512 then throw (IO.userError "too many decoder fixtures")
  output.putStrLn s!"ZKBDEC2 {count}"
  for _ in [:count] do
    let tokens := (← input.getLine).trimAscii.toString.splitOn " "
    if tokens.length > 160 then throw (IO.userError "oversized WASM fixture")
    let mut wasm : List (Fin 256) := []
    for token in tokens do
      let some value := token.toNat? | throw (IO.userError "invalid byte")
      if small : value < 256 then wasm := wasm ++ [⟨value, small⟩]
      else throw (IO.userError "byte outside range")
    match decodeBinary wasm with
    | none => output.putStrLn "reject"
    | some decoded =>
      output.putStrLn ("accept " ++ String.intercalate " " ((paddedProgram decoded.operations).map operationText))
      let mut results : List String := []
      for a in sampleInputs do
        for b in sampleInputs do
          let some [result] := runBinary wasm (fun i => if i.val = 0 then a else b) |
            throw (IO.userError "accepted decoder fixture has undefined execution")
          results := results ++ [toString result.toNat]
      output.putStrLn (String.intercalate " " results)
  if (← input.getLine) != "" then throw (IO.userError "trailing decoder input")
