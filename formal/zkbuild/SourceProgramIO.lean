import SourceProgram
set_option autoImplicit false
namespace ZkBuild.SourceProgramIO
open CircuitShape AuditIO ModuleContextAuditIO

def readProgram (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (SourceProgram.Program × Std.HashMap String Int) := do
  let [tag,first,last,count,blocks] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid source program header")
  let count ← number count
  let blocks ← number blocks
  if tag != "P" || count > 1048576 || blocks > 1048576 then throw (IO.userError "invalid source program dimensions")
  let mut ops := []
  let mut cache := cache
  for _ in [:count] do
    let (op,next) ← readOperation file wires cache
    ops := op::ops
    cache := next
  let mut helpers := []
  for _ in [:blocks] do
    let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing source helper")
    if tag != "X" || fields.length != 6 then throw (IO.userError "invalid source helper")
    let ns ← fields.mapM number
    helpers := (⟨ns.getD 0 0,ns.getD 1 0,ns.getD 2 0,ns.getD 3 0,ns.getD 4 0,ns.getD 5 0⟩ : SourceProgram.Block)::helpers
  pure (⟨⟨← number first,← number last,ops.reverse⟩,helpers.reverse⟩,cache)
end ZkBuild.SourceProgramIO
