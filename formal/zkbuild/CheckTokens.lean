import TokenAuditIO
import BinaryTokenSound

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.TokenAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_tokens AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries,tokens] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid token audit header")
  if magic != "ZKTOKEN1" then throw (IO.userError "invalid token audit magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  let tokens ← number tokens
  if wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 || tokens > 1048576 then
    throw (IO.userError "token audit dimensions out of bounds")
  let mut matrix : Shape := { wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates }
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := { matrix with gates := matrix.gates.push ⟨a,b,c⟩ }
  let (source,next) ← readSource file wires cache
  let (hash,next) ← readHash file wires next
  let (memory,next) ← readMemory file wires next
  cache := next
  let mut inputs : List BinarySourceMatrix.Entry := []
  for _ in [:queries] do
    let (active,next) ← linear file wires cache
    let (address,next) ← linear file wires next
    let (value,next) ← linear file wires next
    cache := next
    inputs := ⟨active,address,value⟩::inputs
  let mut readers := []
  for i in [:tokens] do
    let (reader,next) ← readToken file wires cache
    cache := next
    if !BinaryTokenMatrix.check matrix reader then
      throw (IO.userError s!"token {i} kind {reader.kind} rejected")
    readers := reader::readers
  if !BinaryTokenEmbedded.check matrix source hash memory inputs.reverse readers.reverse then
    throw (IO.userError "token/source/hash/RAM interface rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing token audit data")
  IO.println s!"token audit PASS: matrix={gates} capacity={source.capacity} queries={queries} readers={tokens}"
