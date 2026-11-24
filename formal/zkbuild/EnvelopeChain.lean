import EnvelopeRanges
namespace ZkBuild.EnvelopeChain
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix EnvelopeRanges
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem row_metadata (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (r : Row)
    (accepted : checkRow matrix tokens r = true) :
    r.ranges.length = 6 ∧ r.idToken < tokens.length ∧ r.sizeToken < tokens.length ∧ r.wordToken < tokens.length ∧
    tokenMatches (token tokens r.idToken) 0 r.entry.active r.entry.start r.entry.id ∧
    tokenMatches (token tokens r.sizeToken) 1 r.entry.active r.sizePosition r.entry.size ∧
    tokenMatches (token tokens r.wordToken) 1 r.standard r.entry.body r.entry.firstWord ∧
    r.lookup.input = r.entry.id ∧ r.lookup.columns = 2 := by
  have a := (Bool.and_eq_true_iff.mp accepted).1
  have b := (Bool.and_eq_true_iff.mp a).1
  have c := (Bool.and_eq_true_iff.mp b).1
  have d := (Bool.and_eq_true_iff.mp c).1
  have e := (Bool.and_eq_true_iff.mp d).1
  exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp e).1

theorem token_checked (matrix : Shape) (tokens : List BinaryTokenMatrix.Record)
    (checks : tokens.all (BinaryTokenMatrix.check matrix) = true) (i : Nat) (inside : i < tokens.length) :
    BinaryTokenMatrix.check matrix (token tokens i) = true := by
  have member : token tokens i ∈ tokens := by
    rw [token,← List.getElem_eq_getD default]
    exact List.getElem_mem inside
  exact List.all_eq_true.mp checks _ member

private theorem natural_equal {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 2^34) (bb : b < 2^34) (equal : (a : F) = (b : F)) : a = b := by
  have large : 2^34 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp equal

private theorem cursor_step {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (source : Linear) (tokens : List BinaryTokenMatrix.Record) (r : Row) (cursor rank previous : Linear) (totals : Totals)
    (holds : AllHold values (rowGates source tokens r cursor rank previous totals)) :
    E values r.cursor = E values cursor+E values r.entry.active*(E values r.entry.finish-E values cursor) := by
  have core := part_holds values source tokens r cursor rank previous totals holds 19 (by decide)
  change AllHold values [selectGate r.entry.active r.entry.finish cursor r.cursor] at core
  exact select_sound values _ _ _ _ (core _ (by simp))

theorem active_row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : Row) (accepted : checkRow matrix tokens r = true) (d : Decoded) (bounded : Bounded d)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (represented : EnvelopeRanges.Represents values r d) (enabled : d.active = true)
    (source cursor rank previous : Linear) (totals : Totals) (position : Nat) (positionBound : position < 2^32)
    (cursorImage : E values cursor = (position : F))
    (holds : AllHold values (rowGates source tokens r cursor rank previous totals)) :
    d.start = position ∧ BinaryEnvelope.WellFormed (span d) ∧ E values r.cursor = (d.finish : F) := by
  rcases row_metadata matrix tokens r accepted with ⟨_,_,sizeInside,_,_,sizeMatch,_,_,_⟩
  let sizeToken := token tokens r.sizeToken
  have tokenCheck := token_checked matrix tokens checks r.sizeToken sizeInside
  obtain ⟨length,lengthBound,lengthImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix sizeToken tokenCheck values oneValue satisfied
  have kind : sizeToken.kind = 1 := sizeMatch.1
  have sizeActive : sizeToken.activeMode = r.entry.active := sizeMatch.2.1
  have a : E values r.entry.active = 1 := by simpa [enabled] using represented.1
  have ta : E values (BinaryTokenMatrix.active sizeToken) = 1 := by simp [BinaryTokenMatrix.active,kind,sizeActive,a]
  have positive : 0 < length := by
    by_cases z : length = 0
    · rw [z] at activity
      have impossible : (0 : F) = 1 := by simpa only [ite_true] using activity.symm.trans ta
      exact False.elim (Field.zero_ne_one impossible)
    · omega
  have short : length ≤ 5 := by simpa [kind,BinaryTokenMatrix.capacity] using lengthBound
  have startCore := part_holds values source tokens r cursor rank previous totals holds 2 (by decide)
  change AllHold values [BinaryTokenMatrix.gate r.entry.active (sub r.entry.start cursor)] at startCore
  have bodyCore := part_holds values source tokens r cursor rank previous totals holds 6 (by decide)
  change AllHold values [BinaryTokenMatrix.gate r.entry.active (sub (sub (sub r.entry.body r.entry.start) (BinaryTokenMatrix.nat 1)) sizeToken.length),
    BinaryTokenMatrix.gate r.entry.active (sub (sub r.entry.finish r.entry.body) r.entry.size),
    mulGate r.entry.active (sub source r.entry.finish) r.remaining] at bodyCore
  have startGate := BinaryTokenBits.product_zero values oneValue r.entry.active (sub r.entry.start cursor) (startCore _ (by simp))
  have bodyGate := BinaryTokenBits.product_zero values oneValue r.entry.active (sub (sub (sub r.entry.body r.entry.start) (BinaryTokenMatrix.nat 1)) sizeToken.length) (bodyCore _ (by simp))
  have finishGate := BinaryTokenBits.product_zero values oneValue r.entry.active (sub (sub r.entry.finish r.entry.body) r.entry.size) (bodyCore _ (by simp))
  have startImage := represented.2.2.1
  have bodyImage := represented.2.2.2.1
  have sizeImage := represented.2.2.2.2.1
  have finishImage := represented.2.2.2.2.2.1
  have bounds : d.start < 2^32 ∧ d.body < 2^32 ∧ d.size < 2^32 ∧ d.finish < 2^32 := ⟨bounded.2.1,bounded.2.2.1,bounded.2.2.2.1,bounded.2.2.2.2.1⟩
  rw [a,eval_sub,startImage,cursorImage] at startGate
  have sameStart : d.start = position := natural_equal (F := F) d.start position (by omega) (by omega) (by grind)
  have oneImage : E values (BinaryTokenMatrix.nat 1) = 1 := by simp [BinaryTokenMatrix.nat,eval_constant values oneValue]
  rw [a,eval_sub,eval_sub,eval_sub,bodyImage,startImage,oneImage,lengthImage] at bodyGate
  have sameBody : d.body = d.start+1+length := natural_equal (F := F) d.body (d.start+1+length) (by omega) (by omega) (by
    simp only [Semiring.natCast_add,Semiring.natCast_one]; grind)
  rw [a,eval_sub,eval_sub,finishImage,bodyImage,sizeImage] at finishGate
  have sameFinish : d.finish = d.body+d.size := natural_equal (F := F) d.finish (d.body+d.size) (by omega) (by omega) (by
    simp only [Semiring.natCast_add]; grind)
  have after := cursor_step values oneValue source tokens r cursor rank previous totals holds
  rw [a,finishImage] at after
  refine ⟨sameStart,⟨by simp [BinaryEnvelope.WellFormed,span]; omega,sameFinish⟩,?_⟩
  grind

