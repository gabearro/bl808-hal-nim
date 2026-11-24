import ValidationEventSound
import InstructionSourceSound
set_option autoImplicit false
namespace ZkBuild.ValidationSourceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Decoders {F : Type} [Field F] (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (catalog : InstructionDecodeMatrix.Catalog)
    (decoders : List InstructionDecodeMatrix.Record) (values : Nat → F) (message : List Sha256.Byte) : Prop :=
  ∀ d ∈ decoders, ∃ output state,
    (InstructionDecodeMatrix.replay matrix body.tokens splits catalog d).run (SourceProgram.init d.program) = .ok (output,state) ∧
    SourceProgram.finished d.program state ∧ ModuleProgram.sameInputs output d.outputs ∧
    InstructionSourceSound.ProgramFacts matrix body splits values message state

def Stream {F : Type} [Field F] (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (catalog : InstructionDecodeMatrix.Catalog)
    (decoders : List InstructionDecodeMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (values : Nat → F) (message : List Sha256.Byte) : Prop :=
  ∃ result state, InstructionStreamCheck.run matrix body.tokens splits tables catalog decoders instructions = .ok (result,state) ∧
    SourceProgram.finished instructions.program state ∧ InstructionStreamCheck.outputLinks tables instructions result = true ∧
    InstructionStreamMatrix.frameCheck matrix instructions result = true ∧
    InstructionSourceSound.ProgramFacts matrix body splits values message state

def projected (events : ValidationEventMatrix.Record) : List (List Linear) :=
  events.rows.map fun row => [ValidationEventMatrix.f row 0,ValidationEventMatrix.f row 1,
    ValidationEventMatrix.f row 9,ValidationEventMatrix.f row 8,ValidationEventMatrix.f row 10,
    ValidationEventMatrix.f row 11,ValidationEventMatrix.f row 12]

theorem event_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (instructions : InstructionStreamMatrix.Record) (events : ValidationEventMatrix.Record)
    (linked : ValidationEventCheck.links events instructions = true) (values : Nat → F) :
    (projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) := by
  have links := _root_.of_decide_eq_true linked
  have same : ValidationEventMatrix.normalized instructions.events = ValidationEventMatrix.normalized (projected events) := links.2.2.2.2.1
  have image := congrArg (List.map (List.map (fun l => E values l))) same.symm
  change (projected events).map (fun row => row.map (fun l => R1CS.eval values (interpretLinear l))) =
    instructions.events.map (fun row => row.map (fun l => R1CS.eval values (interpretLinear l)))
  simpa only [ValidationEventMatrix.normalized,List.map_map,Function.comp_def,E,FullMatrix.evalLinear,
    normalized_linear_same_field] using image

/-- The instruction and validation replays share one committed message and the
    very same event expressions. This does not assert the remaining dynamic
    typing rules or a refinement of the entire runtime validator. -/
theorem checked {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      InstructionDecodeMatrix.catalogCheck catalog = true ∧
      Decoders matrix body splits catalog decoders values message ∧
      Stream matrix body splits tables catalog decoders instructions values message ∧
      (projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) ∧
      (∀ i, i < events.rows.length → ∃ opcode : Nat, opcode < 65536 ∧
        E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt events.rows i) 8) = (opcode : F) ∧
        OpcodeCatalog.admitted opcode = true) ∧
      (∀ s ∈ events.stages, ValidationEventSound.StageFacts matrix statics admission values s) ∧
      ValidationEventSound.MemoryFacts values events.operand ∧ ValidationEventSound.MemoryFacts values events.control ∧
      (∀ p ∈ statics, StaticLookupEmbedded.check matrix p.2 = true ∧ StaticLookupEmbedded.checkTable p.2 = true) ∧
      (∀ p ∈ admission, LookupEmbedded.check matrix p.2 = true ∧ p.2.columns = 1 ∧
        LookupEmbedded.checkTable p.2 16 ValidationEventAuditIO.allowed = true) := by
  obtain ⟨message,source,d0,d1,unique,opcodes,decoded,stream⟩ := InstructionSourceSound.verified
    matrix body splits tables context code catalog decoders instructions sourceChecked instructionsChecked values one satisfied
  obtain ⟨stages,operand,control,staticMatrices,admissionMatrices⟩ := ValidationEventSound.checked
    matrix statics admission instructions events eventsChecked values one satisfied
  have links : ValidationEventCheck.links events instructions = true := by
    have h := eventsChecked
    simp only [ValidationEventCheck.check,Bool.and_eq_true_iff] at h
    exact h.1.1.1.1.1.1.1
  refine ⟨message,source,d0,d1,unique,opcodes,decoded,stream,event_values instructions events links values,
    ?_,stages,operand,control,?_,?_⟩
  · exact ValidationEventSound.admitted_rows matrix statics admission instructions events catalogsChecked eventsChecked values one satisfied
  · intro p member
    exact ⟨staticMatrices p member,ValidationEventSound.static_table statics admission catalogsChecked p.1 p.2 member⟩
  · intro p member
    exact ⟨admissionMatrices p member,ValidationEventSound.admission_table statics admission catalogsChecked p.1 p.2 member⟩

#print axioms event_values
#print axioms checked
end ZkBuild.ValidationSourceSound
