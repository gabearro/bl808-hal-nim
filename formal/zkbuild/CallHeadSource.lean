import SignatureTypeSource
import CallReadTrace
set_option autoImplicit false
namespace ZkBuild.CallHeadSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (tags : CallRowSound.Tags values r .instructionBegin) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (active : CallMode.active code = true)
    (primary : Fin (2^32)) (pi : E values r.primary = (primary.val : F)) :
    E values r.metadata.active = 1 ∧
    E values r.metadata.address = ((2*primary.val+(CallMode.indirect code).toNat : Nat) : F) := by
  have links := (CallRowSound.links matrix r checked).2.2.2.2.2.2.2.2.2
  have ma := VariableSelectorCheck.point values _ _ links 0
  have mk := VariableSelectorCheck.point values _ _ links 1
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at ma mk
  change E values r.metadata.active = E values (f r.flags 0 ++ f r.after 4) at ma
  change E values r.metadata.address = E values (f r.after 8 ++ f r.after 9) at mk
  obtain ⟨t0,t1,_⟩ := InstructionRowSound.selectors values _ .instructionBegin tags
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  simp only [eval_append,eqs.begin,eqs.functionAddress,eqs.calleeAddress,mode.1,mode.2.2.1,t0,t1,
    ControlEvents.selected,reduceCtorEq,decide_true,decide_false,active,flag,Bool.false_eq_true,ite_false,ite_true,
    eval_scale,pi,Ring.intCast_ofNat] at ma mk
  constructor
  · grind only
  · cases h : CallMode.indirect code <;> simp [h,Semiring.natCast_add,Semiring.natCast_mul] at mk ⊢ <;> grind only

/-- Lists are tied to a declared type and to the queried function/type key.
    Parameter lists use operand-pop order, as specified by SourceTypeLists. -/
