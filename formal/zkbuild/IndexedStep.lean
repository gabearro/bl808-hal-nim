import IndexedCell

namespace ZkBuild.IndexedStep
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix IndexedMatrix IndexedCell
open DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem continuation {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (image : Represents values splits r d) (bound : Bounded d) (active : E values r.entry.active = 1)
    (previousHead : Nat) (previousBound : previousHead < 2^32) (previousImage : E values ph = (previousHead : F)) :
    E values r.continuing = if index ≠ 0 ∧ d.head = previousHead then 1 else 0 := by
  by_cases first : index = 0
  · have shape := metadata matrix splits r index ph po pn checked
    have zero := shape.2.2.2.2.2.2.2.2 first
    rw [zero.1]
    simp [first,z,eval_constant values oneValue]
  · have all := holds matrix splits r index ph po pn checked values satisfied
    have part : AllHold values (zeroGates (sub (address splits r).high ph) (wire r.continuationZero) (wire (r.continuationZero+1))++
      [mulGate r.entry.active (wire r.continuationZero) r.continuing]) := by
      simpa [memberParts,first] using part_holds values splits r index ph po pn all 8 (by decide)
    have zero := zero_sound values oneValue (sub (address splits r).high ph) (wire r.continuationZero) (wire (r.continuationZero+1))
      (by intro g gm; exact part g (List.mem_append_left _ gm))
    have same : E values (sub (address splits r).high ph) = 0 ↔ d.head = previousHead := by
      rw [eval_sub,image.1,previousImage]
      constructor
      · intro h
        exact natural_equal (F := F) d.head previousHead (by have b := bound.1; omega) (by omega) (by grind)
      · intro h; rw [h]; grind
    have product := multiply_sound values r.entry.active (wire r.continuationZero) r.continuing (part _ (by simp))
    rw [active,Semiring.one_mul,zero] at product
    have converted : E values r.continuing = if d.head = previousHead then 1 else 0 := by
      simpa only [same] using product
    simpa only [ne_eq,first,not_false_eq_true,true_and] using converted

theorem start_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (image : Represents values splits r d) (bound : Bounded d) (active : E values r.entry.active = 1)
    (first : E values r.continuing = 0) : d.ordinal = 0 ∧ d.cursor = d.head := by
  have all := holds matrix splits r index ph po pn checked values satisfied
  have part := part_holds values splits r index ph po pn all 9 (by decide)
  have ordinal := part (gate (start r) (address splits r).low) (by simp [memberParts])
  have cursor := part (gate (start r) (sub (cell splits r).high (address splits r).high)) (by simp [memberParts])
  change E values (start r)*E values (address splits r).low = E values z at ordinal
  change E values (start r)*E values (sub (cell splits r).high (address splits r).high) = E values z at cursor
  have startImage : E values (start r) = 1 := by rw [start,eval_sub,active,first]; grind
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [startImage,image.2.1,zero] at ordinal
  rw [startImage,eval_sub,image.2.2.1,image.1,zero] at cursor
  exact ⟨natural_equal (F := F) d.ordinal 0 (by have b := bound.2.1; omega) (by decide) (by simpa [Semiring.one_mul,Semiring.natCast_zero] using ordinal),
    natural_equal (F := F) d.cursor d.head (by have b := bound.2.2.1; omega) (by have b := bound.1; omega) (by grind)⟩

theorem continue_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (positive : 0 < index) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (image : Represents values splits r d) (bound : Bounded d)
    (continuing : E values r.continuing = 1) (previousOrdinal previousNext : Nat)
    (ob : previousOrdinal < 2^32) (nb : previousNext < 2^32)
    (oi : E values po = (previousOrdinal : F)) (ni : E values pn = (previousNext : F)) :
    d.ordinal = previousOrdinal+1 ∧ d.cursor = previousNext := by
  have all := holds matrix splits r index ph po pn checked values satisfied
  have part := part_holds values splits r index ph po pn all 10 (by decide)
  have notFirst : index ≠ 0 := by omega
  have ordinal := part (gate r.continuing (sub (sub (address splits r).low po) o)) (by simp [memberParts,notFirst])
  have cursor := part (gate r.continuing (sub (cell splits r).high pn)) (by simp [memberParts,notFirst])
  change E values r.continuing*E values (sub (sub (address splits r).low po) o) = E values z at ordinal
  change E values r.continuing*E values (sub (cell splits r).high pn) = E values z at cursor
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [continuing,eval_sub,eval_sub,image.2.1,oi,one,zero] at ordinal
  rw [continuing,eval_sub,image.2.2.1,ni,zero] at cursor
  exact ⟨natural_equal (F := F) d.ordinal (previousOrdinal+1) (by have b := bound.2.1; omega) (by omega) (by simp only [Semiring.natCast_add,Semiring.natCast_one]; grind),
    natural_equal (F := F) d.cursor previousNext (by have b := bound.2.2.1; omega) (by omega) (by grind)⟩

theorem close_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (next : Linear) (closing : CloseRow)
    (checked : MemoryEvidence.checkSpan matrix closing.firstGate closing.lastGate (closeGates splits r next) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (image : Represents values splits r d) (bound : Bounded d)
    (active : E values r.entry.active = 1) (finished : E values next = 0)
    (length : Nat) (lb : length < 2^32) (li : E values r.lengthQuery.value = (length : F)) :
    d.next = 0 ∧ d.ordinal+1 = length := by
  have all := MemoryEvidence.span_sound matrix _ _ _ checked values satisfied
  have finalNext := all (gate (sub r.entry.active next) (node splits r).high) (by simp [closeGates])
  have finalCount := all (gate (sub r.entry.active next) (sub ((address splits r).low++o) r.lengthQuery.value)) (by simp [closeGates])
  change E values (sub r.entry.active next)*E values (node splits r).high = E values z at finalNext
  change E values (sub r.entry.active next)*E values (sub ((address splits r).low++o) r.lengthQuery.value) = E values z at finalCount
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have add : E values ((address splits r).low++o) = E values (address splits r).low+E values o := eval_append values _ _
  rw [eval_sub,active,finished,image.2.2.2.2.1,zero] at finalNext
  rw [eval_sub,active,finished,eval_sub,add,image.2.1,one,li,zero] at finalCount
  exact ⟨natural_equal (F := F) d.next 0 (by have b := bound.2.2.2; omega) (by decide) (by simp only [Semiring.natCast_zero]; grind),
    natural_equal (F := F) (d.ordinal+1) length (by have b := bound.2.1; omega) (by omega) (by simp only [Semiring.natCast_add,Semiring.natCast_one]; grind)⟩

#print axioms continuation
#print axioms start_step
#print axioms continue_step
#print axioms close_step
end ZkBuild.IndexedStep
