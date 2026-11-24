import ModuleProgram
set_option autoImplicit false
namespace ZkBuild.ModuleProgramSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ModuleProgram
attribute [local instance] Ring.intCast Semiring.natCast

def Facts {F : Type} [Field F] (values : Nat → F) (c : Contract) : Prop :=
  if c.kind = 8 then RangeReuse.Certificate c.width (E values (c.inputs.getD 0 [])) (c.operation.call.outputs.map (E values))
  else ∃ t, GadgetAudit.describe c.operation.call c.operation.source = some t ∧
    c.operation.call.kind = c.kind ∧
    c.inputs.map (E values) = c.operation.call.inputs.map (E values) ∧
    Satisfied (GadgetAudit.model c.operation.call t).shape values ∧
    c.operation.call.outputs.map (E values) = t.outputs.map (E values)

theorem contract {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (c : Contract) (checked : checkContract matrix c = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Facts values c := by
  unfold Facts
  split
  next h => exact range_certificate matrix c h checked values one satisfied
  next h =>
    have primitive : GadgetAudit.check matrix c.operation.call c.operation.source = true := by
      have parts := (Bool.and_eq_true_iff.mp checked).2
      rw [ite_eq_right h] at parts
      exact (Bool.and_eq_true_iff.mp parts).2
    have kind : c.operation.call.kind = c.kind := by
      have parts := (Bool.and_eq_true_iff.mp checked).2
      rw [ite_eq_right h] at parts
      exact (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts).1).1
    cases description : GadgetAudit.describe c.operation.call c.operation.source with
    | none => simp [GadgetAudit.check,description] at primitive
    | some t =>
      have relation := GadgetAudit.checked_fragment_relation matrix c.operation.call c.operation.source t description primitive values satisfied
      exact ⟨t,rfl,kind,contract_inputs matrix c checked values,relation⟩

theorem state {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : State) (checked : auditState matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (∀ c ∈ s.contracts, Facts values c) ∧ ∀ r ∈ s.raw, Holds values r.value := by
  constructor
  · intro c member
    exact contract matrix c (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).1 c member) values one satisfied
  · exact raw_sound matrix s checked values satisfied

#print axioms contract
#print axioms state
end ZkBuild.ModuleProgramSound
