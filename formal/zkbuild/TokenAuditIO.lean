import AuditIO
import BinaryTokenEmbedded

namespace ZkBuild.TokenAuditIO
open CircuitShape AuditIO

def readUse (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (RangeUse.Record × Std.HashMap String Int) := do
  let [tag,reused] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid range use")
  if tag != "U" || (reused != "0" && reused != "1") then throw (IO.userError "invalid range use tag")
  let (call,cache) ← readGadgetRange file wires cache
  if reused = "1" then
    let (prior,cache) ← readGadgetRange file wires cache
    return (⟨call,some prior⟩,cache)
  return (⟨call,none⟩,cache)

def readToken (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (BinaryTokenMatrix.Record × Std.HashMap String Int) := do
  let [tag,kind,firstWire,lastWire,firstGate,lastGate,selectorStart,choiceStart,signStart,count] :=
    (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid token record")
  let kind ← number kind
  let count ← number count
  if tag != "T" || kind > 7 || count != BinaryTokenMatrix.capacity kind then throw (IO.userError "invalid token dimensions")
  let (activeMode,cache) ← linear file wires cache
  let (position,cache) ← linear file wires cache
  let (value,cache) ← linear file wires cache
  let (length,cache) ← linear file wires cache
  let (sourceLength,cache) ← linear file wires cache
  let (positionRange,cache) ← readUse file wires cache
  let (valueRange,cache) ← readUse file wires cache
  let (lengthRange,cache) ← readUse file wires cache
  let mut cache := cache
  let mut rows := []
  for _ in [:count] do
    let [tag,extra] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid token row")
    if tag != "D" then throw (IO.userError "invalid token row tag")
    let (value,next) ← linear file wires cache
    let (address,next) ← linear file wires next
    let (remaining,next) ← linear file wires next
    let (after,next) ← linear file wires next
    let (byteRange,next) ← readUse file wires next
    let (remainingRange,next) ← readUse file wires next
    cache := next
    rows := ⟨value,address,remaining,after,byteRange,remainingRange,← number extra⟩::rows
  return (⟨kind,← number firstWire,← number lastWire,← number firstGate,← number lastGate,
    ← number selectorStart,← number choiceStart,← number signStart,activeMode,position,value,length,sourceLength,
    positionRange,valueRange,lengthRange,rows.reverse⟩,cache)
end ZkBuild.TokenAuditIO
