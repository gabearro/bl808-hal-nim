import GadgetAudit

open ZkBuild ZkBuild.CircuitShape ZkBuild.GadgetAudit

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
  let [path] := args | throw (IO.userError "usage: check_gadget_audit AUDIT")
  let f ← IO.FS.Handle.mk path .read
  let header := (← f.getLine).trimAscii.toString.splitOn " "
  let [magic,wires,publicCount,gates,records] := header | throw (IO.userError "invalid audit header")
  if magic != "ZKAUDIT1" then throw (IO.userError "invalid audit magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || records > 16777216 then
    throw (IO.userError "audit dimensions out of bounds")
  let mut matrix : Shape := { wires := wires, publicCount := publicCount, gates := Array.mkEmpty gates }
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear f wires cache
    let (b,next) ← linear f wires next
    let (c,next) ← linear f wires next
    cache := next
    matrix := { matrix with gates := matrix.gates.push ⟨a,b,c⟩ }
  let mut previous : Array Record := Array.mkEmpty records
  let mut covered := 0
  let mut previousGate := 0
  let mut previousWire := 0
  let mut fresh := 0
  let mut reused := 0
  let mut literals := 0
  for index in [:records] do
    let fields := (← f.getLine).trimAscii.toString.splitOn " "
    let [tag,kind,width,firstWire,lastWire,firstGate,lastGate,reference,inputs,outputs] := fields |
      throw (IO.userError "invalid audit record")
    if tag != "R" then throw (IO.userError "invalid record tag")
    let kind ← number kind
    let width ← number width
    let firstWire ← number firstWire
    let lastWire ← number lastWire
    let firstGate ← number firstGate
    let lastGate ← number lastGate
    let reference ← number reference
    let inputs ← number inputs
    let outputs ← number outputs
    if inputs > 3 || outputs > 248 || kind > 10 || width > 248 then throw (IO.userError "invalid gadget arity")
    let mut ins := []
    let mut outs := []
    for _ in [:inputs] do
      let (value,next) ← linear f wires cache
      cache := next
      ins := value::ins
    for _ in [:outputs] do
      let (value,next) ← linear f wires cache
      cache := next
      outs := value::outs
    let record : Record := ⟨kind,width,firstWire,lastWire,firstGate,lastGate,reference,ins.reverse,outs.reverse⟩
    if firstGate < previousGate || firstWire < previousWire then throw (IO.userError "overlapping audit intervals")
    if reference != 0 && reference-1 ≥ index then throw (IO.userError "forward audit reference")
    previous := previous.push record
    previousGate := lastGate
    previousWire := lastWire
    covered := covered+lastGate-firstGate
    if kind = 8 then fresh := fresh+1
    if kind = 9 then reused := reused+1
    if kind = 10 then literals := literals+1
  if !GadgetAudit.checkAll matrix previous then
    for index in [:previous.size] do
      if !GadgetAudit.checkAt matrix previous index then
        throw (IO.userError s!"gadget record {index} rejected (kind {previous[index]!.kind})")
    throw (IO.userError "gadget audit rejected")
  if (← f.getLine) != "" then throw (IO.userError "trailing audit data")
  IO.println s!"gadget audit PASS: matrix={gates} records={records} covered={covered} unclassified={gates-covered} ranges={fresh} reused={reused} literals={literals}"
