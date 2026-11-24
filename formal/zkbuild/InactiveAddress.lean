import VariableSelectorCheck
set_option autoImplicit false
namespace ZkBuild.InactiveAddress
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Term where
  coefficient : Int
  input : Linear
  product : Linear
  deriving Inhabited
structure Record where
  active : Linear
  address : Linear
  terms : List Term
  first : Nat
  last : Nat
  deriving Inhabited
def sum (terms : List Term) : Linear := terms.flatMap (fun t => scale t.product t.coefficient)
def gates (r : Record) : List Gate := r.terms.map (fun t => mulGate r.active t.input t.product)
def check (matrix : Shape) (r : Record) : Bool :=
  decide (ModuleProgram.sameInputs [r.address] [sum r.terms]) &&
  OperandRowCheck.includes matrix r.first r.last (gates r)

theorem sum_zero {F : Type} [Field F] (values : Nat → F) (terms : List Term)
    (zero : ∀ t ∈ terms, E values t.product = 0) : E values (sum terms) = 0 := by
  induction terms with
  | nil => rfl
  | cons t rest ih =>
    have head := zero t (by simp)
    have tail := ih (fun x member => zero x (List.mem_cons_of_mem t member))
    change E values (scale t.product t.coefficient++sum rest) = _
    simp only [E,eval_append,eval_scale] at head tail ⊢
    rw [head,tail]
    grind only

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (checked : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) (inactive : E values r.active = 0) :
    E values r.address = 0 := by
  have parts := Bool.and_eq_true_iff.mp checked
  have same := VariableSelectorCheck.point values _ _ (_root_.of_decide_eq_true parts.1) 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at same
  rw [same]
  apply sum_zero
  intro t member
  have h := OperandRowSound.includes_sound matrix _ _ _ parts.2 values satisfied _
    (List.mem_map.mpr ⟨t,member,rfl⟩)
  change E values r.active*E values t.input = E values t.product at h
  simpa only [inactive,Semiring.zero_mul] using h.symm

#print axioms sum_zero
#print axioms sound
end ZkBuild.InactiveAddress
