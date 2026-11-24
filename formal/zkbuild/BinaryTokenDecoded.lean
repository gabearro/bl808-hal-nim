import TokenInteger

namespace ZkBuild.BinaryTokenDecoded
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem small_nat_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 16) (bb : b < 16) (equal : (a : F) = (b : F)) : a = b := by
  have large : 16 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp equal

private theorem raw_gate (r : Record) (normal : r.kind ≠ 7) (raw : leb r.kind = false)
    (i : Nat) (present : Linear) (rows : List Row) :
    eqGate r.length (scale r.activeMode (Int.ofNat (capacity r.kind))) ∈ rowsGates r i present rows := by
  induction rows generalizing i present with
  | nil => simp [rowsGates,normal,raw]
  | cons row rest ih => exact List.mem_append_right _ (ih (i+1) row.next)

theorem normal_raw_length {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (normal : r.kind ≠ 7)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (length : Nat) (positive : 0 < length) (bound : length ≤ capacity r.kind) (lenImage : E values r.length = (length : F))
    (raw : leb r.kind = false) : length = capacity r.kind := by
  obtain ⟨other,otherBound,otherImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have same : other = length := small_nat_unique other length (by omega) (by omega) (otherImage.symm.trans lenImage)
  have activeImage : E values r.activeMode = 1 := by
    simpa [active,normal,same,Nat.ne_of_gt positive] using activity
  have all := checked_holds matrix r accepted values satisfied
  have gateHolds := all _ (List.mem_append_right _ (raw_gate r normal raw 0 (active r) r.rows))
  have equal := equality_sound values oneValue _ _ gateHolds
  have scaled : E values (scale r.activeMode (Int.ofNat (capacity r.kind))) = (capacity r.kind : F) := by
    change evalLinear values (scale r.activeMode (Int.ofNat (capacity r.kind))) = _
    rw [FullMatrix.eval_scale]
    have cast : ((Int.ofNat (capacity r.kind) : Int) : F) = (capacity r.kind : F) := Ring.intCast_natCast _
    rw [cast]
    change (capacity r.kind : F)*E values r.activeMode = (capacity r.kind : F)
    rw [activeImage]
    grind
  rw [scaled,lenImage] at equal
  exact small_nat_unique length (capacity r.kind) (by omega) (by omega) equal

/-- A positive fixed-kind reader returns the integer decoded from its source bytes. -/
theorem normal_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (normal : r.kind ≠ 7)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (length : Nat) (positive : 0 < length) (bound : length ≤ capacity r.kind) (lenImage : E values r.length = (length : F))
    (bytes : Nat → Nat)
    (source : ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
      bytes item.1 < 256 ∧ E values item.2.2.value = (bytes item.1 : F)) :
    E values r.value = (TokenInteger.decode r.kind length bytes : F) := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have small : r.kind < 7 := by omega
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have ranges := checked_ranges matrix r accepted values oneValue satisfied
  obtain ⟨other,ob,oi,rules⟩ := BinaryTokenBits.checked_rules matrix r normal accepted values oneValue satisfied
  have same : other = length := small_nat_unique other length (by omega) (by omega) (oi.symm.trans lenImage)
  subst other
  have rawLength := normal_raw_length matrix r accepted normal values oneValue satisfied length positive bound lenImage
  apply TokenInteger.decoded_value values oneValue r r.kind length (width r.kind) small positive bound rawLength
    (by omega) (Nat.le_refl _) bytes ranges.2.1 (by intro row mem; exact (ranges.2.2.2 row mem).1) source
  · intro item mem
    have rule := rules item mem
    by_cases encoded : leb r.kind = true
    · have signSame : sign r = kindSign r r.kind := by simp [sign,kindSign,normal]
      simpa only [BinaryTokenBits.Rules,BinaryVariantBits.Rules,encoded,↓reduceIte,signSame] using rule
    · have raw : leb r.kind = false := by cases h : leb r.kind <;> simp_all
      simp only [BinaryTokenBits.Rules,raw,Bool.false_eq_true,↓reduceIte] at rule
      simp only [BinaryVariantBits.Rules,raw,Bool.false_eq_true,↓reduceIte]
      intro _ j jb
      have found := BinaryTokenBits.row_member values r 0 (active r) r.rows
        (by intro g gm; exact checked_holds matrix r accepted values satisfied g (List.mem_append_right _ gm)) item mem
      have used : item.1 < length := by have size := shape.2.1; have exact := rawLength raw; omega
      simpa only [ite_eq_left used] using (rule j jb).symm
  · intro i inside outside
    omega

/-- A positive dynamic reader returns the same integer as its selected format. -/
theorem variant_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (variant : r.kind = 7)
    (kind : Nat) (small : kind < 7) (values : Nat → F) (oneValue : values 0 = 1)
    (satisfied : Satisfied matrix values) (mode : E values r.activeMode = ((kind+1 : Nat) : F))
    (length : Nat) (bound : length < 16) (lenImage : E values r.length = (length : F)) (bytes : Nat → Nat)
    (source : ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
      bytes item.1 < 256 ∧ E values item.2.2.value = (bytes item.1 : F)) :
    E values r.value = (TokenInteger.decode kind length bytes : F) := by
  obtain ⟨other,positive,lenBound,image,rawLength⟩ := BinaryVariantFormat.checked_length matrix r accepted variant kind small values oneValue satisfied mode
  have cap : capacity kind ≤ 10 := by unfold capacity; grind
  have same : other = length := small_nat_unique other length (by omega) bound (image.symm.trans lenImage)
  subst other
  obtain ⟨decoded,decodeBound,decodeImage,rules⟩ := BinaryVariantBits.checked_rules matrix r accepted variant kind small values oneValue satisfied mode
  have equal : decoded = length := small_nat_unique decoded length (by omega) bound (decodeImage.symm.trans lenImage)
  subst decoded
  have ranges := checked_ranges matrix r accepted values oneValue satisfied
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1).1
  have size : r.rows.length = 10 := by simpa [variant,capacity] using shape.2.1
  exact TokenInteger.decoded_value values oneValue r kind length 64 small positive lenBound rawLength (by omega)
    (by unfold width; grind) bytes (by simpa [variant,width] using ranges.2.1)
    (by intro row mem; exact (ranges.2.2.2 row mem).1) source rules
    (BinaryVariantFormat.upper_bits matrix r accepted variant kind small values oneValue satisfied mode)

