import BranchLastMarker
set_option autoImplicit false
namespace ZkBuild.BranchComplete
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Complete {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (s : DynamicTypingMatrix.Stage) (events : ValidationEventMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → BranchTraceSound.Data,
    BranchTraceSound.Facts values splits tables s rows ops data ∧
    BranchLists.Closed (BranchStore.table values (DynamicTypingMatrix.bank tables s 1)) ∧
    BranchLastMarker.Markers values s rows ops data ∧
    ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin → ops.getD first 0 = 14 →
      ∃ last, InstructionSpans.Span rows first last ∧
        E values (f (rowAt events.rows first) 10) = ((data first).primary.val : F) ∧
        E values (BranchRowCheck.record splits tables s first).bankQuery.active = 1 ∧
        E values (BranchRowCheck.record splits tables s first).bankQuery.address =
          (((rows.getD first default).functionIndex*2^32+(data first).primary.val : Nat) : F) ∧
        BranchLists.Follows (BranchStore.table values (DynamicTypingMatrix.bank tables s 1)) (data first).head.val
          (BranchInstructionBody.labels rows data (first+1) (last-first-1)) ∧
        BranchInstructionBody.labels rows data (first+1) (last-first-1) ≠ [] ∧
        ∀ expected, BranchLists.Follows (BranchStore.table values (DynamicTypingMatrix.bank tables s 1)) (data first).head.val expected →
          BranchInstructionBody.labels rows data (first+1) (last-first-1) = expected

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchCertificate.check matrix splits tables statics events r = true)
    (listsChecked : BranchListCheck.check matrix splits tables (StructuredMatrix.stage r 2) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Complete values splits tables (StructuredMatrix.stage r 2) events rows ops := by
  obtain ⟨data,facts⟩ := BranchTraceSound.sound matrix splits tables statics events r checked listsChecked values one satisfied rows ops images schedule
  have closed := BranchStore.closed matrix splits tables _ listsChecked values one satisfied
  have parts := checked
  simp only [BranchCertificate.check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [BranchCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (StructuredMatrix.stage r 2).rows.length := images.1.trans links.1.1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  refine ⟨data,facts,closed,BranchLastMarker.sound values splits tables _ events rows ops schedule data facts,?_⟩
  intro first fb beginKind code
  obtain ⟨last,span⟩ := InstructionSpans.exists_span values events rows ops schedule first fb beginKind
  have row := BranchCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule first fb
  have begin : BranchStep.beginning (rows.getD first default).kind (ops.getD first 0) = true := by simp only [BranchStep.beginning,beginKind,code,and_self,decide_true]
  have active : E values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) first).bankQuery.active = 1 := by
    simpa only [begin,flag,ite_true] using (facts first fb).2.1.bankActive
  have qm : (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) first).bankQuery ∈ (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 0).queries := by
    change (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 0).queries.getD first default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [shape.2.2.2.1]; omega)
  obtain ⟨positive,present⟩ := BranchHeadSound.selected matrix splits tables _ listsChecked values one satisfied _ qm active (data first).head (facts first fb).1.2.1
  have complete := BranchInstructionBody.complete values splits tables _ events rows ops schedule data facts closed first last span code positive present
  have matched := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (List.all_eq_true.mp links.2 first (List.mem_range.mpr (by omega)))).1
  have primary := VariableSelectorCheck.point values _ _ matched.2.2.2 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at primary
  have primaryImage := primary.symm.trans (facts first fb).1.1
  refine ⟨last,span,primaryImage,active,?_,complete.1,complete.2,?_⟩
  · have key := (facts first fb).2.1.bankAddress
    simp only [begin,flag,ite_true,Semiring.one_mul] at key
    have expansion : E values (scale (f (rowAt (StructuredMatrix.stage r 2).rows first) 1) (Int.ofNat (2^32))++
        (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) first).primary) =
        E values (f (rowAt (StructuredMatrix.stage r 2).rows first) 1)*(Int.ofNat (2^32) : F)+
        E values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) first).primary := by
      simp only [E,eval_append,eval_scale]
      grind only
    rw [key]
    change E values (scale (f (rowAt (StructuredMatrix.stage r 2).rows first) 1) (Int.ofNat (2^32))++
      (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) first).primary) = _
    rw [expansion,row.2.2.1,(facts first fb).1.1]
    simp only [show ((Int.ofNat (2^32) : Int) : F) = ((2^32 : Nat) : F) from Ring.intCast_natCast (2^32),
      Semiring.natCast_add,Semiring.natCast_mul]
  · intro expected path
    exact BranchLists.complete_consumption _ _ expected _ path
      (BranchInstructionBody.consumed values splits tables _ events rows ops schedule data facts first last span code)

#print axioms sound
end ZkBuild.BranchComplete
