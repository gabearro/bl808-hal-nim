import WasmNumericTyping

open ZkBuild.WasmNumericTyping

def main (args : List String) : IO Unit := do
  let [destination] := args | throw (IO.userError "usage: export_wasm_numeric_typing OUTPUT")
  let output ← IO.FS.Handle.mk destination .write
  output.putStrLn "ZKNUM1 1024 140"
  for code in [:1024] do
    match signature code with
    | none => output.putStrLn s!"{code} 0 0 0 0"
    | some rule => output.putStrLn s!"{code} 1 {rule.inputs} {127-rule.inputType.val} {127-rule.outputType.val}"
