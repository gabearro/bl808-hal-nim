import BranchCertificate
set_option autoImplicit false
namespace ZkBuild.BranchStep
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Cursor := Fin (2^32)
def mark (kind : Kind) (code : Nat) : Bool := decide (kind = .labelCheck ∧ code = 14)
def beginning (kind : Kind) (code : Nat) : Bool := decide (kind = .instructionBegin ∧ code = 14)
def ending (kind : Kind) (code : Nat) : Bool := decide (kind = .instructionEnd ∧ code = 14)
def prepare (kind : Kind) (before head : Cursor) : Cursor :=
  if kind = .functionBegin ∨ kind = .instructionBegin then head else before
def advance (kind : Kind) (code : Nat) (ready next : Cursor) : Cursor := if mark kind code then next else ready

structure Facts {F : Type} [Field F] (values : Nat → F) (r : BranchRowCheck.Record)
    (kind : Kind) (code : Nat) (before head next : Cursor) : Prop where
  bankActive : E values r.bankQuery.active = flag (beginning kind code)
  bankAddress : E values r.bankQuery.address = flag (beginning kind code) * E values (scale (f r.row 1) (Int.ofNat (2^32))++r.primary)
  ready : E values (f r.after 4) = ((prepare kind before head).val : F)
  nodeActive : E values r.nodeQuery.active = flag (mark kind code)
  nodeAddress : E values r.nodeQuery.address = flag (mark kind code) * ((prepare kind before head).val : F)
  nextImage : E values (f r.after 9) = ((advance kind code (prepare kind before head) next).val : F)
  positive : mark kind code = true → 0 < (prepare kind before head).val
  last : E values (f r.after 8) = flag (mark kind code && decide (next.val = 0))
  finish : ending kind code = true → (advance kind code (prepare kind before head) next).val = 0

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchRowCheck.Record) (checked : BranchRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (tags : BranchCertificate.Tags values r kind code) (before head next : Cursor)
    (bi : E values r.before = (before.val : F)) (hi : E values r.bankQuery.value = (head.val : F))
    (ni : E values r.payload.high = (next.val : F)) : Facts values r kind code before head next := by
  have meaning := BranchRowSound.meaning matrix r checked values one satisfied
  have all := BranchRowSound.facts matrix r checked values satisfied
  have table := CallRowSound.indicator values one code 14 cb (by decide) _ _ (f r.reciprocals 0) ci
    (by
      intro g member
      apply all g
      simp only [gates,List.mem_append,List.mem_flatMap]
      exact Or.inl (Or.inl (Or.inl (Or.inl ⟨(sub (f r.row 8) (n 14),0),by simp [zeros],member⟩))))
  have begin := meaning.multiply (f r.flags 1) (f r.after 0) 1 (by simp [multiplies])
  have beginImage : E values (f r.after 1) = flag (beginning kind code) := by
    rw [begin,tags.2.1,table]
    by_cases k : kind = .instructionBegin <;> by_cases c : code = 14 <;> simp [flag,beginning,k,c] <;> grind only
  have prepared := meaning.select (f r.flags 0++f r.flags 1) r.bankQuery.value r.before 4 (by simp [selects])
  have readyImage : E values (f r.after 4) = ((prepare kind before head).val : F) := by
    have sum : E values (f r.flags 0++f r.flags 1) = E values (f r.flags 0)+E values (f r.flags 1) := eval_append values _ _
    rw [prepared,sum,tags.1,tags.2.1,bi,hi]
    cases kind <;> simp [prepare,flag] <;> grind only
  have update := meaning.select (f r.flags 9) r.payload.high (f r.after 4) 9 (by simp [selects])
  have nextImage : E values (f r.after 9) = ((advance kind code (prepare kind before head) next).val : F) := by
    rw [update,tags.2.2.2,ni,readyImage]
    change ((prepare kind before head).val : F) + flag (mark kind code) *
      ((next.val : F)-((prepare kind before head).val : F)) = ((if mark kind code then next else prepare kind before head).val : F)
    cases marked : mark kind code <;> simp only [marked,flag,Bool.false_eq_true,ite_false,ite_true] <;> grind only
  have nil := meaning.zero (f r.after 4) 5 (by simp [zeros])
  have endNil := meaning.zero r.payload.high 7 (by simp [zeros])
  have nextZero : (next.val : F) = 0 ↔ next.val = 0 := by
    have zero : (0 : Nat) < scalarModulus := by decide
    simpa only [Semiring.natCast_zero] using IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans next.isLt (by decide)) zero
  have last := meaning.multiply (f r.flags 9) (f r.after 7) 8 (by simp [multiplies])
  have finished := meaning.multiply (f r.flags 7) (f r.after 0) 10 (by simp [multiplies])
  have finishImage : E values (f r.after 10) = flag (ending kind code) := by
    rw [finished,tags.2.2.1,table]
    by_cases k : kind = .instructionEnd <;> by_cases c : code = 14 <;> simp [flag,ending,k,c] <;> grind only
  have interfaces := BranchRowImages.interface matrix r checked values
  constructor
  · exact interfaces.1.trans beginImage
  · rw [interfaces.2.1,meaning.multiply (f r.after 1) (scale (f r.row 1) (Int.ofNat (2^32))++r.primary) 3 (by simp [multiplies]),beginImage]
  · exact readyImage
  · exact interfaces.2.2.1.trans tags.2.2.2
  · rw [interfaces.2.2.2.1,meaning.multiply (f r.flags 9) (f r.after 4) 6 (by simp [multiplies]),tags.2.2.2,readyImage]
    rfl
  · exact nextImage
  · intro marked
    have guard := meaning.guard _ _ (by simp [guards] : (f r.flags 9,f r.after 5) ∈ guards r)
    have empty : (prepare kind before head).val ≠ 0 := by
      intro zero
      have empty : E values (f r.after 4) = 0 := by rw [readyImage,zero,Semiring.natCast_zero]
      rw [tags.2.2.2,nil,empty,ite_eq_left rfl] at guard
      change flag (F := F) (mark kind code) * 1 = 0 at guard
      simp only [marked,flag,ite_true,Semiring.one_mul] at guard
      exact Field.zero_ne_one guard.symm
    omega
  · rw [last,tags.2.2.2,endNil,ni]
    simp only [nextZero]
    change flag (F := F) (mark kind code) * (if next.val = 0 then 1 else 0) = _
    cases m : mark kind code <;> by_cases nz : next.val = 0 <;> simp [flag,nz] <;> grind only
  · intro ended
    have guard := meaning.guard _ _ (by simp [guards] : (f r.after 10,f r.after 9) ∈ guards r)
    rw [finishImage,nextImage] at guard
    simp only [ended,flag,ite_true,Semiring.one_mul] at guard
    exact NumericEvents.nat_eq (F := F) _ 0
      (by have := (advance kind code (prepare kind before head) next).isLt; simp [NumericEvents.countBound]; omega)
      (by decide) (by simpa only [Semiring.natCast_zero] using guard)

#print axioms sound
end ZkBuild.BranchStep
