import BranchActionSequence
set_option autoImplicit false
namespace ZkBuild.BranchConditionTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem point (rows : List Row) (start count i : Nat) (inside : i<count) :
    (BranchActionSequence.kinds rows start count).getD i .padding=(rows.getD (start+i) default).kind := by
  simp [BranchActionSequence.kinds,List.getD,inside]

theorem first (rows : List Row) (first last arity previous : Nat)
    (ordered : first<last)
    (plan : BranchActionSequence.kinds rows (first+1) (last-first-1)=BranchActionLanguage.plan arity previous) :
    first+1<last ∧ (rows.getD (first+1) default).kind=.pop := by
  have length := congrArg List.length plan
  simp only [BranchActionSequence.kinds,List.length_map,List.length_range,BranchActionLanguage.plan,
    List.length_append,List.length_cons,List.length_nil,List.length_replicate] at length
  have inside : 0<last-first-1 := by omega
  have head := congrArg (fun xs : List Kind => xs.getD 0 .padding) plan
  rw [point rows (first+1) (last-first-1) 0 inside] at head
  simpa only [Nat.add_zero,BranchActionLanguage.plan,List.singleton_append,List.cons_append,List.nil_append,List.getD_cons_zero] using And.intro (by omega : first+1<last) head

theorem pending_false (rows : List Row) (ops : List Nat) (start count : Nat)
    (initial : BranchTypePending.state rows ops start=false)
    (noReset : ∀ i, start≤i → i<start+count → BranchTypePending.reset (rows.getD i default).kind=false) :
    BranchTypePending.state rows ops (start+count)=false := by
  induction count with
  | zero => simpa only [Nat.add_zero] using initial
  | succ count ih =>
    have prior := ih (by intro i lo hi; exact noReset i lo (by omega))
    have reset := noReset (start+count) (by omega) (by omega)
    rw [show start+(count+1)=start+count+1 from by omega]
    simp only [BranchTypePending.state,BranchTypePending.prepare,reset,Bool.false_eq_true,ite_false,
      BranchTypePending.advance,prior,Bool.false_and]

def Complete {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    first+1<last ∧ (rows.getD (first+1) default).kind=.pop ∧
      CallEvents.InputOk 0 (rows.getD (first+1) default).valueType.val ∧
      ∀ i, first+1<i → i<last → (rows.getD i default).kind=.pop →
        E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (sequences : BranchActionSequence.Complete rows ops) : Complete values splits r rows ops := by
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  intro start last span active
  obtain ⟨arity,previous,_,plan⟩ := sequences start last span active
  have begin := first rows start last arity previous span.ordered plan
  have code := (InstructionSpanState.opcodes values events rows ops schedule start last span (start+1) (by omega) (by omega)).trans active
  have ready : BranchTypePending.state rows ops (start+1)=true := (BranchActionSequence.initial rows ops (fun _ => default) start span.beginKind active).2
  have after : BranchTypePending.state rows ops (start+2)=false := by
    change BranchTypePending.state rows ops ((start+1)+1)=false
    simp only [BranchTypePending.state,begin.2,code,BranchTypePending.prepare,BranchTypePending.reset,
      BranchTypePending.advance,BranchTypePending.selected,reduceCtorEq,or_self,decide_false,decide_true,
      Bool.false_eq_true,ite_false,ready,and_self,Bool.not_true,Bool.and_false]
  have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule (start+1) (by have := span.bounded; omega)
  obtain ⟨_,_,condition,_⟩ := BranchTypeScalar.type_guards matrix _ rc.1 values one satisfied _ rc.2.2.1
  have conditionActive : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) (start+1)).after 33)=1 := by
    have h := (masks (start+1) (by have := span.bounded; omega)).condition
    simpa only [begin.2,code,BranchTypePending.prepare,BranchTypePending.reset,BranchTypePending.selected,
      reduceCtorEq,or_self,decide_false,decide_true,Bool.false_eq_true,ite_false,ready,and_self,
      Bool.true_and,flag,ite_true] using h
  refine ⟨begin.1,begin.2,condition conditionActive,?_⟩
  intro i lo hi pop
  have currentCode := (InstructionSpanState.opcodes values events rows ops schedule start last span i (by omega) (by omega)).trans active
  have notPending := pending_false rows ops (start+2) (i-(start+2)) after (by
    intro k lower upper
    have interior := InstructionSpanState.interior rows start last span k (by omega) (by omega)
    simp only [BranchTypePending.reset,interior.1,interior.2.1,or_self,decide_false])
  rw [show start+2+(i-(start+2))=i from by omega] at notPending
  have h := (masks i (by have := span.bounded; omega)).argument
  simpa only [pop,currentCode,BranchTypePending.prepare,BranchTypePending.reset,BranchTypePending.selected,
    reduceCtorEq,or_self,decide_false,decide_true,Bool.false_eq_true,ite_false,notPending,and_self,
    Bool.not_false,Bool.true_and,flag,ite_true] using h

#print axioms first
#print axioms pending_false
#print axioms sound
end ZkBuild.BranchConditionTrace
