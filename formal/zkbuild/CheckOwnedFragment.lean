import OwnedSoundness
import PackedAuditIO
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.PackedAuditIO ZkBuild.OwnedAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_owned_fragment AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,tables,fields,owned] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid owned fragment header")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let tables ← number tables
  let fields ← number fields
  let owned ← number owned
  if magic != "ZKOWNEDFRAG1" || wires = 0 || publicCount ≥ wires || wires > 16777216 || gates > 16777216 || tables > 65536 || fields > 1048576 || owned > 65536 then
    throw (IO.userError "invalid owned fragment dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let mut records := []
  for _ in [:tables] do
    let (table,next) ← readTable file wires cache
    cache := next
    records := table::records
  let mut packed := []
  for _ in [:fields] do
    let (field,next) ← readPacked file wires cache
    cache := next
    packed := field::packed
  let mut streams := []
  for _ in [:owned] do
    let (stream,next) ← readOwned file wires cache
    cache := next
    streams := stream::streams
  if !OwnedSound.fragmentCheck matrix records.reverse packed.reverse streams.reverse then
    throw (IO.userError "owned fragment rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing owned fragment data")
  IO.println s!"owned fragment PASS: matrix={gates} streams={streams.length}"
