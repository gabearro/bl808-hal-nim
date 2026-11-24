import EnvelopeDirectory

namespace ZkBuild.EnvelopePayload
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix EnvelopeRanges
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem standard_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Row) (d : Decoded) (bounded : Bounded d)
    (represented : EnvelopeRanges.Represents values r d) (source cursor rank previous : Linear) (totals : Totals)
    (holds : AllHold values (rowGates source tokens r cursor rank previous totals)) :
    E values r.standard = if d.active && d.id != 0 then 1 else 0 := by
  have zeroCore := part_holds values source tokens r cursor rank previous totals holds 11 (by decide)
  change AllHold values (zeroGates r.entry.id (wire r.standardStart) (wire (r.standardStart+1))) at zeroCore
  have zero := zero_sound values oneValue _ _ _ zeroCore
  have idZero : E values r.entry.id = 0 ↔ d.id = 0 := by
    rw [represented.2.1]
    exact IsCharP.natCast_eq_zero_iff_of_lt scalarModulus (Nat.lt_trans bounded.1 (by decide))
  have core := part_holds values source tokens r cursor rank previous totals holds 12 (by decide)
  change AllHold values [mulGate r.entry.active (sub BinaryTokenMatrix.one (wire r.standardStart)) r.standard,
    mulGate r.standard (sub (sub (r.lookup.outputs.getD 1 []) rank) (BinaryTokenMatrix.nat 1)) r.rankGap] at core
  have standard := multiply_sound values r.entry.active (sub BinaryTokenMatrix.one (wire r.standardStart)) r.standard (core _ (by simp))
  rw [standard,represented.1,eval_sub,zero]
  simp only [idZero]
  have one : E values BinaryTokenMatrix.one = 1 := by simp [BinaryTokenMatrix.one,eval_constant values oneValue]
  rw [one]
  cases active : d.active <;> by_cases zero : d.id = 0 <;> simp [active,zero] <;> grind

/-- The leading payload integer stays inside its own section, rather than
    borrowing bytes from the following section. Custom sections read no word. -/
theorem word_span {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (r : Row) (accepted : checkRow matrix tokens r = true) (d : Decoded) (bounded : Bounded d)
    (represented : EnvelopeRanges.Represents values r d) (source cursor rank previous : Linear) (totals : Totals)
    (holds : AllHold values (rowGates source tokens r cursor rank previous totals)) :
    ∃ length : Nat, E values (token tokens r.wordToken).length = (length : F) ∧ length ≤ 5 ∧
      (d.active = true → d.id = 0 → length = 0) ∧
      (d.active = true → d.id ≠ 0 → 0 < length ∧ d.body+length ≤ d.finish) := by
  have shape := EnvelopeChain.row_metadata matrix tokens r accepted
  have tokenCheck := EnvelopeChain.token_checked matrix tokens checks r.wordToken shape.2.2.2.1
  obtain ⟨length,bound,lengthImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix (token tokens r.wordToken) tokenCheck values oneValue satisfied
  have kind := shape.2.2.2.2.2.2.1.1
  have active := shape.2.2.2.2.2.2.1.2.1
  have standard := standard_image values oneValue r d bounded represented source cursor rank previous totals holds
  have image : E values (BinaryTokenMatrix.active (token tokens r.wordToken)) = E values r.standard := by
    simp [BinaryTokenMatrix.active,kind,active]
  have short : length ≤ 5 := by simpa [kind,BinaryTokenMatrix.capacity] using bound
  refine ⟨length,lengthImage,short,?_,?_⟩
  · intro enabled custom
    have zero : E values r.standard = 0 := by simp [enabled,custom] at standard; exact standard
    by_cases absent : length = 0
    · exact absent
    · have impossible : (0 : F) = 1 := by simpa [image,zero,absent] using activity
      exact False.elim (Field.zero_ne_one impossible)
  · intro enabled noncustom
    have one : E values r.standard = 1 := by simpa [enabled,noncustom] using standard
    have positive : 0 < length := by
      by_cases absent : length = 0
      · have impossible : (1 : F) = 0 := by simpa [image,one,absent] using activity
        exact False.elim (Field.zero_ne_one impossible.symm)
      · omega
    have outer := Bool.and_eq_true_iff.mp accepted
    have gapCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).2
    obtain ⟨gap,gapBound,gapImage⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.wordGapRange r.wordGap 32 gapCheck values oneValue satisfied)
    have core := part_holds values source tokens r cursor rank previous totals holds 16 (by decide)
    change AllHold values [mulGate r.standard (sub (sub r.entry.finish r.entry.body) (token tokens r.wordToken).length) r.wordGap] at core
    have equation := multiply_sound values r.standard (sub (sub r.entry.finish r.entry.body) (token tokens r.wordToken).length) r.wordGap (core _ (by simp))
    rw [gapImage,one,eval_sub,eval_sub,represented.2.2.2.2.2.1,represented.2.2.2.1,lengthImage] at equation
    have cast : (d.finish : F) = ((d.body+length+gap : Nat) : F) := by
      simp only [Semiring.natCast_add]; grind
    have limit : d.body+length+gap < scalarModulus := by
      have big : 2^34 < scalarModulus := by decide
      have bodyBound := bounded.2.2.1
      omega
    have same : d.finish = d.body+length+gap := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans bounded.2.2.2.2.1 (by decide)) limit).mp cast
    exact ⟨positive,by omega⟩

