import VariableSemanticCheck
set_option autoImplicit false
namespace ZkBuild.EnvironmentTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def state (rows : List OperandEvents.Row) (tags : Nat → Fin 7) : Nat → Fin 7
  | 0 => ⟨0,by decide⟩
  | i+1 => if (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .instructionBegin
      then tags i else state rows tags i

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (rows : List OperandEvents.Row)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (records : ∀ i, i < rows.length → EnvironmentRowCheck.check matrix (EnvironmentRowCheck.record tables s i) = true ∧
      EnvironmentRowSound.Tags values (EnvironmentRowCheck.record tables s i) (rows.getD i default).kind) :
    ∃ tags : Nat → Fin 7,
      (∀ i, i < rows.length → ∃ mutable : Bool,
        E values (EnvironmentRowCheck.tag (EnvironmentRowCheck.record tables s i)) = ((tags i).val : F) ∧
        E values (f (RangeUse.bits (EnvironmentRowCheck.record tables s i).packedRange) 3) = OperandEvents.flag mutable ∧
        E values (EnvironmentRowCheck.record tables s i).localQuery.value + E values (EnvironmentRowCheck.record tables s i).objectQuery.value =
          (VariableTyping.globalValue (tags i).val mutable : F)) ∧
      (∀ i, i ≤ rows.length → E values (EnvironmentRowCheck.record tables s i).before = ((state rows tags i).val : F)) ∧
      (∀ i, i < rows.length → E values (f (EnvironmentRowCheck.record tables s i).after 11) = ((state rows tags (i+1)).val : F)) := by
  classical
  let tags : Nat → Fin 7 := fun i => if h : i < rows.length then
    Classical.choose (EnvironmentRowSound.packed matrix _ (records i h).1 values one satisfied) else ⟨0,by decide⟩
  have tagImages (i : Nat) (ib : i < rows.length) : ∃ mutable : Bool,
      E values (EnvironmentRowCheck.tag (EnvironmentRowCheck.record tables s i)) = ((tags i).val : F) ∧
      E values (f (RangeUse.bits (EnvironmentRowCheck.record tables s i).packedRange) 3) = OperandEvents.flag mutable ∧
      E values (EnvironmentRowCheck.record tables s i).localQuery.value + E values (EnvironmentRowCheck.record tables s i).objectQuery.value =
        (VariableTyping.globalValue (tags i).val mutable : F) := by
    simpa only [tags,ib,dif_pos] using Classical.choose_spec (EnvironmentRowSound.packed matrix _ (records i ib).1 values one satisfied)
  have step (i : Nat) (ib : i < rows.length)
      (prior : E values (EnvironmentRowCheck.record tables s i).before = ((state rows tags i).val : F)) :
      E values (f (EnvironmentRowCheck.record tables s i).after 11) = ((state rows tags (i+1)).val : F) := by
    have t := EnvironmentRowSound.transition matrix _ (records i ib).1 values one satisfied _ (records i ib).2
    obtain ⟨_,image,_⟩ := tagImages i ib
    rw [t,prior,image]
    change (if (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .instructionBegin then
      ((tags i).val : F) else ((state rows tags i).val : F)) =
      ((if (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .instructionBegin then
        tags i else state rows tags i).val : F)
    split <;> rfl
  have invariant (i : Nat) (ib : i ≤ rows.length) : E values (EnvironmentRowCheck.record tables s i).before = ((state rows tags i).val : F) := by
    induction i with
    | zero => simp [EnvironmentRowCheck.record,state,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
    | succ i ih =>
      have next := step i (by omega) (ih (by omega))
      simpa [EnvironmentRowCheck.record,f,DeclarationMatrix.get] using next
  exact ⟨tags,tagImages,invariant,fun i ib => step i ib (invariant i (by omega))⟩

#print axioms trace
end ZkBuild.EnvironmentTraceSound
