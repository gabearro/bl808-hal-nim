import PermutationEmbedded

open ZkBuild ZkBuild.CircuitShape

private def number (text : String) : IO Nat :=
  match text.toNat? with
  | some n => pure n
  | none => throw (IO.userError "invalid audit integer")

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
  if count != terms.length || count > 1048576 then throw (IO.userError "invalid linear term count")
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
  let [path] := args | throw (IO.userError "usage: check_permutation_audit AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,records] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid permutation header")
  if magic != "ZKPERMUTE1" then throw (IO.userError "invalid permutation magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || records = 0 || records > 65536 then
    throw (IO.userError "permutation dimensions out of bounds")
  let mut matrix : Shape := { wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates }
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := { matrix with gates := matrix.gates.push ⟨a,b,c⟩ }
  let mut previousEnd := 0
  let mut covered := 0
  for index in [:records] do
    let [tag,depth,firstWire,lastWire,firstGate,lastGate,capacity] := (← file.getLine).trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid permutation record")
    if tag != "P" then throw (IO.userError "invalid permutation tag")
    let depth ← number depth
    let firstWire ← number firstWire
    let lastWire ← number lastWire
    let firstGate ← number firstGate
    let lastGate ← number lastGate
    let capacity ← number capacity
    if depth > 20 || capacity != 2^depth || firstGate < previousEnd then
      throw (IO.userError "invalid permutation capacity or overlap")
    let mut inputs := []
    let mut outputs := []
    for _ in [:capacity] do
      let (value,next) ← linear file wires cache
      cache := next
      inputs := value::inputs
    for _ in [:capacity] do
      let (value,next) ← linear file wires cache
      cache := next
      outputs := value::outputs
    let record : PermutationEmbedded.Record := ⟨depth,firstWire,lastWire,firstGate,lastGate,inputs.reverse,outputs.reverse⟩
    if !PermutationEmbedded.check matrix record then throw (IO.userError s!"permutation record {index} rejected")
    previousEnd := lastGate
    covered := covered+lastGate-firstGate
  if (← file.getLine) != "" then throw (IO.userError "trailing permutation data")
  IO.println s!"permutation audit PASS: matrix={gates} records={records} gates={covered}"
