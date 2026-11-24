import PackedFields
import TokenAuditIO
namespace ZkBuild.PackedAuditIO
open CircuitShape AuditIO TokenAuditIO

def readPacked (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (PackedFields.Record × Std.HashMap String Int) := do
  let [tag,lowWidth,highWidth,firstGate,lastGate] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid packed field record")
  let lowWidth ← number lowWidth
  let highWidth ← number highWidth
  if tag != "F" || lowWidth = 0 || highWidth = 0 || lowWidth+highWidth > 64 then throw (IO.userError "invalid packed field dimensions")
  let (value,cache) ← linear file wires cache
  let (low,cache) ← linear file wires cache
  let (high,cache) ← linear file wires cache
  let (range,cache) ← readUse file wires cache
  return (⟨lowWidth,highWidth,← number firstGate,← number lastGate,value,low,high,range⟩,cache)
end ZkBuild.PackedAuditIO
