import InstructionSpans
set_option autoImplicit false
namespace ZkBuild.InstructionPartition
open Lean.Grind OperandEvents InstructionSpans

/-- Every open state has an actual earlier instruction start, with no intervening boundary. -/
theorem preceding {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (bound : i ≤ rows.length) (opened : (InstructionTraceSound.state rows ops i).opened = true) :
    ∃ first, first < i ∧ (rows.getD first default).kind = .instructionBegin ∧
      ∀ j, first < j → j < i → Middle (rows.getD j default).kind := by
  induction i with
  | zero => simp [InstructionTraceSound.state] at opened
  | succ i ih =>
    by_cases beginKind : (rows.getD i default).kind = .instructionBegin
    · exact ⟨i,by omega,beginKind,by intro j lo hi; omega⟩
    · have previous : (InstructionTraceSound.state rows ops i).opened = true := by
        change InstructionSchedule.afterOpen _ _ = true at opened
        cases kind : (rows.getD i default).kind <;> simp_all [InstructionSchedule.afterOpen]
      have ending : (rows.getD i default).kind ≠ .instructionEnd := by
        intro kind
        change InstructionSchedule.afterOpen _ _ = true at opened
        simp only [kind,InstructionSchedule.afterOpen,Bool.false_eq_true] at opened
      have middle : Middle (rows.getD i default).kind :=
        (open_kind _ _ _ previous (schedule.modes i (by omega))).resolve_left ending
      obtain ⟨first,lo,start,inside⟩ := ih (by omega) previous
      refine ⟨first,by omega,start,?_⟩
      intro j lower upper
      by_cases last : j = i
      · simpa only [last] using middle
      · exact inside j lower (by omega)

theorem covered {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (bound : i < rows.length) (opened : (InstructionTraceSound.state rows ops i).opened = true) :
    ∃ first last, Span rows first last ∧ first < i ∧ i ≤ last := by
  obtain ⟨first,lo,start,inside⟩ := preceding values events rows ops schedule i (by omega) opened
  obtain ⟨last,span⟩ := exists_span values events rows ops schedule first (by omega) start
  have upper : i ≤ last := by
    by_cases bad : last < i
    · exact False.elim ((inside last span.ordered bad).2.2.1 span.endKind)
    · omega
  exact ⟨first,last,span,lo,upper⟩

theorem membership_unique (rows : List Row) (a b c d i : Nat) (left : Span rows a b)
    (right : Span rows c d) (al : a ≤ i) (ar : i ≤ b) (cl : c ≤ i) (cr : i ≤ d) : a = c ∧ b = d := by
  have equal : a = c := by
    by_cases ac : a < c
    · have := disjoint rows a b c d left right ac; omega
    by_cases ca : c < a
    · have := disjoint rows c d a b right left ca; omega
    omega
  subst c
  exact ⟨rfl,unique rows a b d left right⟩

theorem ending {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (bound : i < rows.length) (endKind : (rows.getD i default).kind = .instructionEnd) :
    ∃ first, Span rows first i := by
  have allowed := schedule.modes i bound
  have opened : (InstructionTraceSound.state rows ops i).opened = true := by
    rw [endKind] at allowed
    cases pending : InstructionTraceSound.pending rows i <;>
      simpa [InstructionSchedule.allowed,pending] using allowed
  obtain ⟨first,last,span,lo,hi⟩ := covered values events rows ops schedule i bound opened
  have same : i = last := by
    by_cases same : i = last
    · exact same
    · exact False.elim ((span.middle i lo (by omega)).2.2.1 endKind)
  simpa only [same] using Exists.intro first span

/-- Outside instruction bodies only boundaries, padding, or the pending function root are permitted. -/
theorem outside {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (bound : i < rows.length) (closed : (InstructionTraceSound.state rows ops i).opened = false) :
    (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .instructionBegin ∨
    (rows.getD i default).kind = .functionEnd ∨ (rows.getD i default).kind = .padding ∨
    ((rows.getD i default).kind = .controlPush ∧ InstructionTraceSound.pending rows i = true) := by
  have allowed := schedule.modes i bound
  cases pending : InstructionTraceSound.pending rows i <;> cases kind : (rows.getD i default).kind <;>
    simp only [InstructionSchedule.allowed,closed,pending,kind] at allowed <;> simp_all

structure Partition (rows : List Row) (ops : List Nat) : Prop where
  coverage : ∀ i, i < rows.length → (InstructionTraceSound.state rows ops i).opened = true →
    ∃ first last, Span rows first last ∧ first < i ∧ i ≤ last
  endings : ∀ i, i < rows.length → (rows.getD i default).kind = .instructionEnd → ∃ first, Span rows first i
  uniqueness : ∀ a b c d i, Span rows a b → Span rows c d → a ≤ i → i ≤ b → c ≤ i → i ≤ d → a = c ∧ b = d
  external : ∀ i, i < rows.length → (InstructionTraceSound.state rows ops i).opened = false →
    (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .instructionBegin ∨
    (rows.getD i default).kind = .functionEnd ∨ (rows.getD i default).kind = .padding ∨
    ((rows.getD i default).kind = .controlPush ∧ InstructionTraceSound.pending rows i = true)

theorem partition {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Partition rows ops :=
  ⟨covered values events rows ops schedule,ending values events rows ops schedule,membership_unique rows,
    outside values events rows ops schedule⟩

#print axioms preceding
#print axioms covered
#print axioms membership_unique
#print axioms ending
#print axioms outside
#print axioms partition
end ZkBuild.InstructionPartition