#print axioms normal_value
#print axioms variant_value
end ZkBuild.BinaryTokenDecoded

namespace ZkBuild.BinaryTokenDecoded
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem zero_length_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (lengthZero : E values r.length = 0) : E values r.value = 0 := by
  obtain ⟨length,bound,lenImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have length : length = 0 := small_nat_unique length 0 (by omega) (by omega) (by simpa using lenImage.symm.trans lengthZero)
  have activeZero : E values (active r) = 0 := by simpa [length] using activity
  have pro : AllHold values (prologue r) := by
    intro g gm; exact checked_holds matrix r accepted values satisfied g (List.mem_append_left _ gm)
  by_cases variant : r.kind = 7
  · obtain ⟨mode,bound,modeImage,absentImage,selectors⟩ := BinaryTokenSchedule.checked_variant_mode matrix r accepted variant values oneValue satisfied
    have mem : eqGate (absent r ++ active r) one ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons]; grind
    have total := equality_sound values oneValue _ _ (pro _ mem)
    have addition : E values (absent r ++ active r) = E values (absent r)+E values (active r) := eval_cat values _ _
    have oneImage : E values one = 1 := by simp [one,eval_constant values oneValue]
    rw [addition,activeZero,oneImage,absentImage] at total
    have modeZero : mode = 0 := by
      by_cases z : mode = 0
      · exact z
      · simp only [ite_eq_right z] at total
        have impossible : (0 : F) = 1 := by grind
        exact False.elim (Field.zero_ne_one impossible)
    have selZero (i : Nat) (ib : i < 7) : E values (selector r i) = 0 := by
      have ne : ¬0 = i+1 := by omega
      simpa only [modeZero,ite_eq_right ne] using selectors i ib
    have unavailable (i : Nat) : E values (outputAvailable r i) = 0 := by
      have s0 := selZero 0 (by decide)
      have s3 := selZero 3 (by decide)
      have s4 := selZero 4 (by decide)
      have s6 := selZero 6 (by decide)
      by_cases byte : i < 8
      · simpa [outputAvailable,byte] using activeZero
      · by_cases word : i < 32
        · simp only [outputAvailable,ite_eq_right byte,ite_eq_left word,eval_sub,activeZero,s0]; grind
        · by_cases extra : i = 32
          · rw [outputAvailable,ite_eq_right byte,ite_eq_right word,ite_eq_left extra]
            rw [eval_cat,eval_cat,s3,s4,s6]
            grind
          · rw [outputAvailable,ite_eq_right byte,ite_eq_right word,ite_eq_right extra]
            rw [eval_cat,s4,s6]
            grind
    have ranges := checked_ranges matrix r accepted values oneValue satisfied
    apply TokenInteger.zero_from_bits values oneValue r.value (RangeUse.bits r.valueRange) 64
      (by simpa [variant,width] using ranges.2.1)
    intro i ib
    have gm : gate (sub one (outputAvailable r i)) (atBit (RangeUse.bits r.valueRange) i) ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append]
      right
      exact List.mem_map.mpr ⟨i,List.mem_range.mpr ib,rfl⟩
    have product := BinaryTokenBits.product_zero values oneValue _ _ (pro _ gm)
    rw [eval_sub,unavailable,oneImage] at product
    grind
  · have gm : gate (sub one r.activeMode) r.value ∈ prologue r := by
      simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons]; grind
    have product := BinaryTokenBits.product_zero values oneValue _ _ (pro _ gm)
    have absent : E values r.activeMode = 0 := by simpa only [active,ite_eq_right variant] using activeZero
    rw [eval_sub,absent] at product
    have oneImage : E values one = 1 := by simp [one,eval_constant values oneValue]
    rw [oneImage] at product
    grind

#print axioms zero_length_value
end ZkBuild.BinaryTokenDecoded
