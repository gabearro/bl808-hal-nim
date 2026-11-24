import ConstantSourceRead
set_option autoImplicit false
namespace ZkBuild.ConstantSourceTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Step {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (r : ConstantSourceMatrix.Record)
    (message : List Sha256.Byte) (i p length : Nat) : Prop :=
  BinaryTokenSound.Result values (EnvelopeMatrix.token tokens (readAt r i).token) message p length ∧
    E values (cursor r i) = (p : F) ∧ E values (readAt r i).cursor = ((p+length : Nat) : F) ∧
    E values (layout r i).2.2 = E values (EnvelopeMatrix.token tokens (readAt r i).token).value

theorem consecutive {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tokens : Tokens) (r : ConstantSourceMatrix.Record) (message : List Sha256.Byte)
    (i p length next nextLength : Nat) (_inside : i < 5)
    (first : Step values tokens r message i p length) (second : Step values tokens r message (i+1) next nextLength) :
    next = p+length := by
  have same : cursor r (i+1) = (readAt r i).cursor := by simp [cursor]
  have eq : ((next : Nat) : F) = ((p+length : Nat) : F) := by rw [← second.2.1,same,first.2.2.1]
  exact DeclarationLocations.natural_equal (F := F) _ _ (by have b := second.1.1; omega)
    (by have pb := first.1.1; have lb := first.1.2.1; omega) eq

def Trace {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (r : ConstantSourceMatrix.Record)
    (message : List Sha256.Byte) : Prop :=
  (∀ i, i < 6 → ∃ p length, Step values tokens r message i p length) ∧
  ∀ i p length next nextLength, i < 5 → Step values tokens r message i p length →
    Step values tokens r message (i+1) next nextLength → next = p+length

theorem checked_trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l) :
    Trace values tokens r message :=
  ⟨fun i ib => reader_semantics matrix tokens splits r checked values oneValue satisfied message decoded i ib,
    fun i p l q m ib a b => consecutive values tokens r message i p l q m ib a b⟩

#print axioms consecutive
#print axioms checked_trace
end ZkBuild.ConstantSourceTrace
