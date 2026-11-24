import EnvelopeChain

namespace ZkBuild.EnvelopeOrder
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix EnvelopeRanges
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def rank (id : Nat) : Nat :=
  ([0,1,2,3,4,5,7,8,9,10,12,13,11,6] : List Nat).getD id 0

theorem rank_bound (id : Nat) : rank id < 14 := by
  by_cases inside : id < 14
  · have cases : id = 0 ∨ id = 1 ∨ id = 2 ∨ id = 3 ∨ id = 4 ∨ id = 5 ∨ id = 6 ∨
        id = 7 ∨ id = 8 ∨ id = 9 ∨ id = 10 ∨ id = 11 ∨ id = 12 ∨ id = 13 := by omega
    rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  · have missing : ([0,1,2,3,4,5,7,8,9,10,12,13,11,6] : List Nat)[id]? = none := List.getElem?_eq_none (by simp; omega)
    simp [rank,List.getD_eq_getElem?_getD,missing]

theorem order_rank (id : Nat) : SectionPolicy.order id = (rank id : Int) := by
  by_cases inside : id < 14
  · have cases : id = 0 ∨ id = 1 ∨ id = 2 ∨ id = 3 ∨ id = 4 ∨ id = 5 ∨ id = 6 ∨
        id = 7 ∨ id = 8 ∨ id = 9 ∨ id = 10 ∨ id = 11 ∨ id = 12 ∨ id = 13 := by omega
    rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> rfl
  · have a : ([0,1,2,3,4,5,7,8,9,10,12,13,11,6] : List Nat)[id]? = none := List.getElem?_eq_none (by simp; omega)
    have b : ([0,1,2,3,4,5,7,8,9,10,12,13,11,6] : List Int)[id]? = none := List.getElem?_eq_none (by simp; omega)
    simp [SectionPolicy.order,rank,List.getD_eq_getElem?_getD,a,b]

theorem id_bound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : Row) (accepted : checkRow matrix tokens r = true) (d : Decoded) (bounded : Bounded d)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (represented : EnvelopeRanges.Represents values r d) : d.id < 256 := by
  have shape := EnvelopeChain.row_metadata matrix tokens r accepted
  have checked := EnvelopeChain.token_checked matrix tokens checks r.idToken shape.2.1
  have kind := shape.2.2.2.2.1.1
  have value := shape.2.2.2.2.1.2.2.2
  have cert := (BinaryTokenMatrix.checked_ranges matrix (token tokens r.idToken) checked values oneValue satisfied).2.1
  rw [kind] at cert
  obtain ⟨n,small,image⟩ := RangeReuse.certificate_sound _ _ _ cert
  have narrow : n < 256 := by simpa [BinaryTokenMatrix.width] using small
  have prime : 256 < scalarModulus := by decide
  have same : n = d.id := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans narrow prime)
    (Nat.lt_trans bounded.1 (by decide))).mp (image.symm.trans (by rw [value]; exact represented.2.1))
  simpa [same] using narrow

