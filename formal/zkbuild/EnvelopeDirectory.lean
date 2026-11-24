import EnvelopeOrder

namespace ZkBuild.EnvelopeDirectory
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix EnvelopeRanges
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- One section contributes to exactly the directory entry matching its ID. -/
theorem row_directory {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Row) (d : Decoded) (bounded : Bounded d)
    (represented : EnvelopeRanges.Represents values r d) (previous : Totals) (length : Linear)
    (wordLength : Nat) (lengthImage : E values length = (wordLength : F))
    (holds : AllHold values (aggregateGates r previous length)) (id : Nat) (inside : id < 14) :
    let selected := d.active && d.id == id
    E values ((nextTotals r).present id) = E values (previous.present id)+(if selected then 1 else 0) ∧
    E values ((nextTotals r).firstWords id) = E values (previous.firstWords id)+(if selected then (d.firstWord : F) else 0) ∧
    E values ((nextTotals r).payloads id) = E values (previous.payloads id)+(if selected then ((d.body+wordLength : Nat) : F) else 0) ∧
    E values ((nextTotals r).ends id) = E values (previous.ends id)+(if selected then (d.finish : F) else 0) := by
  let start := r.aggregateStart+10*id
  have localHolds : AllHold values (zeroGates (sub r.entry.id (BinaryTokenMatrix.nat id)) (wire start) (wire (start+1)) ++
      [mulGate r.entry.active (wire start) (wire (start+2)),
       eqGate (wire (start+3)) (previous.present id ++ wire (start+2)),
       mulGate (wire (start+2)) r.entry.firstWord (wire (start+4)),
       eqGate (wire (start+5)) (previous.firstWords id ++ wire (start+4)),
       mulGate (wire (start+2)) (r.entry.body ++ length) (wire (start+6)),
       eqGate (wire (start+7)) (previous.payloads id ++ wire (start+6)),
       mulGate (wire (start+2)) r.entry.finish (wire (start+8)),
       eqGate (wire (start+9)) (previous.ends id ++ wire (start+8))]) := by
    intro g gm
    apply holds g
    exact List.mem_flatMap.mpr ⟨id,List.mem_range.mpr inside,gm⟩
  have zeroHolds : AllHold values (zeroGates (sub r.entry.id (BinaryTokenMatrix.nat id)) (wire start) (wire (start+1))) := by
    intro g gm; exact localHolds g (List.mem_append_left _ gm)
  have bodyHolds : AllHold values
      [mulGate r.entry.active (wire start) (wire (start+2)),
       eqGate (wire (start+3)) (previous.present id ++ wire (start+2)),
       mulGate (wire (start+2)) r.entry.firstWord (wire (start+4)),
       eqGate (wire (start+5)) (previous.firstWords id ++ wire (start+4)),
       mulGate (wire (start+2)) (r.entry.body ++ length) (wire (start+6)),
       eqGate (wire (start+7)) (previous.payloads id ++ wire (start+6)),
       mulGate (wire (start+2)) r.entry.finish (wire (start+8)),
       eqGate (wire (start+9)) (previous.ends id ++ wire (start+8))] := by
    intro g gm; exact localHolds g (List.mem_append_right _ gm)
  have zero := zero_sound values oneValue _ _ _ zeroHolds
  have idImage : E values (BinaryTokenMatrix.nat id) = (id : F) := by
    exact (eval_constant values oneValue (Int.ofNat id)).trans (Ring.intCast_natCast id)
  have equal : E values (sub r.entry.id (BinaryTokenMatrix.nat id)) = 0 ↔ d.id = id := by
    rw [eval_sub,represented.2.1,idImage]
    have natural := IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans bounded.1 (by decide)) (Nat.lt_trans inside (by decide))
    constructor
    · intro h; apply natural.mp; grind
    · intro h; rw [h]; grind
  have selected := multiply_sound values r.entry.active (wire start) (wire (start+2)) (bodyHolds _ (by simp))
  have selectedImage : E values (wire (start+2)) = if d.active && d.id == id then 1 else 0 := by
    rw [selected,represented.1,zero]
    simp only [equal]
    cases active : d.active <;> by_cases same : d.id = id <;> simp [active,same] <;> grind
  have count := equality_sound values oneValue (wire (start+3)) (previous.present id ++ wire (start+2)) (bodyHolds _ (by simp))
  have word := multiply_sound values (wire (start+2)) r.entry.firstWord (wire (start+4)) (bodyHolds _ (by simp))
  have words := equality_sound values oneValue (wire (start+5)) (previous.firstWords id ++ wire (start+4)) (bodyHolds _ (by simp))
  have payload := multiply_sound values (wire (start+2)) (r.entry.body ++ length) (wire (start+6)) (bodyHolds _ (by simp))
  have payloads := equality_sound values oneValue (wire (start+7)) (previous.payloads id ++ wire (start+6)) (bodyHolds _ (by simp))
  have finish := multiply_sound values (wire (start+2)) r.entry.finish (wire (start+8)) (bodyHolds _ (by simp))
  have ends := equality_sound values oneValue (wire (start+9)) (previous.ends id ++ wire (start+8)) (bodyHolds _ (by simp))
  have cat (a b : Linear) : E values (a++b) = E values a+E values b := FullMatrix.eval_append values a b
  rw [cat,selectedImage] at count
  rw [cat,word,selectedImage,represented.2.2.2.2.2.2] at words
  rw [cat,payload,selectedImage,cat,represented.2.2.2.1,lengthImage] at payloads
  rw [cat,finish,selectedImage,represented.2.2.2.2.2.1] at ends
  change E values (wire (start+3)) = _ ∧ E values (wire (start+5)) = _ ∧ E values (wire (start+7)) = _ ∧ E values (wire (start+9)) = _
  refine ⟨count,?_,?_,?_⟩
  · cases active : (d.active && d.id == id) <;> simp [active] at words ⊢ <;> grind
  · cases active : (d.active && d.id == id) <;> simp [active,Semiring.natCast_add] at payloads ⊢ <;> grind
  · cases active : (d.active && d.id == id) <;> simp [active] at ends ⊢ <;> grind

