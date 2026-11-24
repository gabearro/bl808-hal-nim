import CallRowCheck
import VariableRowSound
import VariableSelectorCheck
set_option autoImplicit false
namespace ZkBuild.CallRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem links (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true) :
    CallRowCheck.links r := by
  have parts := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  exact parts.1.1.1.1.1

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (CallRowCheck.gates r) := by
  have parts := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff] at parts
  exact OperandRowSound.includes_sound matrix _ _ _ parts.1.1.1.1.2 values satisfied

theorem heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ params results : Fin (2^32),
      E values r.heads.low = (params.val : F) ∧ E values r.heads.high = (results.val : F) ∧
      E values r.metadata.value = (params.val+2^32*results.val : Nat) := by
  have parts := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff] at parts
  have shape := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.heads parts.1.2 values one satisfied
  rw [shape.2.2.2.2.2.1] at lb eq
  rw [shape.2.2.2.2.2.2.1] at hb
  have matched := VariableSelectorCheck.point values _ _ shape.2.2.2.2.2.2.2.2.2 2
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at matched
  exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,matched.symm.trans (by simpa only [eq] using vi)⟩

theorem payload {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ tag : Fin 8, ∃ next : Fin (2^32),
      E values r.payload.low = (tag.val : F) ∧ E values r.payload.high = (next.val : F) ∧
      E values r.node.value = (tag.val+8*next.val : Nat) := by
  have parts := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff] at parts
  have shape := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.payload parts.2 values one satisfied
  rw [shape.2.2.2.2.2.2.2.1] at lb eq
  rw [shape.2.2.2.2.2.2.2.2.1] at hb
  have matched := VariableSelectorCheck.point values _ _ shape.2.2.2.2.2.2.2.2.2 5
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at matched
  exact ⟨⟨low,by simpa using lb⟩,⟨high,hb⟩,li,hi,matched.symm.trans (by simpa only [eq] using vi)⟩

theorem immediates {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ primary secondary : Fin (2^32), E values r.primary = (primary.val : F) ∧ E values r.secondary = (secondary.val : F) := by
  have parts := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff] at parts
  obtain ⟨primary,pb,pi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ parts.1.1.1.2 values one satisfied)
  obtain ⟨secondary,sb,si,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ parts.1.1.2 values one satisfied)
  exact ⟨⟨primary,pb⟩,⟨secondary,sb⟩,pi,si⟩

def Tags {F : Type} [Field F] (values : Nat → F) (r : CallRowCheck.Record) (kind : OperandEvents.Kind) : Prop :=
  InstructionRowSound.Tags values ⟨[],r.flags,[],[],default,default,0,0,0,0⟩ kind

-- This local lemma reads the actual indicator gates, not an asserted selector.
theorem indicator {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (one : values 0 = 1)
    (code number : Nat) (bound : code < 2^16) (nb : number < 2^16) [IsCharP F scalarModulus]
    (input output inverse : Linear) (image : E values input = (code : F))
    (holds : AllHold values (zeroGates (sub input (n number)) output inverse)) :
    E values output = OperandEvents.flag (decide (code = number)) := by
  have selected := zero_sound values one _ _ _ holds
  have same : (code : F) = (number : F) ↔ code = number :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans bound (by decide)) (Nat.lt_trans nb (by decide))
  have diff : (code : F)-(number : F) = 0 ↔ code = number := by constructor <;> intro h <;> grind only
  simpa only [eval_sub,n,eval_constant values one,show ((Int.ofNat number : Int) : F) = (number : F) from Ring.intCast_natCast number,image,diff,OperandEvents.flag,decide_eq_true_eq] using selected

theorem selectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code : Nat) (bound : code < 2^16) (image : E values (f r.row 8) = (code : F)) :
    ∀ j, j < 4 → E values (f r.after j) = OperandEvents.flag (decide (code = 16+j)) := by
  have all := facts matrix r checked values satisfied
  intro j jb
  have choices : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3 := by omega
  apply indicator values one code (16+j) bound (by omega) _ _ (f r.reciprocals j) image
  intro g member
  rcases choices with rfl | rfl | rfl | rfl
  all_goals exact all g (by simp only [CallRowCheck.gates,List.mem_append]; grind only)

#print axioms heads
#print axioms payload
#print axioms immediates
#print axioms selectors
end ZkBuild.CallRowSound
