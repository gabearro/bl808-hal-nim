import SlotRowCompleteness

open ZkBuild ZkBuild.SlotRowCompleteness

def scalarHex (value : Int) : String := Id.run do
  let mut n := (value % Int.ofNat scalarModulus).toNat
  let mut chars := []
  let digits := "0123456789abcdef".toList.toArray
  for _ in [:64] do
    chars := (digits[n % 16]?.getD '0') :: chars
    n := n / 16
  return String.ofList chars

def main (args : List String) : IO Unit := do
  let [source, destination] := args | throw (IO.userError "usage: export_slot_witness INPUT OUTPUT")
  let input ← IO.FS.Handle.mk source .read
  let output ← IO.FS.Handle.mk destination .write
  let ["ZKSLOT1", countText] := (← input.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid row input header")
  let some count := countText.toNat? | throw (IO.userError "invalid row count")
  if count > 512 then throw (IO.userError "too many rows")
  output.putStrLn s!"ZKSLOTW1 {count} 753"
  for _ in [:count] do
    let [kindText, heightText, valueText] := (← input.getLine).trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid row")
    let some kind := kindText.toNat? | throw (IO.userError "invalid row")
    let some height := heightText.toNat? | throw (IO.userError "invalid row")
    let some value := valueText.toNat? | throw (IO.userError "invalid row")
    if hk : kind < 10 then
      if hh : height < 9 then
        if value ≥ 2^32 || !SlotShape.valid kind height then throw (IO.userError "unsupported row")
        let witness := canonicalRowWitness ⟨kind, hk⟩ ⟨height, hh⟩ (BitVec.ofNat 32 value)
        if witness.length != 753 then throw (IO.userError "invalid row witness length")
        for scalar in witness do output.putStrLn (scalarHex scalar)
      else throw (IO.userError "unsupported row")
    else throw (IO.userError "unsupported row")
  if (← input.getLine) != "" then throw (IO.userError "trailing row input")
