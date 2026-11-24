import AuditIO

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_memory_audit AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,records] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid memory audit header")
  if magic != "ZKMEMORY1" then throw (IO.userError "invalid memory audit magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || records = 0 || records > 65536 then
    throw (IO.userError "memory audit dimensions out of bounds")
  let mut matrix : Shape := { wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates }
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := { matrix with gates := matrix.gates.push ⟨a,b,c⟩ }
  let mut rows := 0
  for i in [:records] do
    let (record,next) ← readMemory file wires cache
    cache := next
    if !MemoryEmbedded.check matrix record then throw (IO.userError s!"memory record {i} rejected")
    rows := rows+record.inputs.length
  if (← file.getLine) != "" then throw (IO.userError "trailing memory audit data")
  IO.println s!"memory audit PASS: matrix={gates} records={records} accesses={rows}"
