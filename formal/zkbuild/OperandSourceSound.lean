import OperandCertificate
import ValidationSourceSound
set_option autoImplicit false
namespace ZkBuild.OperandSourceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (operandChecked : OperandCertificate.check matrix events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      (ValidationSourceSound.projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) ∧
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧
      (∀ i, i < rows.length → OperandTraceSound.Transition rows i ∧
        OperandTraceSound.Projection values (ValidationEventCheck.stage events 1) rows i) ∧
      (rows.getD (rows.length-1) default).height = 0 ∧
      MemoryTrace.Reads (fun _ => none) (OperandMemorySound.projected rows) := by
  obtain ⟨message,source,d0,d1,unique,_,decoded,stream,linked,_⟩ := ValidationSourceSound.checked
    matrix body splits tables context code catalog decoders instructions statics admission events
    sourceChecked instructionsChecked catalogsChecked eventsChecked values one satisfied
  obtain ⟨rows,images,steps,finalHeight,memory⟩ := OperandCertificate.sound matrix events operandChecked values one satisfied
  exact ⟨message,rows,source,d0,d1,unique,decoded,stream,linked,images,steps,finalHeight,memory⟩

#print axioms source_bound
end ZkBuild.OperandSourceSound