theorem walk_chain {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (source : Linear) (rows : List Row) (rowChecks : rows.all (checkRow matrix tokens) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (length position : Nat) (lengthBound : length < 2^32) (positionBound : position < 2^32)
    (sourceImage : E values source = (length : F)) (cursor rank previous : Linear) (totals : Totals)
    (cursorImage : E values cursor = (position : F)) (holds : AllHold values (walk source tokens rows cursor rank previous totals)) :
    ∃ decoded : List Decoded, ShaProgram.Related (EnvelopeRanges.Represents values) rows decoded ∧
      (∀ d ∈ decoded, Bounded d) ∧ BinaryEnvelope.Chain position (activeSpans decoded) length := by
  induction rows generalizing position cursor rank previous totals with
  | nil =>
    have gate := holds (eqGate cursor source) (by simp [walk])
    have same := equality_sound values oneValue cursor source gate
    rw [cursorImage,sourceImage] at same
    have equal : position = length := natural_equal (F := F) position length (by omega) (by omega) same
    exact ⟨[],.nil,by simp,by simpa [activeSpans,equal] using BinaryEnvelope.Chain.nil length⟩
  | cons row rest ih =>
    have rc : checkRow matrix tokens row = true := (List.all_eq_true.mp rowChecks row (by simp))
    have restChecks : rest.all (checkRow matrix tokens) = true := by
      apply List.all_eq_true.mpr
      intro r member; exact List.all_eq_true.mp rowChecks r (by simp [member])
    have head : AllHold values (rowGates source tokens row cursor rank previous totals) := by
      intro g gm; exact holds g (List.mem_append_left _ gm)
    have tail : AllHold values (walk source tokens rest row.cursor row.nextRank row.entry.active (nextTotals row)) := by
      intro g gm; exact holds g (List.mem_append_right _ gm)
    have core := part_holds values source tokens row cursor rank previous totals head 0 (by decide)
    change AllHold values [boolGate row.entry.active,BinaryTokenMatrix.gate row.entry.active (sub BinaryTokenMatrix.one previous)] at core
    have boolean : Holds values (boolGate row.entry.active) := core _ (by simp)
    obtain ⟨d,represented,bounded⟩ := EnvelopeRanges.decode matrix tokens row rc values oneValue satisfied boolean
    cases active : d.active with
    | false =>
      have az : E values row.entry.active = 0 := by simpa [active] using represented.1
      have next := cursor_step values oneValue source tokens row cursor rank previous totals head
      have nextImage : E values row.cursor = (position : F) := by rw [az,cursorImage] at next; simpa [Semiring.zero_mul,Semiring.add_zero] using next
      obtain ⟨decoded,rep,bounds,chain⟩ := ih restChecks position positionBound row.cursor row.nextRank row.entry.active (nextTotals row) nextImage tail
      refine ⟨d::decoded,.cons represented rep,?_,?_⟩
      · intro a mem; rcases List.mem_cons.mp mem with rfl | later; exact bounded; exact bounds a later
      · simpa [activeSpans,active] using chain
    | true =>
      obtain ⟨start,formed,nextImage⟩ := active_row matrix tokens tokenChecks row rc d bounded values oneValue satisfied represented active
        source cursor rank previous totals position positionBound cursorImage head
      obtain ⟨decoded,rep,bounds,chain⟩ := ih restChecks d.finish bounded.2.2.2.2.1 row.cursor row.nextRank row.entry.active (nextTotals row) nextImage tail
      refine ⟨d::decoded,.cons represented rep,?_,?_⟩
      · intro a mem; rcases List.mem_cons.mp mem with rfl | later; exact bounded; exact bounds a later
      · have cons := BinaryEnvelope.Chain.cons (by simpa [span] using start) formed chain
        simpa [activeSpans,active] using cons

#print axioms active_row
#print axioms walk_chain
end ZkBuild.EnvelopeChain
