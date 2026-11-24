import TokenAuditIO
import LookupEmbedded

namespace ZkBuild.LookupAuditIO
open AuditIO CircuitShape

def readLookup (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (LookupEmbedded.Record × Std.HashMap String Int) := do
  let [tag,firstWire,lastWire,firstGate,lastGate,root,columns,nodes] :=
    (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid lookup header")
  let columns ← number columns
  let count ← number nodes
  if tag != "L" || columns = 0 || columns > 64 || count = 0 || count > 131071 then
    throw (IO.userError "invalid lookup dimensions")
  let (input,cache) ← linear file wires cache
  let mut cache := cache
  let mut outputs := []
  for _ in [:columns] do
    let (out,next) ← linear file wires cache
    cache := next
    outputs := out::outputs
  let (range,next) ← TokenAuditIO.readUse file wires cache
  let mut nodes := []
  for _ in [:count] do
    let tag::bit::zero::one::payload := (← file.getLine).trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid lookup node")
    if tag != "N" || payload.length != columns then throw (IO.userError "invalid lookup node arity")
    let bit ← number bit
    if bit > 16 then throw (IO.userError "invalid lookup bit")
    let mut values := []
    for value in payload do
      let some value := value.toInt? | throw (IO.userError "invalid lookup payload")
      values := value::values
    nodes := ⟨if bit = 0 then none else some (bit-1),← number zero,← number one,values.reverse⟩::nodes
  return (⟨range,← number firstWire,← number lastWire,← number firstGate,← number lastGate,
    ← number root,columns,input,outputs.reverse,nodes.reverse⟩,next)
end ZkBuild.LookupAuditIO
