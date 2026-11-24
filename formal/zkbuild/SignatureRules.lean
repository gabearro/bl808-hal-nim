import SignatureSound

namespace ZkBuild.SignatureRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix SignatureMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem reference_meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (enabled id : Linear) (r : Reference)
    (holds : AllHold values (referenceGates enabled id r)) (active : E values enabled = 1)
    (n : Nat) (bound : n < 2^32) (image : E values id = (n : F)) :
    E values r.query.active = (if n = 0 then 0 else 1) ∧ E values r.query.address = (n : F) := by
  have indicator := zero_sound values oneValue id (wire r.zeroStart) (wire (r.zeroStart+1))
    (by intro g gm; exact holds g (List.mem_append_left _ gm))
  have same : E values id = 0 ↔ n = 0 := by
    rw [image]
    constructor
    · intro z
      exact DeclarationLocations.natural_equal (F := F) n 0 (by omega) (by decide) (by simpa only [Semiring.natCast_zero] using z)
    · intro z; simp [z]
  have indicatorValue : E values (wire r.zeroStart) = if n = 0 then 1 else 0 := by simpa only [same] using indicator
  have activity := multiply_sound values enabled (sub o (wire r.zeroStart)) r.query.active (holds _ (by simp [referenceGates]))
  have key := multiply_sound values r.query.active id r.query.address (holds _ (by simp [referenceGates,queryGate]))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [active,eval_sub,one,indicatorValue] at activity
  have activityValue : E values r.query.active = if n = 0 then 0 else 1 := by
    by_cases z : n = 0 <;> simp only [z,↓reduceIte] at activity ⊢ <;> grind
  refine ⟨activityValue,?_⟩
  rw [key,activityValue,image]
  by_cases z : n = 0 <;> simp [z] <;> grind

theorem metadata_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MetadataRow) (checked : SignatureMatrix.checkMetadata matrix splits r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (metadataGates splits r) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem metadata_part {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : MetadataRow)
    (holds : AllHold values (metadataGates splits r)) (i : Nat) (bound : i < 7) :
    AllHold values ((metadataParts splits r).getD i []) := by
  have b : i < (metadataParts splits r).length := by simpa [metadataParts] using bound
  have m : (metadataParts splits r).getD i [] ∈ metadataParts splits r := by rw [← List.getElem_eq_getD []]; exact List.getElem_mem b
  intro g gm; exact holds g (List.mem_flatten.mpr ⟨_,m,gm⟩)

theorem address_bits {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : MetadataRow) (splits : Splits) (checked : SignatureMatrix.checkMetadata matrix splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < 2^33 ∧ E values r.entry.address = (n : F) ∧
      E values (SignatureMatrix.parity r) = if n.testBit 0 then 1 else 0 := by
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).2
  obtain ⟨n,bound,image,bits⟩ := TokenInteger.certificate_nat values oneValue r.entry.address (RangeUse.bits r.addressRange) 33
    (RangeUse.checked_certificate matrix r.addressRange r.entry.address 33 rangeCheck values oneValue satisfied)
  exact ⟨n,bound,image,bits 0⟩

/-- An active even-key function entry selects an odd-key type entry using
    its constrained U32 type-index column and preserves both list heads. -/
theorem function_origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : MetadataRow) (splits : Splits) (checked : SignatureMatrix.checkMetadata matrix splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functionIndex : Nat) (fb : functionIndex < 2^32) (active : E values r.entry.active = 1)
    (address : E values r.entry.address = ((2*functionIndex : Nat) : F)) :
    ∃ typeIndex : Nat, typeIndex < 2^32 ∧ E values r.typeIndex = (typeIndex : F) ∧
      E values r.origin.active = 1 ∧ E values r.origin.address = ((2*typeIndex+1 : Nat) : F) ∧ E values r.origin.value = E values r.entry.value := by
  have all := metadata_holds matrix splits r checked values satisfied
  obtain ⟨n,nb,ni,bit⟩ := address_bits matrix r splits checked values oneValue satisfied
  have same := DeclarationLocations.natural_equal (F := F) n (2*functionIndex) (by omega) (by omega) (ni.symm.trans address)
  have parityZero : E values (SignatureMatrix.parity r) = 0 := by simpa [same,Nat.testBit_zero,Nat.mul_mod] using bit
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  obtain ⟨tid,tb,ti⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.typeIndexRange r.typeIndex 32 rangeCheck values oneValue satisfied)
  have selector := metadata_part values splits r all 4 (by decide)
  have select := multiply_sound values r.entry.active (sub o (SignatureMatrix.parity r)) r.functionEntry (selector _ (by simp [metadataParts]))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have enabled : E values r.functionEntry = 1 := by rw [select,active,eval_sub,one,parityZero]; grind
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1
  have body := metadata_part values splits r all 6 (by decide)
  have key := multiply_sound values r.functionEntry (scale r.typeIndex 2++o) r.origin.address (body _ (by simp [metadataParts,queryGate]))
  have value := multiply_sound values r.functionEntry r.entry.value r.origin.value (body _ (by simp [metadataParts]))
  have add : E values (scale r.typeIndex 2++o) = E values (scale r.typeIndex 2)+E values o := eval_append values _ _
  have scaled := eval_scale values r.typeIndex 2
  change E values (scale r.typeIndex 2) = ((2 : Int) : F)*E values r.typeIndex at scaled
  have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
  refine ⟨tid,tb,ti,?_,?_,?_⟩
  · rw [shape.2.2,enabled]
  · rw [key,enabled,Semiring.one_mul,add,scaled,two,ti,one,Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_one]
  · simpa only [enabled,Semiring.one_mul] using value

#print axioms reference_meaning
#print axioms function_origin
end ZkBuild.SignatureRules