theorem row_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : Row) (accepted : checkRow matrix tokens r = true) (d : Decoded) (bounded : Bounded d)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (represented : EnvelopeRanges.Represents values r d) (source cursor previous rankWire : Linear) (totals : Totals)
    (prior : Nat) (priorBound : prior < 14) (priorImage : E values rankWire = (prior : F))
    (holds : AllHold values (rowGates source tokens r cursor rankWire previous totals)) :
    (d.active = true → d.id < 14) ∧
    (d.active = true → d.id ≠ 0 → prior < rank d.id) ∧
    E values r.nextRank = ((if d.active && d.id != 0 then rank d.id else prior : Nat) : F) := by
  have shape := EnvelopeChain.row_metadata matrix tokens r accepted
  have small := id_bound matrix tokens checks r accepted d bounded values oneValue satisfied represented
  have outer := Bool.and_eq_true_iff.mp accepted
  have lookupCheck := (Bool.and_eq_true_iff.mp outer.1).2
  have gaps := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).1
  have gapCheck := gaps.2
  have table := LookupEmbedded.checked_values matrix r.lookup lookupCheck 8 SectionPolicy.expected outer.2 d.id small values oneValue satisfied
    (by rw [shape.2.2.2.2.2.2.2.1]; exact represented.2.1)
  have output (field : Nat) (inside : field < 2) :
      E values (r.lookup.outputs.getD field []) = (SectionPolicy.expected d.id field : F) := by
    have point := congrArg (fun xs : List F => xs.getD field 0) table
    have empty : E values ([] : Linear) = 0 := by simp [E,evalLinear,interpretLinear,R1CS.eval]
    rw [← empty,TokenInteger.map_getD] at point
    rw [shape.2.2.2.2.2.2.2.2] at point
    simpa [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range inside,empty] using point
  have validCore := part_holds values source tokens r cursor rankWire previous totals holds 10 (by decide)
  change AllHold values [BinaryTokenMatrix.gate r.entry.active (sub (r.lookup.outputs.getD 0 []) BinaryTokenMatrix.one)] at validCore
  have validGate := BinaryTokenBits.product_zero values oneValue r.entry.active (sub (r.lookup.outputs.getD 0 []) BinaryTokenMatrix.one) (validCore _ (by simp))
  have valid : d.active = true → d.id < 14 := by
    intro active
    by_cases outside : d.id < 14
    · exact outside
    apply False.elim
    have a : E values r.entry.active = 1 := by simpa [active] using represented.1
    rw [a,eval_sub,output 0 (by decide)] at validGate
    have p : E values BinaryTokenMatrix.one = 1 := by simp [BinaryTokenMatrix.one,eval_constant values oneValue]
    simp only [SectionPolicy.expected,ite_true,ite_eq_right outside,Ring.intCast_zero,p] at validGate
    have impossible : (0 : F) = 1 := by grind
    exact Field.zero_ne_one impossible
  have zeroCore := part_holds values source tokens r cursor rankWire previous totals holds 11 (by decide)
  change AllHold values (zeroGates r.entry.id (wire r.standardStart) (wire (r.standardStart+1))) at zeroCore
  have zeroImage := zero_sound values oneValue _ _ _ zeroCore
  have idZero : E values r.entry.id = 0 ↔ d.id = 0 := by
    rw [represented.2.1]
    exact IsCharP.natCast_eq_zero_iff_of_lt scalarModulus (Nat.lt_trans bounded.1 (by decide))
  have core := part_holds values source tokens r cursor rankWire previous totals holds 12 (by decide)
  change AllHold values [mulGate r.entry.active (sub BinaryTokenMatrix.one (wire r.standardStart)) r.standard,
    mulGate r.standard (sub (sub (r.lookup.outputs.getD 1 []) rankWire) (BinaryTokenMatrix.nat 1)) r.rankGap] at core
  have standard := multiply_sound values r.entry.active (sub BinaryTokenMatrix.one (wire r.standardStart)) r.standard (core _ (by simp))
  have gap := multiply_sound values r.standard (sub (sub (r.lookup.outputs.getD 1 []) rankWire) (BinaryTokenMatrix.nat 1)) r.rankGap (core _ (by simp))
  have standardImage : E values r.standard = if d.active && d.id != 0 then 1 else 0 := by
    rw [standard,represented.1,eval_sub,zeroImage]
    simp only [idZero]
    have one : E values BinaryTokenMatrix.one = 1 := by simp [BinaryTokenMatrix.one,eval_constant values oneValue]
    rw [one]
    cases active : d.active <;> by_cases zero : d.id = 0 <;> simp [active,zero] <;> grind
  obtain ⟨n,gapBound,gapImage⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.rankGapRange r.rankGap 4 gapCheck values oneValue satisfied)
  have rankImage : E values (r.lookup.outputs.getD 1 []) = (rank d.id : F) := by
    rw [output 1 (by decide)]; simp [SectionPolicy.expected,order_rank,Ring.intCast_natCast]
  have order : d.active = true → d.id ≠ 0 → prior < rank d.id := by
    intro active nonzero
    rw [gapImage,standardImage,eval_sub,eval_sub,rankImage,priorImage] at gap
    have one : E values (BinaryTokenMatrix.nat 1) = 1 := by simp [BinaryTokenMatrix.nat,eval_constant values oneValue]
    have selected : (d.active && d.id != 0) = true := by simp [active,nonzero]
    simp only [selected,ite_true,one] at gap
    have cast : (rank d.id : F) = ((prior+1+n : Nat) : F) := by
      simp only [Semiring.natCast_add,Semiring.natCast_one]; grind
    have limit : prior+1+n < scalarModulus := by
      have big : 64 < scalarModulus := by decide
      omega
    have same : rank d.id = prior+1+n := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans (rank_bound _) (by decide)) limit).mp cast
    omega
  have nextCore := part_holds values source tokens r cursor rankWire previous totals holds 14 (by decide)
  change AllHold values [selectGate r.standard (r.lookup.outputs.getD 1 []) rankWire r.nextRank] at nextCore
  have next := select_sound values r.standard (r.lookup.outputs.getD 1 []) rankWire r.nextRank (nextCore _ (by simp))
  refine ⟨valid,order,?_⟩
  rw [next,standardImage,rankImage,priorImage]
  cases active : (d.active && d.id != 0) <;> simp [active] <;> grind