def Selected {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (indirect : Bool) (primary paramsHead resultsHead : Fin (2^32)) : Prop :=
  ∃ row ∈ signature.metadata, E values row.entry.active = 1 ∧
    E values row.entry.address = ((2*primary.val+indirect.toNat : Nat) : F) ∧
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (tid : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) declaration.types types ∧ tid < types.length ∧
      (if indirect then tid = primary.val else E values row.typeIndex = (tid : F)) ∧
      DeclarationFraming.Framed message (types.getD tid default) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramsHead.val params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultsHead.val results ∧
      params.length = (types.getD tid default).params ∧ results.length = (types.getD tid default).results ∧
      SourceTypeLists.Matches message (types.getD tid default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD tid default).resultsStart false results

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true) (member : r.metadata ∈ signature.extraMetadata)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (indirect : Bool) (primary : Fin (2^32)) (data : CallTraceSound.Inputs) (image : CallTraceSound.DataImage values r data)
    (active : E values r.metadata.active = 1)
    (address : E values r.metadata.address = ((2*primary.val+indirect.toNat : Nat) : F)) :
    Selected values body tables declaration indexed signature indirect primary data.params data.results := by
  have sig := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1)
  have declarationCheck := (Bool.and_eq_true_iff.mp sig.1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp declarationCheck).1
  have splitChecks := (Bool.and_eq_true_iff.mp sourceCheck).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sourceCheck).1).2
  have parts := sig.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true parts.2
  let bank := SignatureMatrix.table tables signature 0
  have bm : bank ∈ tables := by
    have im : signature.tables.getD 0 0 ∈ signature.tables := by
      rw [← List.getElem_eq_getD 0]
      exact List.getElem_mem (by rw [links.1]; decide)
    change tables.getD (signature.tables.getD 0 0) default ∈ tables
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (links.2.1 _ im)
  have qm : r.metadata ∈ bank.queries := by
    change r.metadata ∈ (SignatureMatrix.table tables signature 0).queries
    rw [links.2.2.2.1]
    exact List.mem_append_right _ member
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix bank (List.all_eq_true.mp tableChecks _ bm) values one satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership r.metadata qm active
  change entry ∈ (SignatureMatrix.table tables signature 0).entries at em
  rw [links.2.2.1] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  have rowCheck := List.all_eq_true.mp parts.1.1 row rm
  have rowShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp rowCheck).1).1).1
  have sm : split splits row.heads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.1
  have shape := CallRowSound.links matrix r checked
  have checks := checked
  simp only [CallRowCheck.check,Bool.and_eq_true_iff] at checks
  have heads := SourceListSelection.equal_heads matrix r.heads (split splits row.heads) checks.1.2 (List.all_eq_true.mp splitChecks _ sm)
    shape.2.2.2.2.2.1 shape.2.2.2.2.2.2.1 rowShape.2.1.2.1 rowShape.2.1.2.2 values one satisfied
    (by
      have linked := VariableSelectorCheck.point values _ _ shape.2.2.2.2.2.2.2.2.2 2
      simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at linked
      rw [rowShape.2.1.1]
      exact linked.trans ev.symm)
  refine ⟨row,rm,ea,ek.trans address,?_⟩
  cases indirect with
  | false =>
    have key : E values row.entry.address = ((2*primary.val : Nat) : F) := by simpa using ek.trans address
    obtain ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,ti,frame,pb,rb,pi,ri,pr,rr,pc,rc,pm,rs⟩ :=
      SignatureSource.function_source_signature_bounded matrix body tables splits declaration indexed signature space signatureChecked values one satisfied
        row rm primary.val primary.isLt ea key
    have pSame := DeclarationLocations.natural_equal (F := F) data.params.val ph (by have := data.params.isLt; omega) (by omega)
      (image.1.symm.trans (heads.1.trans pi))
    have rSame := DeclarationLocations.natural_equal (F := F) data.results.val rh (by have := data.results.isLt; omega) (by omega)
      (image.2.1.symm.trans (heads.2.trans ri))
    exact ⟨message,types,tid,params,results,meaning,d0,d1,images,it,ti,frame,by rw [pSame]; exact pr,by rw [rSame]; exact rr,pc,rc,pm,rs⟩
  | true =>
    have key : E values row.entry.address = ((2*primary.val+1 : Nat) : F) := ek.trans address
    obtain ⟨message,types,ph,rh,params,results,meaning,d0,d1,images,it,frame,pb,rb,pi,ri,pr,rr,pc,rc,pm,rs⟩ :=
      SignatureTypeSource.type_source_signature matrix body tables splits declaration indexed signature space signatureChecked values one satisfied
        row rm primary.val primary.isLt ea key
    have pSame := DeclarationLocations.natural_equal (F := F) data.params.val ph (by have := data.params.isLt; omega) (by omega)
      (image.1.symm.trans (heads.1.trans pi))
    have rSame := DeclarationLocations.natural_equal (F := F) data.results.val rh (by have := data.results.isLt; omega) (by omega)
      (image.2.1.symm.trans (heads.2.trans ri))
    exact ⟨message,types,primary.val,params,results,meaning,d0,d1,images,it,rfl,frame,by rw [pSame]; exact pr,by rw [rSame]; exact rr,pc,rc,pm,rs⟩

/-- Eliminate the existential source lists using representation uniqueness.
    This ties the lists consumed by a complete call body to the same bytes. -/
theorem lists {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (indirect : Bool) (primary paramsHead resultsHead : Fin (2^32))
    (selected : Selected values body tables declaration indexed signature indirect primary paramsHead resultsHead)
    (message : List Sha256.Byte)
    (unique : ∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message)
    (params results : List Nat)
    (pr : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramsHead.val params)
    (rr : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultsHead.val results) :
    ∃ types : List DeclarationType.Decoded, ∃ tid : Nat,
      Related (DeclarationType.Represents values) declaration.types types ∧ tid < types.length ∧
      (indirect = true → tid = primary.val) ∧ DeclarationFraming.Framed message (types.getD tid default) ∧
      params.length = (types.getD tid default).params ∧ results.length = (types.getD tid default).results ∧
      SourceTypeLists.Matches message (types.getD tid default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD tid default).resultsStart false results := by
  obtain ⟨row,_,_,_,other,types,tid,ps,rs,source,_,_,images,bound,which,framed,pRep,rRep,pc,rc,pm,rm⟩ := selected
  have sameMessage := unique other source
  have sameParams := SignatureLists.represents_unique _ _ ps params pRep pr
  have sameResults := SignatureLists.represents_unique _ _ rs results rRep rr
  subst other; subst ps; subst rs
  exact ⟨types,tid,images,bound,by intro enabled; simpa only [enabled,ite_true] using which,framed,pc,rc,pm,rm⟩

#print axioms lists
#print axioms query
#print axioms selected
end ZkBuild.CallHeadSource
