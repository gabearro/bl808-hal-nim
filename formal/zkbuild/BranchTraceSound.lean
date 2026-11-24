import BranchStep
import BranchStore
import ReadOnlyInactive
set_option autoImplicit false
namespace ZkBuild.BranchTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchStep
attribute [local instance] Ring.intCast Semiring.natCast

structure Data where
  primary : Cursor
  head : Cursor
  depth : Cursor
  next : Cursor
  deriving Inhabited

def state (rows : List Row) (ops : List Nat) (data : Nat → Data) : Nat → Cursor
  | 0 => ⟨0,by decide⟩
  | i+1 => advance (rows.getD i default).kind (ops.getD i 0)
      (prepare (rows.getD i default).kind (state rows ops data i) (data i).head) (data i).next

def Images {F : Type} [Field F] (values : Nat → F) (r : BranchRowCheck.Record) (d : Data) : Prop :=
  E values r.primary = (d.primary.val : F) ∧ E values r.bankQuery.value = (d.head.val : F) ∧
  E values r.payload.low = (d.depth.val : F) ∧ E values r.payload.high = (d.next.val : F) ∧
  E values r.nodeQuery.value = ((d.depth.val+2^32*d.next.val : Nat) : F)

theorem data_exists {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage)
    (rowsChecked : BranchRowCheck.checkStage matrix splits tables s = true)
    (listsChecked : BranchListCheck.check matrix splits tables s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < s.rows.length) : ∃ data : Data, Images values (BranchRowCheck.record splits tables s i) data := by
  have row := List.all_eq_true.mp (Bool.and_eq_true_iff.mp rowsChecked).2 i (List.mem_range.mpr ib)
  have rshape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp rowsChecked).1
  have parts := listsChecked
  simp only [BranchListCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  obtain ⟨primary,pi⟩ := BranchRowImages.primary matrix _ row values one satisfied
  obtain ⟨depth,next,di,ni,payload⟩ := BranchRowImages.payload matrix _ row values one satisfied
  have qm : (BranchRowCheck.record splits tables s i).bankQuery ∈ (DynamicTypingMatrix.bank tables s 0).queries := by
    change (DynamicTypingMatrix.bank tables s 0).queries.getD i default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [rshape.2.2.2.1]; exact ib)
  obtain ⟨head,hb,hi⟩ := ReadOnlyFacts.query_value matrix _ parts.1.1.1.2 values one satisfied _ qm
  rw [parts.1.1.1.1.2.1] at hb
  exact ⟨⟨primary,⟨head,hb⟩,depth,next⟩,pi,hi,di,ni,payload⟩

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchCertificate.check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → Data)
    (inputs : ∀ i, i < rows.length → Images values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i) (data i)) :
    ∀ i, i ≤ rows.length → E values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i).before = ((state rows ops data i).val : F) := by
  intro i ib
  induction i with
  | zero => simp [BranchRowCheck.record,state,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  | succ i ih =>
    have rb : i < rows.length := by omega
    have row := BranchCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i rb
    have inv := ih (by omega)
    have result := BranchStep.sound matrix _ row.1 values one satisfied _ _ (schedule.opcode i rb).1 row.2.2.2
      row.2.1 (state rows ops data i) (data i).head (data i).next inv (inputs i rb).2.1 (inputs i rb).2.2.2.1
    simpa [BranchRowCheck.record,state,f,DeclarationMatrix.get] using result.nextImage

def Facts {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (s : DynamicTypingMatrix.Stage) (rows : List Row) (ops : List Nat) (data : Nat → Data) : Prop :=
  ∀ i, i < rows.length →
    Images values (BranchRowCheck.record splits tables s i) (data i) ∧
    BranchStep.Facts values (BranchRowCheck.record splits tables s i) (rows.getD i default).kind (ops.getD i 0)
      (state rows ops data i) (data i).head (data i).next ∧
    (mark (rows.getD i default).kind (ops.getD i 0) = true →
      BranchStore.table values (DynamicTypingMatrix.bank tables s 1)
        (prepare (rows.getD i default).kind (state rows ops data i) (data i).head).val =
        some ⟨(data i).depth.val,(data i).next.val⟩) ∧
    E values (f (rowAt s.outputs i) 0) = ((data i).depth.val : F) ∧
    E values (f (rowAt s.outputs i) 1) = flag (mark (rows.getD i default).kind (ops.getD i 0) && decide ((data i).next.val = 0))

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchCertificate.check matrix splits tables statics events r = true)
    (listsChecked : BranchListCheck.check matrix splits tables (StructuredMatrix.stage r 2) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ data : Nat → Data, Facts values splits tables (StructuredMatrix.stage r 2) rows ops data := by
  classical
  have parts := checked
  simp only [BranchCertificate.check,Bool.and_eq_true_iff] at parts
  have linked := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (StructuredMatrix.stage r 2).rows.length := images.1.trans linked.1
  have choices (i : Nat) (ib : i < rows.length) := data_exists matrix splits tables _ parts.1.2 listsChecked values one satisfied i (by omega)
  let data : Nat → Data := fun i => if h : i < rows.length then Classical.choose (choices i h) else default
  have inputs (i : Nat) (ib : i < rows.length) : Images values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i) (data i) := by
    simpa only [data,dite_eq_left ib] using Classical.choose_spec (choices i ib)
  have inv := invariant matrix splits tables statics events r checked values one satisfied rows ops images schedule data inputs
  have listParts := listsChecked
  simp only [BranchListCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at listParts
  refine ⟨data,?_⟩
  intro i ib
  have row := BranchCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  have result := BranchStep.sound matrix _ row.1 values one satisfied _ _ (schedule.opcode i ib).1 row.2.2.2 row.2.1
    (state rows ops data i) (data i).head (data i).next (inv i (by omega)) (inputs i ib).2.1 (inputs i ib).2.2.2.1
  have outputs := BranchRowImages.outputs matrix _ row.1 values
  refine ⟨inputs i ib,result,?_,outputs.1.trans (inputs i ib).2.2.1,outputs.2.trans result.last⟩
  intro marked
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  have qm : (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i).nodeQuery ∈ (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 1).queries := by
    change (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 1).queries.getD
      ((DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 0).entries.length+(DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 1).entries.length+i) default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [shape.2.2.2.2]; omega)
  apply BranchStore.found matrix _ listParts.1.1.2 values one satisfied
  refine ⟨(prepare _ _ _).isLt,(data i).depth.isLt,(data i).next.isLt,_,qm,?_,?_,(inputs i ib).2.2.2.2⟩
  · simpa only [marked,flag,ite_true] using result.nodeActive
  · simpa only [marked,flag,ite_true,Semiring.one_mul] using result.nodeAddress

#print axioms data_exists
#print axioms invariant
#print axioms sound
end ZkBuild.BranchTraceSound
