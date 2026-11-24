import InstructionSemanticSound
set_option autoImplicit false
namespace ZkBuild.InstructionSpans
open Lean.Grind OperandEvents

def Middle (kind : Kind) : Prop :=
  kind ≠ .functionBegin ∧ kind ≠ .instructionBegin ∧ kind ≠ .instructionEnd ∧
  kind ≠ .functionEnd ∧ kind ≠ .padding

structure Span (rows : List Row) (first last : Nat) : Prop where
  ordered : first < last
  bounded : last < rows.length
  beginKind : (rows.getD first default).kind = .instructionBegin
  endKind : (rows.getD last default).kind = .instructionEnd
  middle : ∀ i, first < i → i < last → Middle (rows.getD i default).kind

theorem open_kind (opened pending : Bool) (kind : Kind)
    (isOpen : opened = true) (allowed : InstructionSchedule.allowed opened pending kind = true) :
    kind = .instructionEnd ∨ Middle kind := by
  subst opened
  cases pending <;> cases kind <;> simp [InstructionSchedule.allowed,Middle] at allowed ⊢

theorem seek {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (remaining : Nat) : ∀ i, i+remaining = rows.length → (InstructionTraceSound.state rows ops i).opened = true →
    ∃ last, i ≤ last ∧ last < rows.length ∧ (rows.getD last default).kind = .instructionEnd ∧
      ∀ j, i ≤ j → j < last → Middle (rows.getD j default).kind := by
  induction remaining with
  | zero =>
    intro i size opened
    have eq : i = rows.length := by omega
    rw [eq,schedule.closed] at opened
    contradiction
  | succ remaining ih =>
    intro i size opened
    have ib : i < rows.length := by omega
    have allowed := open_kind _ _ _ opened (schedule.modes i ib)
    rcases allowed with ending | middle
    · exact ⟨i,by omega,ib,ending,by intro j lo hi; omega⟩
    · have nextOpen : (InstructionTraceSound.state rows ops (i+1)).opened = true := by
        change InstructionSchedule.afterOpen (InstructionTraceSound.state rows ops i).opened (rows.getD i default).kind = true
        rw [opened]
        cases k : (rows.getD i default).kind <;> simp [InstructionSchedule.afterOpen]
        exact False.elim (middle.2.2.1 k)
      obtain ⟨last,lo,hi,ending,body⟩ := ih (i+1) (by omega) nextOpen
      refine ⟨last,by omega,hi,ending,?_⟩
      intro j jb je
      by_cases same : j = i
      · simpa only [same] using middle
      · exact body j (by omega) je

theorem exists_span {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first : Nat) (fb : first < rows.length) (beginKind : (rows.getD first default).kind = .instructionBegin) :
    ∃ last, Span rows first last := by
  have opened : (InstructionTraceSound.state rows ops (first+1)).opened = true := by
    change InstructionSchedule.afterOpen _ _ = true
    simp only [beginKind,InstructionSchedule.afterOpen]
  obtain ⟨last,lo,hi,ending,middle⟩ := seek values events rows ops schedule (rows.length-(first+1)) (first+1) (by omega) opened
  exact ⟨last,by constructor; omega; exact hi; exact beginKind; exact ending; intro i ib ie; exact middle i (by omega) ie⟩

theorem unique (rows : List Row) (first a b : Nat) (left : Span rows first a) (right : Span rows first b) : a = b := by
  by_cases ab : a < b
  · have bad := (right.middle a left.ordered ab).2.2.1 left.endKind
    exact False.elim bad
  by_cases ba : b < a
  · have bad := (left.middle b right.ordered ba).2.2.1 right.endKind
    exact False.elim bad
  omega

theorem disjoint (rows : List Row) (a b c d : Nat) (left : Span rows a b) (right : Span rows c d)
    (ordered : a < c) : b < c := by
  by_cases cb : c < b
  · exact False.elim ((left.middle c ordered cb).2.1 right.beginKind)
  by_cases same : c = b
  · have impossible := right.beginKind
    rw [same,left.endKind] at impossible
    contradiction
  omega

#print axioms seek
#print axioms exists_span
#print axioms unique
#print axioms disjoint
end ZkBuild.InstructionSpans
