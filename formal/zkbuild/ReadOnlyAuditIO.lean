import ReadOnlySound
import TokenAuditIO

namespace ZkBuild.ReadOnlyAuditIO
open CircuitShape AuditIO TokenAuditIO

def readEntry (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (ReadOnlyMatrix.Entry × Std.HashMap String Int) := do
  let (active,cache) ← linear file wires cache
  let (address,cache) ← linear file wires cache
  let (value,cache) ← linear file wires cache
  return (⟨active,address,value⟩,cache)

def readTable (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (ReadOnlyMatrix.Record × Std.HashMap String Int) := do
  let [tag,firstGate,preludeEnd,entries,queries,steps] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid immutable table header")
  let entries ← number entries
  let queries ← number queries
  let steps ← number steps
  if tag != "I" || entries > 1048576 || queries > 1048576 || steps != entries-1 then
    throw (IO.userError "invalid immutable table dimensions")
  let mut cache := cache
  let mut input := []
  let mut reads := []
  let mut order : List ReadOnlyMatrix.Step := []
  for _ in [:entries] do
    let (entry,next) ← readEntry file wires cache
    cache := next
    input := entry::input
  for _ in [:queries] do
    let (entry,next) ← readEntry file wires cache
    cache := next
    reads := entry::reads
  for _ in [:steps] do
    if (← file.getLine).trimAscii.toString != "D" then throw (IO.userError "invalid table order tag")
    let (delta,next) ← linear file wires cache
    let (range,next) ← readUse file wires next
    cache := next
    order := ⟨delta,range⟩::order
  let (memory,finalCache) ← readMemory file wires cache
  return (⟨← number firstGate,← number preludeEnd,input.reverse,reads.reverse,order.reverse,memory⟩,finalCache)
end ZkBuild.ReadOnlyAuditIO
