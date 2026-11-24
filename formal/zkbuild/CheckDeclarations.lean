import DeclarationFraming
import DeclarationBinding
import ReadOnlyAuditIO
import PackedAuditIO
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ModuleAuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.DeclarationAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_declarations AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens,tables,fields] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid module table audit")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  let tables ← number tables
  let fields ← number fields
  if magic != "ZKDECLARATIONS1" || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 || tables > 65536 || fields > 1048576 then
    throw (IO.userError "invalid module audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let (body,next) ← readBody file wires queries tokens cache
  cache := next
  let mut records := []
  for _ in [:tables] do
    let (table,next) ← readTable file wires cache
    cache := next
    records := table::records
  let mut packed := []
  for _ in [:fields] do
    let (record,next) ← readPacked file wires cache
    cache := next
    packed := record::packed
  let (declaration,_) ← readDeclaration file wires cache
  if !DeclarationSound.check matrix body records.reverse packed.reverse declaration then throw (IO.userError "source declaration audit rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing module audit data")
  IO.println s!"declarations PASS: matrix={gates} tokens={tokens} tables={tables} splits={fields}"
