import CallHeadSource
set_option autoImplicit false
namespace ZkBuild.CallEntrySource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem function_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (rows : List Row)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows) (i : Nat) (ib : i < rows.length) :
    E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).row 1) =
      ((rows.getD i default).functionIndex : F) := by
  have parts := checked
  simp only [CallCertificate.check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [CallCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (DynamicTypingCheck.stage typing 3).rows.length := images.1.trans links.1.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have same := VariableSelectorCheck.point values _ _ matched.1 1
  have equal : E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 1) =
      E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).row 1) := by
    simpa [CallRowCheck.record,f,DeclarationMatrix.get,List.getD,List.getElem?_take] using same
  exact equal.symm.trans (images.2 i ib).1.functionIndex

theorem metadata_member {F : Type} [Field F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (rows : List Row)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows) (i : Nat) (ib : i < rows.length) :
    (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).metadata ∈ signature.extraMetadata := by
  have parts := checked
  simp only [CallCertificate.check,Bool.and_eq_true_iff] at parts
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (DynamicTypingCheck.stage typing 3).rows.length := images.1.trans links.1
  change signature.extraMetadata.getD i default ∈ signature.extraMetadata
  rw [← List.getElem_eq_getD default]
  exact List.getElem_mem (by rw [shape.2.2.2.1,← size]; exact ib)

theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (tags : CallRowSound.Tags values r .functionBegin)
    (index : Nat) (image : E values (f r.row 1) = (index : F)) :
    E values r.metadata.active = 1 ∧ E values r.metadata.address = ((2*index : Nat) : F) := by
  have links := (CallRowSound.links matrix r checked).2.2.2.2.2.2.2.2.2
  have ma := VariableSelectorCheck.point values _ _ links 0
  have mk := VariableSelectorCheck.point values _ _ links 1
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at ma mk
  change E values r.metadata.active = E values (f r.flags 0 ++ f r.after 4) at ma
  change E values r.metadata.address = E values (f r.after 8 ++ f r.after 9) at mk
  obtain ⟨t0,t1,_⟩ := InstructionRowSound.selectors values _ .functionBegin tags
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  simp only [eval_append,eqs.functionAddress,eqs.calleeAddress,eqs.begin,t0,t1,
    ControlEvents.selected,reduceCtorEq,decide_true,decide_false,flag,Bool.false_eq_true,ite_false,ite_true,
    eval_scale,image] at ma mk
  constructor
  · grind only
  · simp only [Semiring.natCast_mul]
    grind only

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (i : Nat) (ib : i < rows.length) (kind : (rows.getD i default).kind = .functionBegin)
    (data : CallTraceSound.Inputs) (di : CallTraceSound.DataImage values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i) data) :
    ∃ index : Fin (2^32), index.val = (rows.getD i default).functionIndex ∧
      CallHeadSource.Selected values body tables declaration indexed signature false index data.params data.results := by
  let index : Fin (2^32) := ⟨(rows.getD i default).functionIndex,(images.2 i ib).2.1⟩
  have fields := CallCertificate.row matrix splits tables signature statics events typing checked values one rows images i ib
  have tags : CallRowSound.Tags values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i) .functionBegin := by
    rw [← kind]; exact fields.2.1
  have queries := query matrix _ fields.1 values one satisfied tags index.val
    (function_index matrix splits tables signature statics events typing checked values one rows images i ib)
  exact ⟨index,rfl,CallHeadSource.selected matrix body splits tables declaration indexed signature space signatureChecked _ fields.1
    (metadata_member matrix splits tables signature statics events typing checked values rows images i ib) values one satisfied false index data di
    queries.1 (by simpa using queries.2)⟩

#print axioms function_index
#print axioms query
#print axioms selected
end ZkBuild.CallEntrySource
