import CallBodySource
import CallFunctionSource
import CallRootSource
import CallTableSource
import CallSignatureBody
set_option autoImplicit false
namespace ZkBuild.CallRuntimeSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- Whole call bodies use source-selected function/type signatures, the
    actual caller's results for tail calls, and authenticated table entries. -/
def Bodies {F : Type} [Field F] (values : Nat → F) (declaration : DeclarationMatrix.Record)
    (imports : ImportMatrix.Record) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (context : ModuleContextMatrix.Record)
    (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (message : List Sha256.Byte) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin → CallMode.active (ops.getD first 0) = true →
    ∃ last, ∃ primary secondary caller : Fin (2^32), ∃ params results currentParams current : List Nat,
      InstructionSpans.Span rows first last ∧
      E values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).primary = (primary.val : F) ∧
      E values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) first).secondary = (secondary.val : F) ∧ caller.val = (rows.getD first default).functionIndex ∧
      CallFunctionSource.Selected values declaration imports message caller currentParams current ∧
      (CallMode.indirect (ops.getD first 0) = false → CallFunctionSource.Selected values declaration imports message primary params results) ∧
      (CallMode.indirect (ops.getD first 0) = true → CallTableSource.Access values tables context secondary) ∧
      (CallMode.tail (ops.getD first 0) = true → current = results) ∧
      CallSignatureBody.Typed (ops.getD first 0) params results current (InstructionSpanState.body rows first last) ∧
      ∃ types : List DeclarationType.Decoded, ∃ tid : Nat,
        Related (DeclarationType.Represents values) declaration.types types ∧ tid < types.length ∧
        (CallMode.indirect (ops.getD first 0) = true → tid = primary.val) ∧
        DeclarationFraming.Framed message (types.getD tid default) ∧
        params.length = (types.getD tid default).params ∧ results.length = (types.getD tid default).results ∧
        SourceTypeLists.Matches message (types.getD tid default).paramsStart true params ∧
        SourceTypeLists.Matches message (types.getD tid default).resultsStart false results

theorem bodies {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (importsChecked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (complete : CallBodySource.Complete values body splits tables declaration indexed signature typing rows ops)
    (message : List Sha256.Byte)
    (unique : ∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) :
    Bodies values declaration imports splits tables context signature typing message rows ops := by
  obtain ⟨data,facts,allBodies⟩ := complete
  have signatureChecked := (Bool.and_eq_true_iff.mp importsChecked).1
  have roots := CallRootSource.sound matrix body splits tables declaration indexed signature space signatureChecked statics events typing
    checked values one satisfied rows ops images data facts
  have tableReads := CallTableSource.sound matrix splits tables signature context locals statics events typing typingChecked checked
    values one satisfied rows ops images schedule
  intro first fb kind active
  obtain ⟨last,primary,secondary,params,results,indexTokens,rest,span,pi,si,selected,pr,rr,shape,indexBody,run,_⟩ := allBodies first fb kind active
  obtain ⟨start,caller,earlier,beginKind,callerIndex,callerSelected,root,tailRoot⟩ := roots first fb kind
  have callerSelection := callerSelected
  obtain ⟨_,_,_,_,_,_,_,currentParams,current,_,_,_,_,_,_,_,cpr,crr,_⟩ := callerSelection
  have tailResults : CallMode.tail (ops.getD first 0) = true → current = results := by
    intro tail
    have same := tailRoot tail
    have sameRep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) (data first).results.val current := by
      rw [same]; exact crr
    exact SignatureLists.represents_unique _ _ current results sameRep rr
  have callerSource := CallFunctionSource.selected matrix body tables splits declaration indexed signature space imports importsChecked
    values one satisfied caller (data start).params (data start).results callerSelected message unique currentParams current cpr crr
  refine ⟨last,primary,secondary,caller,params,results,currentParams,current,span,pi,si,callerIndex,callerSource,?_,?_,tailResults,?_,?_⟩
  · intro direct
    apply CallFunctionSource.selected matrix body tables splits declaration indexed signature space imports importsChecked
      values one satisfied primary (data first).params (data first).results
      (by simpa only [direct] using selected) message unique params results pr rr
  · intro indirect
    obtain ⟨index,image,access⟩ := tableReads first fb kind indirect
    have same := DeclarationLocations.natural_equal (F := F) index.val secondary.val
      (by have := index.isLt; omega) (by have := secondary.isLt; omega) (image.symm.trans si)
    have eq : index = secondary := Fin.ext same
    subst index
    exact access
  · rw [shape]
    exact CallSignatureBody.body _ active params results current tailResults indexTokens rest indexBody run
  · exact CallHeadSource.lists values body tables declaration indexed signature _ primary (data first).params (data first).results
      selected message unique params results pr rr

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (imports : ImportMatrix.Record) (typing : DynamicTypingMatrix.Record) (structured : StructuredMatrix.Record) (runtime : RuntimeContextMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (importsChecked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
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
      InstructionPartition.Partition rows ops ∧ CallBodySource.Complete values body splits tables declaration indexed signature typing rows ops ∧
      CallBodySource.SourceBodies values declaration message rows ops ∧
      Bodies values declaration imports splits tables context signature typing message rows ops := by
  have signatureChecked := (Bool.and_eq_true_iff.mp importsChecked).1
  obtain ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,complete,matched⟩ :=
    CallBodySource.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature space indexed declaration typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked
      signatureChecked typingChecked structuredChecked runtimeChecked semanticChecked values one satisfied
  exact ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,complete,matched,
    bodies matrix body splits tables declaration indexed signature space imports importsChecked context locals statics events typing
      typingChecked semanticChecked values one satisfied rows ops images schedule complete message unique⟩

#print axioms source_bound

#print axioms bodies
end ZkBuild.CallRuntimeSource
