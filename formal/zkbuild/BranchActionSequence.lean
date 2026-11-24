import BranchActionLanguage
import BranchActionAlphabet
set_option autoImplicit false
namespace ZkBuild.BranchActionSequence
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def kinds (rows : List Row) (start count : Nat) : List Kind :=
  (List.range count).map (fun k => (rows.getD (start+k) default).kind)

theorem snoc (rows : List Row) (start count : Nat) :
    kinds rows start (count+1)=kinds rows start count++[(rows.getD (start+count) default).kind] := by
  simp only [kinds,List.range_succ,List.map_append,List.map_cons,List.map_nil]

theorem initial (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (first : Nat)
    (kind : (rows.getD first default).kind=.instructionBegin) (code : ops.getD first 0=14) :
    BranchTypeTrace.state rows ops data (first+1)={} ∧ BranchTypePending.state rows ops (first+1)=true := by
  simp only [BranchTypeTrace.state,BranchTypePending.state,kind,code]
  simp [BranchTypeState.prepare,BranchTypeState.select,BranchTypeState.advance,BranchTypeState.mark,
    BranchTypePending.prepare,BranchTypePending.advance,BranchTypePending.reset,BranchTypePending.selected]

theorem segment {F : Type} [Field F]
    (values : Nat → F) (events : ValidationEventMatrix.Record) (rows : List Row) (ops : List Nat)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → BranchTypeData.Data) (guards : BranchTypeSemanticSound.Guards rows ops data)
    (alphabet : BranchActionAlphabet.Complete rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ops.getD first 0=14)
    (count : Nat) (bound : first+1+count≤last) :
    BranchActionLanguage.Prefix (BranchTypeTrace.state rows ops data (first+1+count))
      (BranchTypePending.state rows ops (first+1+count)) (kinds rows (first+1) count) := by
  induction count with
  | zero =>
    have start := initial rows ops data first span.beginKind active
    simpa only [Nat.add_zero,kinds,List.range_zero,List.map_nil,start.1,start.2] using BranchActionLanguage.initial
  | succ count ih =>
    have prior := ih (by omega)
    let i := first+1+count
    have inside : i<last := by dsimp [i]; omega
    have lo : first<i := by dsimp [i]; omega
    have ib : i<rows.length := by have := span.bounded; omega
    have code := (InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)).trans active
    have kinds := InstructionSpanState.interior rows first last span i lo (by omega)
    have reset : BranchTypePending.reset (rows.getD i default).kind=false := by
      simp only [BranchTypePending.reset,kinds.1,kinds.2.1,or_self,decide_false]
    have g := guards i ib
    simp only [BranchTypeTrace.ready,BranchTypeState.prepare,BranchTypePending.prepare,reset,
      Bool.false_eq_true,ite_false,code,BranchTypeTrace.chosen,BranchTypeTrace.state,BranchTypePending.state] at g
    have step := BranchActionLanguage.step (BranchTypeTrace.state rows ops data i) (BranchTypePending.state rows ops i)
      _ _ i (data i) (alphabet first last span active i lo inside) prior g
    rw [snoc]
    have sum : first+1+(count+1)=i+1 := by dsimp [i]; omega
    rw [sum]
    simpa only [BranchTypeTrace.state,BranchTypePending.state,BranchTypeState.prepare,BranchTypePending.prepare,
      reset,Bool.false_eq_true,ite_false,code,i] using step

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∃ arity previous, arity<2^32 ∧ kinds rows (first+1) (last-first-1)=BranchActionLanguage.plan arity previous

theorem for_span {F : Type} [Field F]
    (values : Nat → F) (events : ValidationEventMatrix.Record) (rows : List Row) (ops : List Nat)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → BranchTypeData.Data) (guards : BranchTypeSemanticSound.Guards rows ops data)
    (alphabet : BranchActionAlphabet.Complete rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ops.getD first 0=14) :
    ∃ previous, kinds rows (first+1) (last-first-1)=
      BranchActionLanguage.plan (BranchTypeTrace.state rows ops data last).arity previous := by
  have offset : first+1+(last-first-1)=last := by have := span.ordered; omega
  have prior := segment values events rows ops schedule data guards alphabet first last span active (last-first-1) (by omega)
  rw [offset] at prior
  have code := (InstructionSpanState.opcodes values events rows ops schedule first last span last (by have := span.ordered; omega) (by omega)).trans active
  have g := guards last span.bounded
  simp only [BranchTypeTrace.ready,BranchTypeState.prepare,BranchTypePending.prepare,span.endKind,
    BranchTypePending.reset,reduceCtorEq,or_self,decide_false,Bool.false_eq_true,ite_false,
    code,BranchTypeTrace.chosen,BranchTypeTrace.state,BranchTypePending.state] at g
  obtain ⟨previous,plan⟩ := BranchActionLanguage.finish _ _ _ last (data last) prior g
  exact ⟨previous,plan⟩

theorem complete {F : Type} [Field F]
    (values : Nat → F) (events : ValidationEventMatrix.Record) (rows : List Row) (ops : List Nat)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → BranchTypeData.Data) (guards : BranchTypeSemanticSound.Guards rows ops data)
    (alphabet : BranchActionAlphabet.Complete rows ops) : Complete rows ops := by
  intro first last span active
  obtain ⟨previous,plan⟩ := for_span values events rows ops schedule data guards alphabet first last span active
  exact ⟨(BranchTypeTrace.state rows ops data last).arity,previous,(BranchTypeTrace.bounds rows ops data last).2.1,plan⟩

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete rows ops := by
  obtain ⟨data,_,guards⟩ := BranchTypeSemanticSound.sound matrix splits tables indexed statics events r checked lookupChecked
    values one satisfied rows ops images schedule
  exact complete values events rows ops schedule data guards
    (BranchActionAlphabet.sound matrix events r frames values one satisfied rows ops images schedule)

#print axioms initial
#print axioms segment
#print axioms for_span
#print axioms complete
#print axioms sound
end ZkBuild.BranchActionSequence
