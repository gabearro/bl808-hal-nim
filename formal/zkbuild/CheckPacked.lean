import PackedAuditIO
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.PackedAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_packed AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,records] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid packed-field audit")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if magic != "ZKPACKED1" || wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || records > 1048576 then
    throw (IO.userError "invalid packed-field audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  for i in [:records] do
    let (record,next) ← readPacked file wires cache
    cache := next
    if !PackedFields.check matrix record then throw (IO.userError s!"packed field {i} rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing packed-field data")
  IO.println s!"packed fields PASS: matrix={gates} splits={records}"
