import DynamicTypingCheck
import ValidationEventAuditIO
set_option autoImplicit false
namespace ZkBuild.DynamicTypingAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO DynamicTypingMatrix
def read (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let count ← InstructionSourceAuditIO.header file "H" 4
  let mut stages := []
  let mut cache := cache
  for _ in [:count] do
    let kind ← InstructionSourceAuditIO.header file "Q" 3
    let (rows,next) ← readRows file wires cache
    let (flags,next) ← readRows file wires next
    let (selectors,next) ← readRows file wires next
    let (inputs,next) ← readRows file wires next
    let (outputs,next) ← readRows file wires next
    let (auxiliary,next) ← readRows file wires next
    let banks ← BodySourceAuditIO.readBanks file
    let (program,next) ← readProgram file wires next
    stages := (⟨kind,rows,flags,selectors,inputs,outputs,auxiliary,banks,program⟩ : Stage)::stages
    cache := next
  pure (⟨stages.reverse⟩,cache)
end ZkBuild.DynamicTypingAuditIO
