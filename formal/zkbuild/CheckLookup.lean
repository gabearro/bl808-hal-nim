import LookupAuditIO
import SectionPolicy
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.LookupAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_lookup AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,records] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid lookup audit")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let records ← number records
  if magic != "ZKLOOKUP1" || wires = 0 || wires > 16777216 || publicCount ≥ wires || gates > 16777216 || records > 65536 then
    throw (IO.userError "invalid lookup audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  for i in [:records] do
    let (lookup,next) ← readLookup file wires cache
    cache := next
    if lookup.columns != 2 || !LookupEmbedded.check matrix lookup then
      throw (IO.userError s!"lookup matrix {i} rejected")
    if !LookupEmbedded.checkTable lookup 16 SectionPolicy.expected then
      throw (IO.userError s!"lookup table {i} rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing lookup data")
  IO.println s!"lookup PASS: matrix={gates} records={records} exhaustive inputs=65536"
