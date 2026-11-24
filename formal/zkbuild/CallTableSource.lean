import CallEntrySource
set_option autoImplicit false
namespace ZkBuild.CallTableSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (tags : CallRowSound.Tags values r .instructionBegin) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (indirect : CallMode.indirect code = true)
    (index : Fin (2^32)) (image : E values r.secondary = (index.val : F)) :
    E values r.tableQuery.active = 1 ∧ E values r.tableQuery.address = ((2*index.val+1 : Nat) : F) ∧
      E values r.tableQuery.value = 5 := by
  have links := (CallRowSound.links matrix r checked).2.2.2.2.2.2.2.2.2
  have qa := VariableSelectorCheck.point values _ _ links 6
  have qk := VariableSelectorCheck.point values _ _ links 7
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at qa qk
  change E values r.tableQuery.active = E values (f r.after 5) at qa
  change E values r.tableQuery.address = E values (f r.after 17) at qk
  have t1 := (InstructionRowSound.selectors values _ .instructionBegin tags).2.1
  change E values (f r.flags 1) = _ at t1
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have selected := eqs.indirectBegin
  simp only [t1,mode.2.2.1,indirect,ControlEvents.selected,decide_true,flag,ite_true,Semiring.one_mul] at selected
  have val := eqs.tableType
  simp only [selected,Semiring.one_mul,eval_sub,n,eval_constant values one,Ring.intCast_ofNat 5] at val
  refine ⟨qa.trans selected,?_,by grind only⟩
  have key := qk.trans eqs.tableAddress
  simp only [selected,Semiring.one_mul,eval_append,eval_scale,image,o,eval_constant values one,Ring.intCast_one] at key
  simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_one]
  grind only

def Access {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (index : Fin (2^32)) : Prop :=
  ∃ source ∈ (ModuleContextMatrix.bank tables context 0).entries,
    E values source.active = 1 ∧ E values source.address = ((2*index.val+1 : Nat) : F) ∧ E values source.value = 5

def All {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (context : ModuleContextMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i < rows.length → (rows.getD i default).kind = .instructionBegin → CallMode.indirect (ops.getD i 0) = true →
    ∃ index : Fin (2^32), E values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).secondary = (index.val : F) ∧
      Access values tables context index

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    All values splits tables signature context typing rows ops := by
  intro i ib kind indirect
  have row := CallCertificate.row matrix splits tables signature statics events typing checked values one rows images i ib
  have tags : CallRowSound.Tags values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i) .instructionBegin := by
    rw [← kind]; exact row.2.1
  have ci : E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).row 8) = (ops.getD i 0 : F) :=
    row.2.2.2.trans (schedule.opcode i ib).2.1
  obtain ⟨_,index,_,image⟩ := CallRowSound.immediates matrix _ row.1 values one satisfied
  have read := query matrix _ row.1 values one satisfied tags _ (schedule.opcode i ib).1 ci indirect index image
  have parts := checked
  simp only [CallCertificate.check,Bool.and_eq_true_iff] at parts
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (DynamicTypingCheck.stage typing 3).rows.length := images.1.trans links.1
  have member : (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).tableQuery ∈
      (DynamicTypingMatrix.bank tables (DynamicTypingCheck.stage typing 3) 0).queries := by
    change (DynamicTypingMatrix.bank tables (DynamicTypingCheck.stage typing 3) 0).queries.getD i default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [shape.2.2.2.2.2,← size]; exact ib)
  obtain ⟨source,sm,sa,sk,sv⟩ := (DynamicTypingSource.environment_origins matrix splits tables signature context locals events typing typingChecked values one satisfied).2.2 _ member read.1
  exact ⟨index,image,source,sm,sa,sk.trans read.2.1,sv.trans read.2.2⟩

#print axioms query
#print axioms sound
end ZkBuild.CallTableSource
