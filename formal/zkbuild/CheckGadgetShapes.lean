import GadgetShape

open ZkBuild ZkBuild.CircuitShape

private def number (text : String) : IO Nat :=
  match text.toNat? with
  | some n => pure n
  | none => throw (IO.userError "invalid gadget number")

private def fromHex (text : String) : IO Int := do
  if text.length != 64 then throw (IO.userError "invalid scalar encoding")
  let mut result := 0
  for ch in text.toList do
    let n := ch.toNat
    let digit ← if 48 ≤ n && n ≤ 57 then pure (n-48)
      else if 97 ≤ n && n ≤ 102 then pure (n-87)
      else throw (IO.userError "invalid scalar hex")
    result := result*16+digit
  if result ≥ scalarModulus then throw (IO.userError "noncanonical gadget scalar")
  return Int.ofNat result

private def readLinear (file : IO.FS.Handle) (wires : Nat)
    (cache : Std.HashMap String Int) : IO (Linear × Std.HashMap String Int) := do
  let fields := (← file.getLine).trimAscii.toString.splitOn " "
  let count::terms := fields | throw (IO.userError "missing linear combination")
  let count ← number count
  if count != terms.length || count > 4096 then throw (IO.userError "invalid term count")
  let mut result := []
  let mut cache := cache
  for term in terms do
    let [wire,coefficient] := term.splitOn ":" | throw (IO.userError "invalid matrix term")
    let wire ← number wire
    if wire ≥ wires then throw (IO.userError "invalid wire index")
    let value ← match cache[coefficient]? with
      | some value => pure value
      | none => fromHex coefficient
    cache := cache.insert coefficient value
    result := (wire,value)::result
  return (result.reverse,cache)

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_gadget_shapes BUNDLE")
  let file ← IO.FS.Handle.mk path .read
  let header := (← file.getLine).trimAscii.toString.splitOn " "
  let [magic,count] := header | throw (IO.userError "invalid gadget bundle header")
  if magic != "ZKGADGETS1" then throw (IO.userError "invalid gadget bundle magic")
  let count ← number count
  if count != GadgetShape.requiredCases.length then throw (IO.userError "incomplete gadget coverage")
  let mut cache : Std.HashMap String Int := {}
  let mut total := 0
  for index in [:count] do
    let fields := (← file.getLine).trimAscii.toString.splitOn " "
    let [kind,width,literal] := fields | throw (IO.userError "invalid gadget case header")
    let kind ← number kind
    let width ← number width
    let literal ← fromHex literal
    if kind > 16 || width > 248 then throw (IO.userError "unsupported gadget case")
    if (kind,width,literal.toNat) != GadgetShape.requiredCases[index]! then
      throw (IO.userError "gadget case differs from required coverage")
    let expected := GadgetShape.artifact kind width literal.toNat
    let dims := (← file.getLine).trimAscii.toString.splitOn " "
    let [magic,wires,publicCount,gates,outputs] := dims | throw (IO.userError "invalid matrix header")
    if magic != "ZKR1CS1" then throw (IO.userError "invalid matrix magic")
    let wires ← number wires
    let publicCount ← number publicCount
    let gates ← number gates
    let outputs ← number outputs
    if wires > 4096 || gates > 4096 || outputs > 4096 then throw (IO.userError "oversized gadget")
    let mut actual : GadgetShape.Artifact := ⟨{ wires := wires, publicCount := publicCount },[]⟩
    for _ in [:gates] do
      let (a,next) ← readLinear file wires cache
      let (b,next) ← readLinear file wires next
      let (c,next) ← readLinear file wires next
      cache := next
      actual := { actual with shape.gates := actual.shape.gates.push ⟨a,b,c⟩ }
    let mut returned := []
    for _ in [:outputs] do
      let (output,next) ← readLinear file wires cache
      cache := next
      returned := output::returned
    actual := { actual with outputs := returned.reverse }
    if !GadgetShape.conforms actual expected then
      throw (IO.userError s!"gadget {index}: matrix or returned expressions differ")
    total := total+gates
  if (← file.getLine) != "" then throw (IO.userError "trailing gadget data")
  IO.println s!"Nim gadget matrix conformance PASS: {count} cases, {total} constraints"
