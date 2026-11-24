import ReadOnlyAuditIO
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ReadOnlyAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_readonly AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,records] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid immutable table audit")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if magic != "ZKREADONLY1" || wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || records > 65536 then
    throw (IO.userError "invalid table audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let mut entries := 0
  let mut queries := 0
  for i in [:records] do
    let (table,next) ← readTable file wires cache
    cache := next
    if !ReadOnlyMatrix.check matrix table then throw (IO.userError s!"immutable table {i} rejected")
    entries := entries+table.entries.length
    queries := queries+table.queries.length
  if (← file.getLine) != "" then throw (IO.userError "trailing table audit data")
  IO.println s!"read-only PASS: matrix={gates} tables={records} entries={entries} queries={queries}"
