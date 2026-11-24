import BranchScratchTrace
import BranchLookupSound
set_option autoImplicit false
namespace ZkBuild.BranchTypeSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

-- These are circuit-to-trace facts. Whole-body branch typing additionally
-- requires the state/count invariant and source signature interpretation.
structure Facts {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (splits : Splits)
    (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop where
  length : rows.length = (StructuredMatrix.stage r 5).rows.length
  row : ∀ i, i < rows.length →
    let rowRecord := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
    BranchTypeRowSound.Meaning values rowRecord ∧
    BranchTypeCertificate.Tags values rowRecord (rows.getD i default).kind (ops.getD i 0) ∧
    E values (f rowRecord.row 4) = ((rows.getD i default).valueType.val : F) ∧
    E values (f rowRecord.row 8) = (ops.getD i 0 : F) ∧
    ∃ expected : Fin 8, E values rowRecord.payload.low = (expected.val : F) ∧
      (E values (f rowRecord.after 33) = 1 → CallEvents.InputOk 0 (rows.getD i default).valueType.val) ∧
      (E values (BranchTypeRowCheck.argument rowRecord) = 1 →
        CallEvents.InputOk expected.val (rows.getD i default).valueType.val)
  lookup : ∀ i, i < rows.length → ∀ family, family < 4 →
    E values (BranchMergeCheck.record r i family).branch.active = 1 →
    ∃ source ∈ (BranchLookupCheck.bank tables indexed r family).entries, E values source.active = 1 ∧
      E values source.address = E values (BranchMergeCheck.record r i family).branch.address ∧
      E values source.value = E values (BranchMergeCheck.record r i family).branch.value
  scratch : ∃ entries, entries.length = rows.length ∧
    ShaProgram.Related (MemoryPacking.Represents values) (r.scratch.inputs.map MemoryEvidence.AccessRef.fields) entries ∧
    BranchScratchTrace.Facts entries (fun i => (rows.getD i default).valueType)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (statics : StaticCatalog)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Facts values splits tables indexed r rows ops := by
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule
  refine ⟨size,?_,?_,?_⟩
  · intro i ib
    have rc := row i ib
    exact ⟨BranchTypeRowSound.meaning matrix _ rc.1 values one satisfied,rc.2.1,rc.2.2.1,rc.2.2.2,
      BranchTypeScalar.type_guards matrix _ rc.1 values one satisfied (rows.getD i default).valueType rc.2.2.1⟩
  · intro i ib family fb active
    exact BranchLookupSound.origin matrix tables indexed r lookupChecked parts.1.2 values one satisfied
      i family (by omega) fb active
  · obtain ⟨entries,length,represented,facts⟩ := BranchScratchTrace.sound matrix splits r.scratch
      (StructuredMatrix.stage r 5) parts.1.1.2 values one satisfied (fun i => (rows.getD i default).valueType)
      (fun i ib => (row i (by omega)).2.2.1)
    exact ⟨entries,length.trans size.symm,represented,facts⟩

#print axioms sound
end ZkBuild.BranchTypeSound
