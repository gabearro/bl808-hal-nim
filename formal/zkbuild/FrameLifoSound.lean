import FrameReadSource
set_option autoImplicit false
namespace ZkBuild.FrameLifoSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

structure Live (rows : List Row) (entries : List MemoryTrace.Entry) (first : Nat) : Prop where
  invariant : ∀ i, i≤rows.length → FrameTokenStack.Invariant rows entries first i
  closed : FrameTokenStack.frames rows entries rows.length=[]
  target : ∀ i, i<rows.length → (FrameTokenStack.entry entries (2*i)).active=true →
    ∃ slot, slot<ControlDepthTrace.depth rows i ∧
      (FrameTokenStack.entry entries (2*i)).address=(rows.getD i default).functionIndex*bound+slot ∧
      (FrameTokenStack.entry entries (2*i)).value=
        (FrameTokenStack.frames rows entries i).getD (ControlDepthTrace.depth rows i-1-slot) 0

def Selected {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record)
    (rows : List Row) (entries : List MemoryTrace.Entry) : Prop :=
  ∀ i, i<rows.length → (FrameTokenStack.entry entries (2*i)).active=true →
    ∃ slot, slot<ControlDepthTrace.depth rows i ∧
      (FrameTokenStack.entry entries (2*i)).address=(rows.getD i default).functionIndex*bound+slot ∧
      E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 36)=
        (((FrameTokenStack.frames rows entries i).getD (ControlDepthTrace.depth rows i-1-slot) 0):F)

def Complete {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) : Prop :=
  ∃ entries first, FrameTraceMemory.Facts values r rows entries ∧ Live rows entries first ∧ Selected values r rows entries

theorem live {F : Type} [Field F]
    (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (entries : List MemoryTrace.Entry)
    (facts : FrameTraceMemory.Facts values r rows entries) (first : Nat)
    (steps : ∀ i, i<rows.length → ControlEvents.Spec (ControlDepthTrace.depth rows i) (ControlDepthTrace.depth rows (i+1)) (rows.getD i default))
    (schedule : ∀ i, i<rows.length →
      FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind≠.padding → (rows.getD i default).functionIndex=(FunctionTraceSound.state rows first i).index))
    (closed : (FunctionTraceSound.state rows first rows.length).opened=false) : Live rows entries first := by
  have inv := FrameTokenStack.invariant rows entries first facts.length facts.projection steps schedule facts.reads
  refine ⟨inv,(inv rows.length (by omega)).2.2.1 closed,?_⟩
  intro i ib active
  obtain ⟨slot,sb,address⟩ := facts.targets i ib active
  obtain ⟨length,matched,unopened,tail⟩ := inv i (by omega)
  have sc := schedule i ib
  have rowMatch : FrameTokenStack.Matches (FrameTokenStack.frames rows entries i)
      (ControlRefinement.view ((rows.getD i default).functionIndex*bound) (FrameTokenStack.memory entries i)) := by
    by_cases padding : (rows.getD i default).kind=.padding
    · have off : (FunctionTraceSound.state rows first i).opened=false := by
        simpa only [FunctionEvents.ScheduleOk,padding,or_true,ite_true] using sc.1
      rw [unopened off]; trivial
    · rw [sc.2 padding]; exact matched
  rw [FrameTokenStack.pair_suffix entries rows.length i facts.length ib] at tail
  have read := tail.1 active (facts.projection i ib).1
  have ordinal : ControlDepthTrace.depth rows i-1-slot < (FrameTokenStack.frames rows entries i).length := by omega
  have actual := FrameTokenStack.target_value _ _ rowMatch (ControlDepthTrace.depth rows i-1-slot) ordinal
  have location : (FrameTokenStack.frames rows entries i).length-1-(ControlDepthTrace.depth rows i-1-slot)=slot := by omega
  rw [location] at actual
  rw [address] at read
  change (FrameTokenStack.memory entries i) ((rows.getD i default).functionIndex*bound+slot)=_ at actual
  have same := Option.some.inj (read.symm.trans actual)
  refine ⟨slot,sb,address,?_⟩
  simpa only [← List.getElem_eq_getD (h:=ordinal) 0] using same

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (depthsChecked : FrameDepthCheck.checkStage matrix splits tables r=true)
    (controls : ControlCertificate.check matrix events=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values r rows := by
  obtain ⟨entries,memory⟩ := FrameTraceMemory.sound matrix splits tables events r checked depthsChecked controls
    values one satisfied rows ops images schedule
  have depths := ControlDepthTrace.sound matrix events controls values one satisfied rows images
  obtain ⟨other,first,oi,size,_,_,states,sc⟩ := FunctionTraceSound.trace matrix events controls values one satisfied
  have same := OperandRepresentationUnique.trace values _ other rows oi images
  subst other
  have closed := FunctionTraceSound.closed matrix _ (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp controls).1).2
    values one satisfied rows first size (states rows.length (by omega)).2.1
  have stack := live values r rows entries memory first depths.step sc closed
  have frameShape := (Bool.and_eq_true_iff.mp checked).1
  simp only [FrameRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at frameShape
  have ms := frameShape.1.1.1.2.2.2.2.2.2.1
  have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).2).1
  have rowSize : rows.length=(StructuredMatrix.stage r 3).rows.length := images.1.trans linked.1
  refine ⟨entries,first,memory,stack,?_⟩
  intro i ib active
  obtain ⟨slot,sb,address,value⟩ := stack.target i ib active
  have row := FrameCertificate.row matrix events r checked values rows ops images schedule i ib
  have tags := FrameSelectors.tags values one _ _ _ row.2
  have cats := FrameOpcodes.categories matrix _ row.1 values one satisfied _ (schedule.opcode i ib).1 row.2.opcode
  have meaning := FrameRowSound.meaning matrix _ row.1 values one satisfied
  have reading := FrameSelectors.active values _ _ _ tags cats
    (meaning.multiply _ _ 13 (by simp [multiplies]))
  have faces := FrameRowImages.interface matrix _ row.1 values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
  have represented := FrameMemorySound.represented_at values r.frames entries memory.represented (2*i) (by omega)
  have enabled : E values (readActive (record r.frames (StructuredMatrix.stage r 3) i))=1 := by
    have h := faces.1.symm.trans represented.1
    change (entries.getD (2*i) MemoryPriorWrite.zero).active=true at active
    simpa only [active,Bool.toNat_true,Semiring.natCast_one] using h
  have mode : FrameSelectors.reads (rows.getD i default).kind (ops.getD i 0)=true := by
    have h := reading.symm.trans enabled
    cases b : FrameSelectors.reads (rows.getD i default).kind (ops.getD i 0)
    · simp only [b,flag,ite_false,Bool.false_eq_true] at h
      exact False.elim (Field.zero_ne_one h)
    · rfl
  have selected := FrameReadSource.selected matrix _ row.1 values one satisfied _ _ tags cats mode
  refine ⟨slot,sb,address,?_⟩
  exact selected.trans (represented.2.2.2.1.trans (congrArg (fun n:Nat => (n:F)) value))

#print axioms live
#print axioms sound
end ZkBuild.FrameLifoSound
