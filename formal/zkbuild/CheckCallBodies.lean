import CallBodyDecision
set_option autoImplicit false
open ZkBuild

def natural (s : String) : IO Nat := match s.toNat? with
  | some n => pure n
  | none => throw (IO.userError s!"invalid natural: {s}")

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_call_bodies CASES")
  let lines := (← IO.FS.lines path).toList
  let some header := lines.head? | throw (IO.userError "missing call body header")
  let [magic,countText] := header.splitOn " " | throw (IO.userError "invalid call body header")
  if magic != "ZKCALLBODY1" then throw (IO.userError "invalid call body format")
  let expected ← natural countText
  let mut count := 0
  let mut valid := 0
  let mut invalid := 0
  for line in lines.drop 1 do
    let xs ← (line.splitOn " ").mapM natural
    let want :: pending :: tail :: np :: nr :: nt :: payload := xs | throw (IO.userError s!"short row {count}")
    if want > 1 || pending > 1 || tail > 1 || payload.length != np+nr+nt then
      throw (IO.userError s!"malformed row {count}")
    let params := payload.take np
    let results := (payload.drop np).take nr
    if params.any (· ≥ 7) || results.any (· ≥ 7) then throw (IO.userError "invalid declared type")
    let encoded := payload.drop (np+nr)
    let tokens ← encoded.mapM fun n => do
      if n < 8 then pure (StaticEvents.Token.pop n)
      else if n < 15 then pure (StaticEvents.Token.push (n-8))
      else if n == 15 then pure StaticEvents.Token.clear
      else throw (IO.userError s!"invalid token: {n}")
    let got := CallBodyDecision.check params results (pending == 1) false (tail == 1) tokens
    if got != (want == 1) then throw (IO.userError s!"call body disagreement at row {count}: expected={want} got={got}")
    if got then valid := valid+1 else invalid := invalid+1
    count := count+1
  if count != expected then throw (IO.userError "call body count mismatch")
  IO.println s!"call bodies PASS: cases={count} accepted={valid} rejected={invalid}"
