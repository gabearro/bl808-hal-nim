import BinaryTokenSource

namespace ZkBuild.BinaryTokenBits
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem row_member {F : Type} [CommRing F] (values : Nat → F) (r : Record)
    (i : Nat) (present : Linear) (rows : List Row)
    (holds : AllHold values (rowsGates r i present rows))
    (item : Nat × Linear × Row) (member : item ∈ rowInputs i present rows) :
    item.1 < i+rows.length ∧ AllHold values (rowGates r item.2.2 item.1 item.2.1) := by
  induction rows generalizing i present with
  | nil => simp [rowInputs] at member
  | cons row rest ih =>
    rcases List.mem_cons.mp member with rfl | tail
    · refine ⟨by simp,?_⟩
      intro g gm; exact holds g (List.mem_append_left _ gm)
    · have tailHolds : AllHold values (rowsGates r (i+1) row.next rest) := by
        intro g gm; exact holds g (List.mem_append_right _ gm)
      have found := ih (i+1) row.next tailHolds tail
      exact ⟨by simpa [Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using found.1,found.2⟩

theorem product_zero {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (a b : Linear) (holds : Holds values (gate a b)) : E values a*E values b = 0 := by
  change E values a*E values b = E values zero at holds
  simpa [zero,eval_constant values oneValue] using holds

def Rules {F : Type} [Field F] (values : Nat → F) (r : Record) (length : Nat) (item : Nat × Linear × Row) : Prop :=
  let i := item.1
  let bytes := RangeUse.bits item.2.2.byteRange
  let bits := RangeUse.bits r.valueRange
  if leb r.kind then
    E values (atBit bytes 7) = (if i+1 < length then 1 else 0) ∧
    (∀ j, j < 7 → 7*i+j < width r.kind → E values (atBit bits (7*i+j)) =
      if i < length then E values (atBit bytes j) else E values (sign r)) ∧
    (∀ j, j < 7 → width r.kind ≤ 7*i+j → i < length → E values (atBit bytes j) = E values (sign r)) ∧
    (signed r.kind = true → length = i+1 → E values (atBit bytes 6) = E values (sign r))
  else ∀ j, j < 8 → E values (atBit bytes j) = E values (atBit bits (8*i+j))

/-- Exact payload routing, continuation bits, sign extension, and overflow bits
    for every fixed-kind reader. Byte decompositions come from checked ranges. -/
theorem checked_rules {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (normal : r.kind ≠ 7) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ length, length ≤ capacity r.kind ∧ E values r.length = (length : F) ∧
      ∀ item ∈ rowInputs 0 (active r) r.rows, Rules values r length item := by
  obtain ⟨length,bound,lenImage,_,schedule⟩ := BinaryTokenSchedule.checked_schedule matrix r accepted values oneValue satisfied
  have checked := BinaryTokenMatrix.checked_holds matrix r accepted values satisfied
  have pro : AllHold values (prologue r) := by intro g gm; exact checked g (List.mem_append_left _ gm)
  have tail : AllHold values (rowsGates r 0 (active r) r.rows) := by intro g gm; exact checked g (List.mem_append_right _ gm)
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have choices := (BinaryTokenSchedule.choice_images values oneValue r length lenImage (by omega) shape.1 pro).1
  refine ⟨length,bound,lenImage,?_⟩
  intro item member
  have found := row_member values r 0 (active r) r.rows tail item member
  have inside : item.1 < capacity r.kind := by have size := shape.2.1; omega
  have bitsHolds : AllHold values (normalBits r item.2.2 item.1 item.2.1) := by
    intro g gm
    apply found.2
    simp only [rowGates,normal,↓reduceIte,List.mem_append]
    grind
  have present := (schedule item member).1
  have next := (BinaryTokenSchedule.row_facts values oneValue r item.2.2 item.1 item.2.1 found.2).2
  have nextImage : E values item.2.2.next = (if item.1+1 < length then 1 else 0) := by
    rw [next,present,choices item.1 inside]
    exact BinaryTokenSchedule.indicator_step item.1 length
  dsimp only [Rules]
  by_cases encoded : leb r.kind = true
  · simp only [encoded,↓reduceIte]
    have continuation := equality_sound values oneValue (atBit (RangeUse.bits item.2.2.byteRange) 7) item.2.2.next
      (bitsHolds _ (by simp [normalBits,encoded]))
    refine ⟨continuation.trans nextImage,?_,?_,?_⟩
    · intro j jb inWidth
      have data : gate item.2.1 (sub (atBit (RangeUse.bits item.2.2.byteRange) j)
          (atBit (RangeUse.bits r.valueRange) (7*item.1+j))) ∈ normalBits r item.2.2 item.1 item.2.1 := by
        simp only [normalBits,encoded,↓reduceIte]
        apply List.mem_append_left
        apply List.mem_append_right
        exact List.mem_flatMap.mpr ⟨j,List.mem_range.mpr jb,by simp [inWidth]⟩
      have extension : gate (sub one item.2.1) (sub (atBit (RangeUse.bits r.valueRange) (7*item.1+j))
          (sign r)) ∈ normalBits r item.2.2 item.1 item.2.1 := by
        simp only [normalBits,encoded,↓reduceIte]
        apply List.mem_append_left
        apply List.mem_append_right
        exact List.mem_flatMap.mpr ⟨j,List.mem_range.mpr jb,by simp [inWidth]⟩
      have a := product_zero values oneValue _ _ (bitsHolds _ data)
      have b := product_zero values oneValue _ _ (bitsHolds _ extension)
      by_cases used : item.1 < length
      · rw [ite_eq_left used]
        simp only [present,ite_eq_left used,eval_sub] at a
        grind
      · rw [ite_eq_right used]
        simp only [present,ite_eq_right used,eval_sub,one,eval_constant values oneValue] at b
        grind
    · intro j jb beyond used
      have inWidth : ¬7*item.1+j < width r.kind := by omega
      have gateMember : gate item.2.1 (sub (atBit (RangeUse.bits item.2.2.byteRange) j) (sign r)) ∈
          normalBits r item.2.2 item.1 item.2.1 := by
        simp only [normalBits,encoded,↓reduceIte]
        apply List.mem_append_left
        apply List.mem_append_right
        exact List.mem_flatMap.mpr ⟨j,List.mem_range.mpr jb,by simp [inWidth]⟩
      have product := product_zero values oneValue _ _ (bitsHolds _ gateMember)
      simp only [present,ite_eq_left used,eval_sub] at product
      grind
    · intro signedKind last
      have gateMember : gate (choice r item.1) (sub (atBit (RangeUse.bits item.2.2.byteRange) 6) (sign r)) ∈
          normalBits r item.2.2 item.1 item.2.1 := by simp [normalBits,encoded,signedKind]
      have product := product_zero values oneValue _ _ (bitsHolds _ gateMember)
      rw [choices item.1 inside,ite_eq_left last,eval_sub] at product
      grind
  · have notEncoded : leb r.kind = false := by cases h : leb r.kind <;> simp_all
    simp only [notEncoded,↓reduceIte]
    intro j jb
    apply equality_sound values oneValue
    apply bitsHolds
    simp only [normalBits,notEncoded,Bool.false_eq_true,↓reduceIte]
    exact List.mem_map.mpr ⟨j,List.mem_range.mpr jb,rfl⟩

#print axioms checked_rules
end ZkBuild.BinaryTokenBits