/-- Active non-custom sections have strictly increasing specification ranks;
    custom and inactive rows do not change the last rank. -/
def OrderedFrom (prior : Nat) : List Decoded → Prop
  | [] => True
  | d::rest => (d.active = true → d.id < 14) ∧
      if d.active && d.id != 0 then prior < rank d.id ∧ OrderedFrom (rank d.id) rest
      else OrderedFrom prior rest

theorem walk_ordered {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (source : Linear) (rows : List Row) (rowChecks : rows.all (checkRow matrix tokens) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (decoded : List Decoded) (represented : ShaProgram.Related (EnvelopeRanges.Represents values) rows decoded)
    (bounded : ∀ d ∈ decoded, Bounded d) (cursor rankWire previous : Linear) (totals : Totals)
    (prior : Nat) (priorBound : prior < 14) (priorImage : E values rankWire = (prior : F))
    (holds : AllHold values (walk source tokens rows cursor rankWire previous totals)) :
    OrderedFrom prior decoded := by
  induction represented generalizing cursor rankWire previous totals prior with
  | nil => trivial
  | @cons row d rest decoded represented tail ih =>
    have checked : checkRow matrix tokens row = true := List.all_eq_true.mp rowChecks row (by simp)
    have restChecks : rest.all (checkRow matrix tokens) = true := by
      apply List.all_eq_true.mpr
      intro r member; exact List.all_eq_true.mp rowChecks r (by simp [member])
    have bound : Bounded d := bounded d (by simp)
    have restBounds : ∀ a ∈ decoded, Bounded a := by
      intro a member; exact bounded a (by simp [member])
    have head : AllHold values (rowGates source tokens row cursor rankWire previous totals) := by
      intro g gm; exact holds g (List.mem_append_left _ gm)
    have after : AllHold values (walk source tokens rest row.cursor row.nextRank row.entry.active (nextTotals row)) := by
      intro g gm; exact holds g (List.mem_append_right _ gm)
    obtain ⟨valid,order,next⟩ := row_order matrix tokens checks row checked d bound values oneValue satisfied represented
      source cursor previous rankWire totals prior priorBound priorImage head
    by_cases selected : (d.active && d.id != 0) = true
    · have active : d.active = true := (Bool.and_eq_true_iff.mp selected).1
      have nonzero : d.id ≠ 0 := by simpa using (Bool.and_eq_true_iff.mp selected).2
      have nextImage : E values row.nextRank = (rank d.id : F) := by simpa [selected] using next
      have ordered := ih restChecks restBounds row.cursor row.nextRank row.entry.active (nextTotals row) (rank d.id) (rank_bound _) nextImage after
      exact ⟨valid,by simpa [OrderedFrom,selected] using And.intro (order active nonzero) ordered⟩
    · have nextImage : E values row.nextRank = (prior : F) := by simpa [selected] using next
      have ordered := ih restChecks restBounds row.cursor row.nextRank row.entry.active (nextTotals row) prior priorBound nextImage after
      exact ⟨valid,by simpa [OrderedFrom,selected] using ordered⟩

def standardRanks (sections : List Decoded) : List Nat :=
  (sections.filter (fun d => d.active && d.id != 0)).map (fun d => rank d.id)

theorem ordered_ranks (prior : Nat) (sections : List Decoded) (ordered : OrderedFrom prior sections) :
    (∀ value ∈ standardRanks sections, prior < value) ∧ (standardRanks sections).Pairwise (· < ·) := by
  induction sections generalizing prior with
  | nil => simp [standardRanks]
  | cons d rest ih =>
    by_cases selected : (d.active && d.id != 0) = true
    · have step : prior < rank d.id ∧ OrderedFrom (rank d.id) rest := by simpa [OrderedFrom,selected] using ordered.2
      obtain ⟨lower,pairs⟩ := ih (rank d.id) step.2
      have same : standardRanks (d::rest) = rank d.id :: standardRanks rest := by simp [standardRanks,selected]
      rw [same]
      exact ⟨by intro value member; rcases List.mem_cons.mp member with rfl | later; exact step.1; exact Nat.lt_trans step.1 (lower value later),.cons lower pairs⟩
    · have step : OrderedFrom prior rest := by simpa [OrderedFrom,selected] using ordered.2
      simpa [standardRanks,selected] using ih prior step

#print axioms id_bound
#print axioms row_order
#print axioms walk_ordered
#print axioms ordered_ranks
end ZkBuild.EnvelopeOrder
