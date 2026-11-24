import Rv32Compiler
import WasmEncoding

open ZkBuild ZkBuild.Rv32Compiler

def parseOperation (token : String) : Except String Op := do
  let [kindText, valueText] := token.splitOn ":" | throw "invalid operation token"
  let some kind := kindText.toNat? | throw "invalid operation kind"
  let some value := valueText.toNat? | throw "invalid immediate"
  if value ≥ 2^32 then throw "immediate outside word range"
  match kind with
  | 0 => return .nop
  | 1 => return .get 0
  | 2 => return .get 1
  | 3 => return .const (BitVec.ofNat 32 value)
  | 4 => return .binary .add
  | 5 => return .binary .sub
  | 6 => return .binary .mul
  | 7 => return .binary .band
  | 8 => return .binary .bor
  | 9 => return .binary .bxor
  | _ => throw "unsupported operation kind"

def inputs : List Word := [0, 1, 0x7fffffff, 0x80000000, 0xffffffff]

def main (args : List String) : IO Unit := do
  let [source, destination] := args | throw (IO.userError "usage: export_compiler INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let ["ZKCOMP1", countText] := (← input.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid compiler input header")
  let some count := countText.toNat? | throw (IO.userError "invalid program count")
  if count > 512 then throw (IO.userError "too many programs")
  output.putStrLn s!"ZKCOMP2 {count} 144 132 25"
  for _ in [:count] do
    let tokens := (← input.getLine).trimAscii.toString.splitOn " "
    if tokens.length != 16 then throw (IO.userError "expected sixteen operation slots")
    let ops ← match tokens.mapM parseOperation with
      | .ok ops => pure ops
      | .error message => throw (IO.userError message)
    if checkProgram ops 0 != some 1 then throw (IO.userError "unsupported stack program")
    let bytes := compileBytes ops
    output.putStrLn (String.intercalate " " (bytes.map fun b => toString b.toNat))
    let wasm := WasmEncoding.encodeWasm ops
    if WasmEncoding.decodeWasm wasm != some ops then throw (IO.userError "WASM codec roundtrip failed")
    output.putStrLn (String.intercalate " " (wasm.map fun b => toString b.toNat))
    let mut values : List String := []
    for a in inputs do
      for b in inputs do
        let some [result] := ZkBuild.run (fun i => if i.val = 0 then a else b) ops [] |
          throw (IO.userError "source execution failed")
        values := values ++ [toString result.toNat]
    output.putStrLn (String.intercalate " " values)
  if (← input.getLine) != "" then throw (IO.userError "trailing compiler input")