structure Contribution where
  entry : Decoded
  wordLength : Nat

def contribution (id : Nat) (c : Contribution) : Nat × Nat × Nat × Nat :=
  if c.entry.active && c.entry.id == id then (1,c.entry.firstWord,c.entry.body+c.wordLength,c.entry.finish) else (0,0,0,0)

def sum (id : Nat) : List Contribution → Nat × Nat × Nat × Nat
  | [] => (0,0,0,0)
  | c::rest =>
    let a := contribution id c
    let b := sum id rest
    (a.1+b.1,a.2.1+b.2.1,a.2.2.1+b.2.2.1,a.2.2.2+b.2.2.2)

def Represents {F : Type} [CommRing F] (values : Nat → F) (tokens : List BinaryTokenMatrix.Record) (row : Row) (c : Contribution) : Prop :=
  EnvelopeRanges.Represents values row c.entry ∧ Bounded c.entry ∧
    E values (token tokens row.wordToken).length = (c.wordLength : F)

def Accumulates {F : Type} [CommRing F] (values : Nat → F) (out initial : Totals) (cs : List Contribution) : Prop :=
  ∀ id, id < 14 →
    E values (out.present id) = E values (initial.present id)+((sum id cs).1 : F) ∧
    E values (out.firstWords id) = E values (initial.firstWords id)+((sum id cs).2.1 : F) ∧
    E values (out.payloads id) = E values (initial.payloads id)+((sum id cs).2.2.1 : F) ∧
    E values (out.ends id) = E values (initial.ends id)+((sum id cs).2.2.2 : F)

def endTotals (rows : List Row) (initial : Totals) : Totals :=
  match rows with
  | [] => initial
  | row::rest => endTotals rest (nextTotals row)

