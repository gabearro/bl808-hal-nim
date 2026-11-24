import ModuleAuditIO
import EnvelopeSound
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.TokenAuditIO ZkBuild.ModuleAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_envelope AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid envelope audit")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  if magic != "ZKENVELOPE1" || wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 then
    throw (IO.userError "invalid envelope audit dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let (body,_) ← readBody file wires queries tokens cache
  if !EnvelopeSound.check matrix body.source body.hash body.memory body.queries body.tokens body.envelope then
    throw (IO.userError "authenticated envelope audit rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing envelope data")
  IO.println s!"envelope PASS: matrix={gates} sections={body.envelope.rows.length} tokens={tokens}"
