import StaticEvents
import VariableEvents
set_option autoImplicit false
namespace ZkBuild.InstructionBodyDecision
open StaticTyping StaticEvents

/-- Executable reflection of the counter-based fixed-signature body relation. -/
def fixed (rule : Rule) (pops pushes clears : Nat) : List Token → Bool
  | [] => pops == rule.inputs.length && pushes == outputCount rule && clears == rule.clears.toNat
  | .pop value :: rest => pushes == 0 && popAllowed rule pops value && fixed rule (pops+1) pushes clears rest
  | .push value :: rest => pushes == 0 && pops == rule.inputs.length && rule.output == some value &&
      fixed rule pops (pushes+1) clears rest
  | .clear :: rest => rule.clears && clears == 0 && fixed rule pops pushes (clears+1) rest

def dependent (rule : Rule) (pops pushes : Nat) : List Token → Bool
  | [] => pops == rule.inputs.length && pushes == outputCount rule
  | .pop value :: rest => pushes == 0 && (value == VariableEvents.inputType rule pops || value == 7) &&
      dependent rule (pops+1) pushes rest
  | .push value :: rest => pushes == 0 && pops == rule.inputs.length && rule.output == some value &&
      dependent rule pops (pushes+1) rest
  | .clear :: _ => false

theorem fixed_iff (rule : Rule) (tokens : List Token) (pops pushes clears : Nat) :
    fixed rule pops pushes clears tokens = true ↔ StaticEvents.Body rule pops pushes clears tokens := by
  induction tokens generalizing pops pushes clears with
  | nil => simp [fixed,StaticEvents.Body,and_assoc]
  | cons token rest ih => cases token <;> simp [fixed,StaticEvents.Body,ih,and_assoc]

theorem dependent_iff (rule : Rule) (tokens : List Token) (pops pushes : Nat) :
    dependent rule pops pushes tokens = true ↔ VariableEvents.Body rule pops pushes tokens := by
  induction tokens generalizing pops pushes with
  | nil => simp [dependent,VariableEvents.Body]
  | cons token rest ih => cases token <;> simp [dependent,VariableEvents.Body,ih,and_assoc]

#print axioms fixed_iff
#print axioms dependent_iff
end ZkBuild.InstructionBodyDecision