theorem walk_directory {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (oneValue : values 0 = 1) (tokens : List BinaryTokenMatrix.Record)
    (rows : List Row) (cs : List Contribution) (represented : ShaProgram.Related (Represents values tokens) rows cs)
    (source cursor rank previous : Linear) (initial : Totals)
    (holds : AllHold values (walk source tokens rows cursor rank previous initial)) :
    Accumulates values (endTotals rows initial) initial cs := by
  induction represented generalizing cursor rank previous initial with
  | nil => intro id inside; simp [Accumulates,endTotals,sum,Semiring.add_zero]
  | @cons row c rows cs image images ih =>
    have first : AllHold values (rowGates source tokens row cursor rank previous initial) := by
      intro g gm; exact holds g (List.mem_append_left _ gm)
    have after : AllHold values (walk source tokens rows row.cursor row.nextRank row.entry.active (nextTotals row)) := by
      intro g gm; exact holds g (List.mem_append_right _ gm)
    have part := part_holds values source tokens row cursor rank previous initial first 18 (by decide)
    change AllHold values (aggregateGates row initial (token tokens row.wordToken).length) at part
    have rest := ih row.cursor row.nextRank row.entry.active (nextTotals row) after
    intro id inside
    obtain ⟨a,b,d,e⟩ := row_directory values oneValue row c.entry image.2.1 image.1 initial _ c.wordLength image.2.2 part id inside
    obtain ⟨aa,bb,dd,ee⟩ := rest id inside
    change E values ((endTotals rows (nextTotals row)).present id) = _ ∧ E values ((endTotals rows (nextTotals row)).firstWords id) = _ ∧
      E values ((endTotals rows (nextTotals row)).payloads id) = _ ∧ E values ((endTotals rows (nextTotals row)).ends id) = _
    rw [a] at aa
    rw [b] at bb
    rw [d] at dd
    rw [e] at ee
    cases active : (c.entry.active && c.entry.id == id) <;>
      simp [sum,contribution,active,Semiring.natCast_add] <;> grind

theorem attach_lengths {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (decoded : List Decoded) (rowChecks : rows.all (checkRow matrix tokens) = true)
    (represented : ShaProgram.Related (EnvelopeRanges.Represents values) rows decoded)
    (bounded : ∀ d ∈ decoded, Bounded d) :
    ∃ cs : List Contribution, cs.map Contribution.entry = decoded ∧
      ShaProgram.Related (Represents values tokens) rows cs ∧ ∀ c ∈ cs, c.wordLength ≤ 5 := by
  induction represented with
  | nil => exact ⟨[],rfl,.nil,by simp⟩
  | @cons row d rows decoded image images ih =>
    have checked : checkRow matrix tokens row = true := List.all_eq_true.mp rowChecks row (by simp)
    have tailChecks : rows.all (checkRow matrix tokens) = true := by
      apply List.all_eq_true.mpr
      intro r member; exact List.all_eq_true.mp rowChecks r (by simp [member])
    have tailBounds : ∀ a ∈ decoded, Bounded a := by intro a member; exact bounded a (by simp [member])
    obtain ⟨cs,entries,represented,lengths⟩ := ih tailChecks tailBounds
    have shape := EnvelopeChain.row_metadata matrix tokens row checked
    have tokenCheck := EnvelopeChain.token_checked matrix tokens checks row.wordToken shape.2.2.2.1
    obtain ⟨length,bound,lengthImage,_,_⟩ := BinaryTokenSchedule.checked_length matrix (token tokens row.wordToken) tokenCheck values oneValue satisfied
    have kind : (token tokens row.wordToken).kind = 1 := shape.2.2.2.2.2.2.1.1
    have short : length ≤ 5 := by simpa [kind,BinaryTokenMatrix.capacity] using bound
    exact ⟨⟨d,length⟩::cs,by simp [entries],.cons ⟨image,bounded d (by simp),lengthImage⟩ represented,
      by intro c member; rcases List.mem_cons.mp member with rfl | later; exact short; exact lengths c later⟩

theorem endTotals_nonempty (head : Row) (rest : List Row) (initial : Totals) :
    endTotals (head::rest) initial = finalTotals (head::rest) := by
  induction rest generalizing head initial with
  | nil => rfl
  | cons row rows ih => exact ih row (nextTotals head)

theorem endTotals_final (rows : List Row) : endTotals rows initialTotals = finalTotals rows := by
  cases rows with
  | nil => rfl
  | cons row rows => exact endTotals_nonempty row rows initialTotals

def outputValues {F : Type} [CommRing F] (cs : List Contribution) : List F :=
  (List.range 14).flatMap fun id => [(sum id cs).1,(sum id cs).2.1,(sum id cs).2.2.1,(sum id cs).2.2.2].map (fun n : Nat => (n : F))

theorem outputs_values {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (rows : List Row) (cs : List Contribution) (accumulated : Accumulates values (finalTotals rows) initialTotals cs) :
    (EnvelopeMatrix.outputs rows).map (E values) = outputValues cs := by
  simp only [EnvelopeMatrix.outputs,outputValues,List.map_flatMap]
  unfold List.flatMap
  apply congrArg List.flatten
  apply List.map_congr_left
  intro id member
  obtain ⟨a,b,c,d⟩ := accumulated id (List.mem_range.mp member)
  have zero : E values (constant 0) = 0 := by simp [eval_constant values oneValue]
  simp only [initialTotals,zero,AddCommMonoid.zero_add] at a b c d
  simp only [List.map_cons,List.map_nil,a,b,c,d]

#print axioms row_directory
#print axioms walk_directory
#print axioms attach_lengths
#print axioms outputs_values
end ZkBuild.EnvelopeDirectory
