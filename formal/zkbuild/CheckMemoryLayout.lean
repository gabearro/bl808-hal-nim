import MemoryPacking

open ZkBuild ZkBuild.CircuitShape

private def number (text : String) : IO Nat :=
  match text.toNat? with
  | some n => pure n
  | none => throw (IO.userError "invalid integer")

private def scalar (text : String) : IO Int := do
  if text.length != 64 then throw (IO.userError "invalid scalar encoding")
  let mut n := 0
  for ch in text.toList do
    let c := ch.toNat
    let digit ← if 48 ≤ c && c ≤ 57 then pure (c-48)
      else if 97 ≤ c && c ≤ 102 then pure (c-87)
      else throw (IO.userError "invalid scalar hex")
    n := 16*n+digit
  if n ≥ scalarModulus then throw (IO.userError "noncanonical scalar")
  return Int.ofNat n

private def linear (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (Linear × Std.HashMap String Int) := do
  let fields := (← file.getLine).trimAscii.toString.splitOn " "
  let count::terms := fields | throw (IO.userError "missing linear expression")
  let count ← number count
  if count != terms.length || count > 1024 then throw (IO.userError "invalid linear term count")
  let mut out := []
  let mut cache := cache
  for term in terms do
    let [wire,value] := term.splitOn ":" | throw (IO.userError "invalid matrix term")
    let wire ← number wire
    if wire ≥ wires then throw (IO.userError "matrix wire out of bounds")
    let coefficient ← match cache[value]? with
      | some old => pure old
      | none => scalar value
    cache := cache.insert value coefficient
    out := (wire,coefficient)::out
  return (out.reverse,cache)

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_memory_layout MATRIX")
  let file ← IO.FS.Handle.mk path .read
  let [magic,count] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid layout header")
  if magic != "ZKMEMLAYOUT1" then throw (IO.userError "invalid layout magic")
  let count ← number count
  if count != MemoryPacking.cases.length then throw (IO.userError "missing layout cases")
  let mut seen := []
  let mut cache : Std.HashMap String Int := {}
  for _ in [:count] do
    let [tag,a,t,v] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid layout dimensions")
    if tag != "C" then throw (IO.userError "invalid layout tag")
    let a ← number a
    let t ← number t
    let v ← number v
    if a > 64 || t > 64 || v > 64 then throw (IO.userError "layout width out of bounds")
    let (packed,next) ← linear file 6 cache
    let (order,next) ← linear file 6 next
    cache := next
    let actual : GadgetShape.Artifact := ⟨{ wires := 6,publicCount := 5 },[packed,order]⟩
    if !GadgetShape.conforms actual (MemoryPacking.artifact a t v) then throw (IO.userError "memory layout differs")
    seen := (a,t,v)::seen
  if seen.reverse != MemoryPacking.cases then throw (IO.userError "layout coverage differs")
  if (← file.getLine) != "" then throw (IO.userError "trailing layout data")
  IO.println s!"memory layout PASS: {count} width profiles, packing and order keys"
