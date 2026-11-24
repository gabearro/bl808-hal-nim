import CallHeadSource
import CallInstructionBody
import CallSemanticSource
set_option autoImplicit false
namespace ZkBuild.CallBodySource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- Every source call has one complete body, with initial heads selected from
    source metadata and every subsequent list read authenticated. -/
def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → CallTraceSound.Inputs,
    CallReadTrace.Facts values splits tables indexed signature typing rows ops data ∧
    ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin → CallMode.active (ops.getD first 0) = true →
      ∃ last, ∃ primary secondary : Fin (2^32), ∃ params results : List Nat, ∃ indexTokens rest : List StaticEvents.Token,
        InstructionSpans.Span rows first last ∧
        E values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).primary = (primary.val : F) ∧
        E values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).secondary = (secondary.val : F) ∧
        CallHeadSource.Selected values body tables declaration indexed signature (CallMode.indirect (ops.getD first 0)) primary (data first).params (data first).results ∧
        SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) (data first).params.val params ∧
        SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) (data first).results.val results ∧
        InstructionSpanState.body rows first last = indexTokens ++ rest ∧
        (if CallMode.indirect (ops.getD first 0) then ∃ actual, CallEvents.InputOk 0 actual ∧ indexTokens = [StaticEvents.Token.pop actual]
         else indexTokens = []) ∧
        CallEvents.Body params results (CallMode.tail (ops.getD first 0)) rest ∧
        (InstructionSpanState.body rows first last).length = last-first-1

theorem complete {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Complete values body splits tables declaration indexed signature typing rows ops := by
  obtain ⟨data,facts⟩ := CallReadTrace.sound matrix body splits tables declaration indexed signature space signatureChecked statics events typing accepted
    values one satisfied rows ops images schedule
  have trace : CallInstructionBody.Trace (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) rows ops data :=
    fun i ib => ⟨(facts i ib).2.1,(facts i ib).2.2.2⟩
  refine ⟨data,facts,?_⟩
  intro first fb beginKind active
  obtain ⟨last,span⟩ := InstructionSpans.exists_span values events rows ops schedule first fb beginKind
  have row := CallCertificate.row matrix splits tables signature statics events typing accepted values one rows images first fb
  have tags : CallRowSound.Tags values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first) .instructionBegin := by
    rw [← beginKind]; exact row.2.1
  have ci : E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).row 8) = (ops.getD first 0 : F) :=
    row.2.2.2.trans (schedule.opcode first fb).2.1
  obtain ⟨primary,secondary,pi,si⟩ := CallRowSound.immediates matrix _ row.1 values one satisfied
  have query := CallHeadSource.query matrix _ row.1 values one satisfied tags _ (schedule.opcode first fb).1 ci active primary pi
  have parts := accepted
  simp only [CallCertificate.check,Bool.and_eq_true_iff] at parts
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (DynamicTypingCheck.stage typing 3).rows.length := images.1.trans links.1
  have member : (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).metadata ∈ signature.extraMetadata := by
    change signature.extraMetadata.getD first default ∈ signature.extraMetadata
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [shape.2.2.2.1,← size]; exact fb)
  have source := CallHeadSource.selected matrix body splits tables declaration indexed signature space signatureChecked _ row.1 member
    values one satisfied _ primary (data first) (facts first fb).1 query.1 query.2
  have selection := source
  obtain ⟨_,_,_,_,message,types,tid,params,results,_,_,_,_,_,_,_,pr,rr,_⟩ := selection
  obtain ⟨indexTokens,rest,shapeBody,indexBody,bodyProof⟩ := CallInstructionBody.body_sound values events rows ops schedule _ data trace first last span active params results pr rr
  exact ⟨last,primary,secondary,params,results,indexTokens,rest,span,pi,si,source,pr,rr,shapeBody,indexBody,bodyProof,
    CallInstructionBody.body_length values events rows ops schedule _ data trace first last span active⟩

def SourceBodies {F : Type} [Field F] (values : Nat → F) (declaration : DeclarationMatrix.Record)
    (message : List Sha256.Byte) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin → CallMode.active (ops.getD first 0) = true →
    ∃ last, ∃ types : List DeclarationType.Decoded, ∃ tid : Nat, ∃ params results : List Nat, ∃ indexTokens rest : List StaticEvents.Token,
      InstructionSpans.Span rows first last ∧ Related (DeclarationType.Represents values) declaration.types types ∧ tid < types.length ∧
      DeclarationFraming.Framed message (types.getD tid default) ∧
      params.length = (types.getD tid default).params ∧ results.length = (types.getD tid default).results ∧
      SourceTypeLists.Matches message (types.getD tid default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD tid default).resultsStart false results ∧
      InstructionSpanState.body rows first last = indexTokens ++ rest ∧
      (if CallMode.indirect (ops.getD first 0) then ∃ actual, CallEvents.InputOk 0 actual ∧ indexTokens = [StaticEvents.Token.pop actual]
       else indexTokens = []) ∧ CallEvents.Body params results (CallMode.tail (ops.getD first 0)) rest

theorem matched {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (rows : List Row) (ops : List Nat) (complete : Complete values body splits tables declaration indexed signature typing rows ops)
    (message : List Sha256.Byte)
    (unique : ∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) :
    SourceBodies values declaration message rows ops := by
  obtain ⟨data,_,bodies⟩ := complete
  intro first fb beginKind active
  obtain ⟨last,primary,secondary,params,results,indexTokens,rest,span,_,_,selected,pr,rr,shape,indexBody,run,_⟩ := bodies first fb beginKind active
  obtain ⟨types,tid,images,bound,_,framed,pc,rc,pm,rm⟩ :=
    CallHeadSource.lists values body tables declaration indexed signature _ primary (data first).params (data first).results
      selected message unique params results pr rr
  exact ⟨last,types,tid,params,results,indexTokens,rest,span,images,bound,framed,pc,rc,pm,rm,shape,indexBody,run⟩

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (structured : StructuredMatrix.Record) (runtime : RuntimeContextMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (structuredChecked : StructuredCheck.check matrix splits tables events instructions signature indexed declaration structured = true)
    (runtimeChecked : RuntimeContextCheck.check matrix body tables context instructions events runtime = true)
    (semanticChecked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row) (ops : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧
      InstructionSemanticSound.Schedule values events rows ops ∧ OperandStackCertificate.Trace rows ∧
      InstructionPartition.Partition rows ops ∧ Complete values body splits tables declaration indexed signature typing rows ops ∧
      SourceBodies values declaration message rows ops := by
  have sig := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1).2
  obtain ⟨message,rows,ds,first,ops,tags,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
      runtimeFacts,runtimeBanks,runtimeCatalog,images,lifo,schedule,stackTrace,variables,origins,signatures,bodies,partition,calls,nodes⟩ :=
    CallSemanticSource.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature indexed declaration typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked sig typingChecked
      structuredChecked runtimeChecked semanticChecked values one satisfied
  have calls := complete matrix body splits tables declaration indexed signature space signatureChecked statics events typing semanticChecked values one satisfied rows ops images schedule
  exact ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,
    matched values body splits tables declaration indexed signature typing rows ops calls message unique⟩

#print axioms matched
#print axioms source_bound

#print axioms complete
end ZkBuild.CallBodySource