def Fits (c : EnvelopeDirectory.Contribution) : Prop :=
  (c.entry.active = true → c.entry.id = 0 → c.wordLength = 0) ∧
  (c.entry.active = true → c.entry.id ≠ 0 → 0 < c.wordLength ∧ c.entry.body+c.wordLength ≤ c.entry.finish)

theorem payloads_fit {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (rowChecks : rows.all (checkRow matrix tokens) = true)
    (cs : List EnvelopeDirectory.Contribution)
    (represented : ShaProgram.Related (EnvelopeDirectory.Represents values tokens) rows cs)
    (lengths : ∀ c ∈ cs, c.wordLength ≤ 5) (source cursor rank previous : Linear) (totals : Totals)
    (holds : AllHold values (walk source tokens rows cursor rank previous totals)) : ∀ c ∈ cs, Fits c := by
  induction represented generalizing cursor rank previous totals with
  | nil => simp
  | @cons row c rows cs image images ih =>
    have checked : checkRow matrix tokens row = true := List.all_eq_true.mp rowChecks row (by simp)
    have tailChecks : rows.all (checkRow matrix tokens) = true := by
      apply List.all_eq_true.mpr
      intro r member; exact List.all_eq_true.mp rowChecks r (by simp [member])
    have tailLengths : ∀ a ∈ cs, a.wordLength ≤ 5 := by intro a member; exact lengths a (by simp [member])
    have head : AllHold values (rowGates source tokens row cursor rank previous totals) := by
      intro g gm; exact holds g (List.mem_append_left _ gm)
    have after : AllHold values (walk source tokens rows row.cursor row.nextRank row.entry.active (nextTotals row)) := by
      intro g gm; exact holds g (List.mem_append_right _ gm)
    obtain ⟨length,lengthImage,short,custom,standard⟩ := word_span matrix tokens checks values oneValue satisfied row checked c.entry image.2.1 image.1 source cursor rank previous totals head
    have ownBound := lengths c (by simp)
    have same : c.wordLength = length := BinaryTokenDecoded.small_nat_unique c.wordLength length (by omega) (by omega) (image.2.2.symm.trans lengthImage)
    have fits : Fits c := by
      unfold Fits
      rw [same]
      exact ⟨custom,standard⟩
    have rest := ih tailChecks tailLengths row.cursor row.nextRank row.entry.active (nextTotals row) after
    intro a member
    rcases List.mem_cons.mp member with rfl | later
    · exact fits
    · exact rest a later

#print axioms standard_image
#print axioms word_span
#print axioms payloads_fit
end ZkBuild.EnvelopePayload
