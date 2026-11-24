import StructuredCheck
import DynamicTypingAuditIO
set_option autoImplicit false
namespace ZkBuild.StructuredAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO StructuredMatrix
def read (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (Record × Std.HashMap String Int) := do
  let count ← InstructionSourceAuditIO.header file "C" 10
  let mut stages := []
  let mut cache := cache
  for _ in [:count] do
    let kind ← InstructionSourceAuditIO.header file "Q" 9
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
  let (frames,next) ← readMemory file wires cache
  let (scratch,next) ← readMemory file wires next
  pure (⟨stages.reverse,frames,scratch⟩,next)
end ZkBuild.StructuredAuditIO
