import SlotCompleteness

open ZkBuild

def parseOp (token : String) : Except String Op := do
  let [kindText, valueText] := token.splitOn ":" | throw "invalid operation"
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

def scalarHex (value : Int) : String := Id.run do
  let mut n := (value % Int.ofNat scalarModulus).toNat
  let mut chars := []
  let digits := "0123456789abcdef".toList.toArray
  for _ in [:64] do
    chars := (digits[n % 16]?.getD '0') :: chars
    n := n / 16
  return String.ofList chars

def main (args : List String) : IO Unit := do
  let [source, destination] := args | throw (IO.userError "usage: export_compile_witness INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let ["ZKCOMP1", countText] := (← input.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid witness input header")
  let some count := countText.toNat? | throw (IO.userError "invalid program count")
  if count > 128 then throw (IO.userError "too many programs")
  output.putStrLn s!"ZKCOMPW1 {count} 11899"
  for _ in [:count] do
    let tokens := (← input.getLine).trimAscii.toString.splitOn " "
    if tokens.length != 16 then throw (IO.userError "expected sixteen operations")
    let ops ← match tokens.mapM parseOp with
      | .ok ops => pure ops
      | .error message => throw (IO.userError message)
    if checkProgram ops 0 != some 1 then throw (IO.userError "unsupported stack program")
    let actions := SlotCheckedTrace.actionsFor ops
    let heights := SlotCheckedTrace.heightsFor ops
    let rows := SlotWitness.rowCache actions heights
    let inputs := SlotModuleCompleteness.cachedPublicValues (F := Int) rows
    for wire in [:11899] do
      output.putStrLn (scalarHex (SlotWitness.cachedValues inputs rows wire))
  if (← input.getLine) != "" then throw (IO.userError "trailing program input")
