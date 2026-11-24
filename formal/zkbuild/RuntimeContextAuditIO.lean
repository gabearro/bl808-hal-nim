import RuntimeContextCheck
import StructuredAuditIO
set_option autoImplicit false
namespace ZkBuild.RuntimeContextAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO RuntimeContextMatrix

def read (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let count ← InstructionSourceAuditIO.header file "K" 1048576
  let mut catalog := []
  let mut cache := cache
  for _ in [:count] do
    let id ← InstructionSourceAuditIO.header file "J" 1048576
    let (record,next) ← LookupAuditIO.readLookup file wires cache
    catalog := (id,record)::catalog
    cache := next
  let count ← InstructionSourceAuditIO.header file "C" 3
  let mut stages := []
  for _ in [:count] do
    let kind ← InstructionSourceAuditIO.header file "Q" 2
    let (rows,next) ← readRows file wires cache
    let (flags,next) ← readRows file wires next
    let (selectors,next) ← readRows file wires next
    let (inputs,next) ← readRows file wires next
    let (outputs,next) ← readRows file wires next
    let (auxiliary,next) ← readRows file wires next
    let banks ← BodySourceAuditIO.readBanks file
    let (program,next) ← readProgram file wires next
    stages := (⟨kind,rows,flags,selectors,inputs,outputs,auxiliary,banks,program⟩ : DynamicTypingMatrix.Stage)::stages
    cache := next
  let [tag,first,last] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing data-count binding")
  if tag != "B" then throw (IO.userError "invalid data-count binding")
  pure (⟨catalog.reverse,stages.reverse,← number first,← number last⟩,cache)
end ZkBuild.RuntimeContextAuditIO
