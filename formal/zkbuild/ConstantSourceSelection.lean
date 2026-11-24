import ConstantSourceRules
set_option autoImplicit false
namespace ZkBuild.ConstantSourceSelection
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem flatten_zero {F : Type} [Field F] (values : Nat → F) (xs : List Linear)
    (all : ∀ x ∈ xs, E values x = 0) : E values xs.flatten = 0 := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    have add : E values (x++xs.flatten) = E values x+E values xs.flatten := eval_append values _ _
    rw [List.flatten_cons,add,all x (by simp),ih (by intro y ym; exact all y (by simp [ym]))]
    exact Semiring.add_zero 0

theorem modern_choice {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (modern : E values (field r 8) = 1) :
    ∃ i, i < 8 ∧ E values (field r 5) = (opcodes.getD i 0 : F) ∧
      ∀ j, j < 8 → E values (selected r j) = (if j = i then 1 else 0) := by
  have found : ∃ i, i < 8 ∧ E values (field r 5) = (opcodes.getD i 0 : F) := by
    by_cases yes : ∃ i, i < 8 ∧ E values (field r 5) = (opcodes.getD i 0 : F)
    · exact yes
    · have none (i : Nat) (inside : i < 8) : E values (selected r i) = 0 := by
        have ne : E values (field r 5) ≠ (opcodes.getD i 0 : F) := fun same => yes ⟨i,inside,same⟩
        simpa only [ne,ite_false,Semiring.mul_zero] using selector_value matrix tokens splits r checked values oneValue satisfied i inside
      have flat : E values (((List.range 8).map (selected r)).flatten) = 0 := by
        apply flatten_zero
        intro x xm
        obtain ⟨i,im,rfl⟩ := List.mem_map.mp xm
        exact none i (List.mem_range.mp im)
      have zero : E values (sumSelected r) = 0 := by
        have add : E values (z ++ ((List.range 8).map (selected r)).flatten) = E values z+E values (((List.range 8).map (selected r)).flatten) := eval_append values _ _
        rw [sumSelected,add,flat,z,eval_constant values oneValue]
        simp only [Ring.intCast_zero,Semiring.add_zero]
      have part := part_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) 2 (by decide)
      have equal := equality_sound values oneValue (sumSelected r) (field r 8) (part _ (by simp [parts]))
      exact False.elim (Field.zero_ne_one (zero.symm.trans (equal.trans modern)))
  obtain ⟨i,inside,opcode⟩ := found
  refine ⟨i,inside,opcode,?_⟩
  intro j jb
  have distinct : ∀ a b : Fin 8, opcodes.getD a.val 0 = opcodes.getD b.val 0 → a = b := by decide
  have same : E values (field r 5) = (opcodes.getD j 0 : F) ↔ j = i := by
    constructor
    · intro eq
      have bound (k : Nat) (kb : k < 8) : opcodes.getD k 0 < 2^64 := by
        have all : ∀ k : Fin 8, opcodes.getD k.val 0 < 2^64 := by decide
        exact all ⟨k,kb⟩
      have natural := DeclarationLocations.natural_equal (F := F) _ _ (bound i inside) (bound j jb) (opcode.symm.trans eq)
      exact (congrArg Fin.val (distinct ⟨i,inside⟩ ⟨j,jb⟩ natural)).symm
    · intro eq; subst j; exact opcode
  have value := selector_value matrix tokens splits r checked values oneValue satisfied j jb
  rw [modern,Semiring.one_mul] at value
  simpa only [same] using value

theorem token_boolean {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : ConstantSourceMatrix.Record) (splits : Splits) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (field r 8) = 0 ∨ E values (field r 8) = 1 := by
  have sh := read_shape tokens splits r (metadata matrix tokens splits r checked) 0 (by decide)
  let t := EnvelopeMatrix.token tokens (readAt r 0).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  have check := List.all_eq_true.mp tokenChecks t tm
  have all := BinaryTokenMatrix.checked_holds matrix t check values satisfied
  have kind : t.kind = 0 := sh.2.1
  have bit := boolean_sound values oneValue t.activeMode (all _ (by simp [BinaryTokenMatrix.gates,BinaryTokenMatrix.prologue,kind]))
  have image := NameGraphRoots.normalized_eval values _ _ sh.2.2.1
  change E values t.activeMode = E values (field r 8) at image
  simpa only [image] using bit

theorem selection {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (field r 0) = 1) :
    (E values (field r 1) = 0 ∧ E values (field r 8) = 0 ∧ E values (field r 9) = 1 ∧
      E values (field r 5) = ((0xd2 : Nat) : F) ∧ E values (field r 7) = 0) ∨
    (E values (field r 1) = 1 ∧ E values (field r 8) = 1 ∧ E values (field r 9) = 0 ∧
      ∃ i, i < 8 ∧ E values (field r 5) = (opcodes.getD i 0 : F) ∧
        ∀ j, j < 8 → E values (selected r j) = (if j = i then 1 else 0)) := by
  have all := holds matrix tokens splits r checked values satisfied
  have first := part_holds values tokens splits r all 0 (by decide)
  have modern := multiply_sound values (field r 0) (field r 1) (field r 8) (first _ (by simp [parts]))
  rw [active,Semiring.one_mul] at modern
  have legacy := NameGraphRoots.normalized_eval values _ _ (metadata matrix tokens splits r checked).2.2.2.2.1
  rw [eval_sub,active] at legacy
  rcases token_boolean matrix tokens tokenChecks r splits checked values oneValue satisfied with no | yes
  · have on : E values (field r 9) = 1 := by rw [legacy,no]; grind
    have last := part_holds values tokens splits r all 10 (by decide)
    have op := last (gate (field r 9) (sub (field r 5) (n 0xd2))) (by simp [parts])
    have vec := last (gate (field r 9) (field r 7)) (by simp [parts])
    change E values (field r 9)*E values (sub (field r 5) (n 0xd2)) = E values z at op
    change E values (field r 9)*E values (field r 7) = E values z at vec
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    have literal : E values (n 0xd2) = ((0xd2 : Nat) : F) :=
      (eval_constant values oneValue _).trans (Ring.intCast_natCast _)
    rw [on,eval_sub,literal,zero] at op
    rw [on,zero,Semiring.one_mul] at vec
    exact Or.inl ⟨modern.symm.trans no,no,on,by grind,vec⟩
  · have off : E values (field r 9) = 0 := by rw [legacy,yes]; grind
    exact Or.inr ⟨modern.symm.trans yes,yes,off,modern_choice matrix tokens splits r checked values oneValue satisfied yes⟩

#print axioms modern_choice
#print axioms selection
end ZkBuild.ConstantSourceSelection
