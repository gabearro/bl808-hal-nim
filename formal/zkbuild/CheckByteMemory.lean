import AuditIO
import BinaryReadMemory

open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_byte_memory AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,queries] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid byte memory header")
  if magic != "ZKBYTEMEM1" then throw (IO.userError "invalid byte memory magic")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let queries ← number queries
  if wires = 0 || publicCount != 2 || wires > 16777216 || gates > 16777216 || queries > 1048576 then
    throw (IO.userError "byte memory dimensions out of bounds")
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
  if !BinaryReadMemory.check matrix source hash memory inputs.reverse then
    if !BinarySourceEmbedded.checkLinked matrix source hash then throw (IO.userError "source/hash rejected")
    if !MemoryEmbedded.check matrix memory then throw (IO.userError "byte RAM rejected")
    throw (IO.userError "source/query/RAM interface rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing byte memory data")
  IO.println s!"byte memory PASS: matrix={gates} capacity={source.capacity} queries={queries} RAM={memory.inputs.length}"
