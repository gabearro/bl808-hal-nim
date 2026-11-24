import FrameRowCheck
set_option autoImplicit false
namespace ZkBuild.FrameRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    ∀ g ∈ gates r, Holds values g :=
  by
    have parts := checked
    simp only [FrameRowCheck.check,Bool.and_eq_true_iff] at parts
    exact OperandRowSound.includes_sound matrix r.first r.last (gates r) parts.1.2 values satisfied

structure Meaning {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (r : FrameRowCheck.Record) : Prop where
  zero : ∀ input i, (input,i) ∈ zeros r → E values (f r.after i) = if E values input = 0 then 1 else 0
  multiply : ∀ a b i, (a,b,i) ∈ multiplies r → E values (f r.after i) = E values a * E values b
  select : ∀ test yes no i, (test,yes,no,i) ∈ selects r →
    E values (f r.after i) = E values no + E values test * (E values yes-E values no)
  equality : ∀ input i, (input,i) ∈ equalities r → E values (f r.after i) = E values input
  guard : ∀ a b, (a,b) ∈ guards r → E values a*E values b = 0

theorem meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Meaning values r := by
  have all := facts matrix r checked values satisfied
  constructor
  · intro input i member
    apply zero_sound values one input (f r.after i) (f r.reciprocals i)
    intro g gm
    apply all g
    simp only [gates,List.mem_append,List.mem_flatMap]
    exact Or.inl (Or.inl (Or.inl (Or.inl ⟨(input,i),member,gm⟩)))
  · intro a b i member
    exact (all _ (by simp only [gates,List.mem_append,List.mem_map]; exact Or.inl (Or.inl (Or.inl (Or.inr ⟨(a,b,i),member,rfl⟩))))).symm
  · intro test yes no i member
    apply select_sound values test yes no (f r.after i)
    exact all _ (by simp only [gates,List.mem_append,List.mem_map]; exact Or.inl (Or.inl (Or.inr ⟨(test,yes,no,i),member,rfl⟩)))
  · intro input i member
    apply equality_sound values one (f r.after i) input
    exact all _ (by simp only [gates,List.mem_append,List.mem_map]; exact Or.inl (Or.inr ⟨(input,i),member,rfl⟩))
  · intro a b member
    have h := all _ (by simp only [gates,List.mem_append,List.mem_map]; exact Or.inr ⟨(a,b),member,rfl⟩)
    change E values a*E values b = E values z at h
    simpa only [z,eval_constant values one,Ring.intCast_zero] using h

#print axioms facts
#print axioms meaning
end ZkBuild.FrameRowSound
