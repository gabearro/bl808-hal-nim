import AuditIO

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_source_hash AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,sources,hashes] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid source/hash header")
  if magic != "ZKSOURCEHASH1" then throw (IO.userError "invalid source/hash magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let sources ← number sources
  let hashes ← number hashes
  if wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || sources != 1 || hashes != 1 then
    throw (IO.userError "source/hash dimensions out of bounds")
  let mut matrix : Shape := { wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates }
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := { matrix with gates := matrix.gates.push ⟨a,b,c⟩ }
  let (source,nextCache) ← readSource file wires cache
  let (hash,_) ← readHash file wires nextCache
  if !BinarySourceEmbedded.checkLinked matrix source hash then
    if !BinarySourceEmbedded.check matrix source then throw (IO.userError "binary-source matrix rejected")
    if !ShaEmbedded.check matrix hash then throw (IO.userError "SHA matrix rejected")
    throw (IO.userError "source/SHA interface rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing source/hash data")
  IO.println s!"source/hash PASS: matrix={gates} capacity={source.capacity} source={source.lastGate-source.firstGate} hash={hash.lastGate-hash.firstGate}"
