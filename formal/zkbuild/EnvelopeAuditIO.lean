import EnvelopeMatrix
import LookupAuditIO
namespace ZkBuild.EnvelopeAuditIO
open CircuitShape AuditIO TokenAuditIO LookupAuditIO

def readEnvelope (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (EnvelopeMatrix.Record × Std.HashMap String Int) := do
  let [tag,fw,lw,fg,lg,count,headers,outputs] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid envelope header")
  let count ← number count
  let headers ← number headers
  let outputs ← number outputs
  if tag != "E" || count > 65536 || headers != 8 || outputs != 56 then throw (IO.userError "invalid envelope dimensions")
  let (length,cache) ← linear file wires cache
  let htag::ids := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing header token indices")
  if htag != "H" || ids.length != 8 then throw (IO.userError "invalid header token indices")
  let headerTokens ← ids.mapM number
  let mut cache := cache
  let mut rows := []
  for _ in [:count] do
    let [tag,idToken,sizeToken,wordToken,standard,aggregate] := (← file.getLine).trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid envelope row")
    if tag != "J" then throw (IO.userError "invalid envelope row tag")
    let (active,next) ← linear file wires cache
    let (id,next) ← linear file wires next
    let (start,next) ← linear file wires next
    let (body,next) ← linear file wires next
    let (size,next) ← linear file wires next
    let (finish,next) ← linear file wires next
    let (firstWord,next) ← linear file wires next
    cache := next
    let mut ranges := []
    for _ in [:6] do
      let (range,next) ← readUse file wires cache
      cache := next
      ranges := range::ranges
    let (sizePosition,next) ← linear file wires cache
    let (remaining,next) ← linear file wires next
    let (standardWire,next) ← linear file wires next
    let (rankGap,next) ← linear file wires next
    let (nextRank,next) ← linear file wires next
    let (wordGap,next) ← linear file wires next
    let (cursor,next) ← linear file wires next
    let (remainingRange,next) ← readUse file wires next
    let (rankGapRange,next) ← readUse file wires next
    let (wordGapRange,next) ← readUse file wires next
    let (lookup,next) ← readLookup file wires next
    cache := next
    rows := ⟨⟨active,id,start,body,size,finish,firstWord⟩,ranges.reverse,← number idToken,← number sizeToken,← number wordToken,
      sizePosition,remaining,standardWire,rankGap,nextRank,wordGap,cursor,remainingRange,rankGapRange,wordGapRange,lookup,
      ← number standard,← number aggregate⟩::rows
  let mut resultOutputs := []
  for _ in [:outputs] do
    let (value,next) ← linear file wires cache
    cache := next
    resultOutputs := value::resultOutputs
  return (⟨← number fw,← number lw,← number fg,← number lg,length,headerTokens,rows.reverse,resultOutputs.reverse⟩,cache)
end ZkBuild.EnvelopeAuditIO
