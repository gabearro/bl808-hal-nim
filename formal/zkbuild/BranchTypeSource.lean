import BranchSourceSound
import BranchTypeSound
import BranchMemberTag
import BranchTypePending
import BranchTypeBehavior
import FrameSound
import FrameLifoSound
import FramePadTrace
import FrameWriteValue
import FrameInstructionSource
import FramePadOrigin
import BranchFrameSource
import BranchLabelLists
import BranchOperandSource
import BranchOperandOrder
import BranchTypedOperands
import BranchActionSource
import BranchFloorInvariant
import BranchPlanSource
set_option autoImplicit false
namespace ZkBuild.BranchTypeSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- Authenticated branch target lists, scalar type guards, ROM lookups, and
    scratch restorations share one source-bound canonical trace. This theorem
    does not yet establish whole-module validation or native-compilation refinement. -/
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
    (parametricChecked : ParametricCertificate.check matrix statics events = true)
    (branchChecked : BranchCertificate.check matrix splits tables statics events structured = true)
    (listsChecked : BranchListCheck.check matrix splits tables (StructuredMatrix.stage structured 2) = true)
    (branchTypeChecked : BranchTypeCertificate.check matrix splits tables statics events structured = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed structured = true)
    (framesChecked : FrameCertificate.check matrix events structured = true)
    (frameDepthsChecked : FrameDepthCheck.checkStage matrix splits tables structured = true)
    (instructionEventsChecked : InstructionEventCheck.checkStage matrix tables instructions=true)
    (instructionInfoChecked : InstructionInfoCheck.checkStage matrix tables catalog decoders instructions=true)
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
      CallRuntimeSource.Bodies values declaration imports splits tables context signature typing message rows ops ∧
      ParametricSourceSound.Complete values events rows ops ∧
      BranchOrigins.Origins values tables instructions structured ∧
      BranchComplete.Complete values splits tables (StructuredMatrix.stage structured 2) events rows ops ∧
      BranchTypeSound.Facts values splits tables indexed structured rows ops ∧
      BranchMemberTag.Inputs values splits structured rows ∧
      BranchTypePending.Trace values splits structured rows ops ∧
      BranchTypeBehavior.Complete values splits structured rows ops ∧
      FrameSound.Facts values structured rows ops ∧
      FrameLifoSound.Complete values structured rows ∧
      FramePadTrace.Encoded values structured rows ops ∧
      FrameWriteValue.Writes values structured rows ops ∧
      FrameWriteValue.Complete values structured rows ops ∧
      FrameInstructionSource.Complete values instructions structured rows ops ∧
      InstructionEventSound.Ends values tables instructions ∧
      FramePadOrigin.Resolved values instructions structured rows ∧
      BranchFrameSource.Complete values body splits tables declaration indexed signature structured rows ops ∧
      BranchLabelLists.Complete values body splits tables declaration indexed signature structured rows ops ∧
      BranchListRead.Inputs values splits tables indexed structured rows ∧
      BranchOperandSource.Inputs values body splits tables declaration indexed signature structured rows ops ∧
      BranchOperandOrder.Complete values splits structured rows ops ∧
      BranchTypedOperands.Complete values body splits tables declaration indexed signature structured rows ops ∧
      BranchActionSource.Complete values body splits tables declaration indexed signature structured rows ops ∧
      (∃ depths firstFunction, EventSemanticLifo.Trace rows depths firstFunction) ∧
      BranchFloorInvariant.Complete rows ops ∧
      BranchPlanSource.Complete values body splits tables declaration indexed signature structured rows ops := by
  obtain ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls,parametric,origins,complete⟩ :=
    BranchSourceSound.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature space indexed declaration imports typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked
      importsChecked typingChecked structuredChecked runtimeChecked semanticChecked parametricChecked branchChecked listsChecked values one satisfied
  have indexedChecked := importsChecked
  simp only [ImportSound.check,SignatureSound.check,Bool.and_eq_true_iff] at indexedChecked
  have controlCertificate : ControlCertificate.check matrix events = true := by
    have pc := parametricChecked
    simp only [ParametricCertificate.check,InstructionSemanticSound.check,InstructionCertificate.check,
      EventSemanticSound.check,Bool.and_eq_true_iff] at pc
    exact pc.1.1.1.1.1.1.1
  have eventSemantic : EventSemanticSound.check matrix events=true := by
    have pc := parametricChecked
    simp only [ParametricCertificate.check,InstructionSemanticSound.check,InstructionCertificate.check,
      Bool.and_eq_true_iff] at pc
    exact pc.1.1.1.1.1
  obtain ⟨lifoRows,depths,firstFunction,lifoImages,lifo⟩ := EventSemanticLifo.sound matrix events eventSemantic values one satisfied
  have lifoSame := OperandRepresentationUnique.trace values _ lifoRows rows lifoImages images
  subst lifoRows
  have controls : ControlRowCheck.checkStage matrix (ValidationEventCheck.stage events 2) = true := by
    have pc := parametricChecked
    simp only [ParametricCertificate.check,InstructionSemanticSound.check,InstructionCertificate.check,
      EventSemanticSound.check,ControlCertificate.check,Bool.and_eq_true_iff] at pc
    exact pc.1.1.1.1.1.1.1.1.2
  have eventLinks : ValidationEventCheck.links events instructions=true := by
    have h := eventsChecked
    simp only [ValidationEventCheck.check,Bool.and_eq_true_iff] at h
    exact h.1.1.1.1.1.1.1
  have structuredLinks : StructuredCheck.links tables events instructions signature indexed declaration structured=true := by
    have h := structuredChecked
    simp only [StructuredCheck.check,Bool.and_eq_true_iff] at h
    exact h.1.1.1.1
  have instructionSources := FrameInstructionSource.sound matrix tables instructions catalog decoders events signature indexed declaration structured
    instructionEventsChecked instructionInfoChecked eventLinks structuredLinks framesChecked values one satisfied rows ops images schedule
  have labelLists := BranchLabelLists.sound matrix body splits tables declaration indexed signature space
    (Bool.and_eq_true_iff.mp importsChecked).1 events instructions statics structured structuredLinks branchTypeChecked
    lookupChecked framesChecked values one satisfied rows ops images schedule
  have listReads := BranchListRead.trace matrix body tables splits declaration indexed indexedChecked.1.1.1
    statics events structured branchTypeChecked lookupChecked values one satisfied rows ops images schedule
  have pending := BranchTypePending.sound matrix splits tables statics events structured branchTypeChecked values one satisfied rows ops images schedule
  have sourceOperands := BranchOperandSource.sound values body splits tables declaration indexed signature structured rows ops listReads
    (BranchHeadOrigin.trace matrix splits tables statics events structured branchTypeChecked values one satisfied rows ops images schedule)
    labelLists pending
  have typedOperands := BranchTypedOperands.sound matrix body splits tables declaration indexed signature statics events structured branchTypeChecked lookupChecked
    framesChecked values one satisfied rows ops images schedule sourceOperands
  have actionPlans := BranchActionSource.sound matrix body splits tables declaration indexed signature statics events structured branchTypeChecked lookupChecked
    framesChecked values one satisfied rows ops images schedule labelLists typedOperands
  have floorFacts := BranchFloorInvariant.sound rows ops depths firstFunction lifo
    (BranchActionAlphabet.sound matrix events structured framesChecked values one satisfied rows ops images schedule)
    (BranchActionSequence.sound matrix splits tables indexed statics events structured branchTypeChecked lookupChecked
      framesChecked values one satisfied rows ops images schedule)
  exact ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls,parametric,origins,complete,
    BranchTypeSound.sound matrix splits tables indexed statics events structured branchTypeChecked lookupChecked values one satisfied rows ops images schedule,
    BranchMemberTag.trace matrix body tables splits declaration indexed indexedChecked.1.1.1 statics events structured
      branchTypeChecked lookupChecked values one satisfied rows ops images schedule,
    pending,
    BranchTypeBehavior.sound matrix splits tables indexed statics events structured branchTypeChecked lookupChecked values one satisfied rows ops images schedule,
    FrameSound.sound matrix events structured framesChecked controls values one satisfied rows ops images schedule,
    FrameLifoSound.sound matrix splits tables events structured framesChecked frameDepthsChecked controlCertificate values one satisfied rows ops images schedule,
    FramePadTrace.encoded matrix events structured framesChecked values one satisfied rows ops images schedule,
    FrameWriteValue.sound matrix events structured framesChecked values one satisfied rows ops images schedule,
    FrameWriteValue.complete matrix splits tables events structured framesChecked frameDepthsChecked controlCertificate values one satisfied rows ops images schedule,
    instructionSources,
    InstructionEventSound.ends matrix tables instructions instructionEventsChecked values one satisfied,
    FramePadOrigin.resolved values instructions structured rows ops
      (FramePadOrigin.trace matrix events structured framesChecked values one satisfied rows ops images schedule) instructionSources,
    BranchFrameSource.sound matrix body splits tables declaration indexed signature space
      (Bool.and_eq_true_iff.mp importsChecked).1 events instructions statics structured structuredLinks branchTypeChecked
      lookupChecked framesChecked values one satisfied rows ops images schedule,
    labelLists,listReads,
    sourceOperands,
    BranchOperandOrder.sound matrix splits tables indexed statics events structured branchTypeChecked lookupChecked
      framesChecked values one satisfied rows ops images schedule,
    typedOperands,
    actionPlans,⟨depths,firstFunction,lifo⟩,floorFacts,
    BranchPlanSource.sound values body splits tables declaration indexed signature structured rows ops actionPlans floorFacts stackTrace⟩

#print axioms source_bound
end ZkBuild.BranchTypeSource
