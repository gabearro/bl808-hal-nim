import ShaHashSound

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
  let [path] := args | throw (IO.userError "usage: check_sha_hash MATRIX")
  let file ← IO.FS.Handle.mk path .read
  let [magic,capacity,wires,publicCount,gates,outputs] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid SHA header")
  if magic != "ZKSHAHASH1" then throw (IO.userError "invalid SHA magic")
  let capacity ← number capacity
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let outputs ← number outputs
  if capacity > 1024 || wires > 2000000 || gates > 2000000 || outputs != 2 then
    throw (IO.userError "invalid SHA dimensions")
  let mut cache : Std.HashMap String Int := {}
  let mut actual : GadgetShape.Artifact := ⟨{ wires := wires,publicCount := publicCount },[]⟩
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    actual := { actual with shape.gates := actual.shape.gates.push ⟨a,b,c⟩ }
  let mut returned := []
  for _ in [:outputs] do
    let (value,next) ← linear file wires cache
    cache := next
    returned := value::returned
  actual := { actual with outputs := returned.reverse }
  let expected := ShaHash.artifact capacity
  if !GadgetShape.conforms actual expected then
    if wires != expected.shape.wires || publicCount != expected.shape.publicCount || gates != expected.shape.gates.size then
      throw (IO.userError s!"SHA dimensions differ: {wires}/{publicCount}/{gates} expected {expected.shape.wires}/{expected.shape.publicCount}/{expected.shape.gates.size}")
    for i in [:gates] do
      if normalizeGate actual.shape.gates[i]! != normalizeGate expected.shape.gates[i]! then
        throw (IO.userError s!"SHA gate {i} differs")
    throw (IO.userError "SHA outputs differ")
  if (← file.getLine) != "" then throw (IO.userError "trailing SHA data")
  IO.println s!"full SHA matrix PASS: capacity={capacity} constraints={gates} outputs={outputs}"
