import BranchLookupSound
import BranchTypeScalar
import IndexedLengths
set_option autoImplicit false
namespace ZkBuild.BranchMemberTag
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem member_checked (matrix : Shape) (splits : Splits) (rows : List IndexedMatrix.MemberRow)
    (index : Nat) (ph po pn : Linear)
    (checked : IndexedMatrix.checkMembers matrix splits rows index ph po pn = true)
    (row : IndexedMatrix.MemberRow) (member : row ∈ rows) :
    ∃ i h o n, IndexedMatrix.checkMember matrix splits row i h o n = true := by
  induction rows generalizing index ph po pn with
  | nil => simp at member
  | cons head tail ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,ph,po,pn,parts.1⟩
    · exact ih _ _ _ _ parts.2 later

-- Initializers carry actual value types (0..6). The polymorphic unknown tag
-- (7) is permitted in the operand trace, never as a declared signature type.
theorem initializer {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : ReadOnlyMatrix.Entry) (member : source ∈ (IndexedMatrix.table tables indexed 1).entries)
    (active : E values source.active = 1) :
    ∃ tag : Fin 7, ∃ cursor : Fin (2^32), E values source.value = ((tag.val+8*cursor.val : Nat) : F) := by
  have banks := IndexedLengths.checked_banks (F := F) matrix body tables splits declaration indexed accepted
  change source ∈ (IndexedLengths.banks tables indexed).members.entries at member
  rw [banks.memberEntries] at member
  obtain ⟨row,rm,same⟩ := List.mem_map.mp member
  rw [← same] at active ⊢
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have all : IndexedMatrix.checkMembers matrix splits indexed.members 0 z z z = true := by grind only
  obtain ⟨i,h,o,n,rc⟩ := member_checked matrix splits indexed.members 0 z z z all row rm
  obtain ⟨decoded,bounds,image,_,_⟩ := IndexedCell.decode matrix splits splitChecks row i h o n rc values one satisfied active
  exact ⟨decoded.tag,⟨decoded.cursor,bounds.2.2.1⟩,image.2.2.2.2.2.2.2.1⟩

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (r : StructuredMatrix.Record)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (merged : BranchMergeCheck.checkStage matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < (StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) = true)
    (actual : Fin 8) (image : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 4) = (actual.val : F))
    (active : E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)) = 1) :
    ∃ tag : Fin 7, E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).payload.low = (tag.val : F) ∧
      CallEvents.InputOk tag.val actual.val := by
  let row := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
  have faces := BranchTypeRowImages.interface matrix row checked values
  have ma : E values (BranchMergeCheck.record r i 2).branch.active = 1 := faces.memberActive.trans active
  obtain ⟨source,sm,sa,_,sv⟩ := BranchLookupSound.origin matrix tables indexed r lookupChecked merged values one satisfied i 2 ib (by decide) ma
  obtain ⟨tag,cursor,vi⟩ := initializer matrix body tables splits declaration indexed accepted values one satisfied source sm sa
  obtain ⟨expected,next,ei,_,payload⟩ := BranchTypeRowImages.payload matrix row checked values one satisfied
  have equal : tag.val+8*cursor.val = expected.val+8*next.val := by
    apply DeclarationLocations.natural_equal (F := F) _ _
      (by have := tag.isLt; have := cursor.isLt; omega)
      (by have := expected.isLt; have := next.isLt; omega)
    exact vi.symm.trans (sv.trans payload)
  have same : expected.val = tag.val := by have := expected.isLt; have := tag.isLt; omega
  obtain ⟨guardTag,gi,_,guard⟩ := BranchTypeScalar.type_guards matrix row checked values one satisfied actual image
  have guardSame : guardTag.val = expected.val := DeclarationLocations.natural_equal (F := F) _ _
    (by have := guardTag.isLt; omega) (by have := expected.isLt; omega) (gi.symm.trans ei)
  refine ⟨tag,?_,?_⟩
  · simpa only [same] using ei
  · simpa only [guardSame,same] using guard active

def Inputs {F : Type} [Field F] (values : Nat → F) (splits : Splits)
    (r : StructuredMatrix.Record) (rows : List OperandEvents.Row) : Prop :=
  ∀ i, i < rows.length →
    let row := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
    E values (BranchTypeRowCheck.argument row) = 1 →
    ∃ tag : Fin 7, E values row.payload.low = (tag.val : F) ∧
      CallEvents.InputOk tag.val (rows.getD i default).valueType.val

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Inputs values splits r rows := by
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  intro i ib
  dsimp only
  intro active
  have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  exact selected matrix body tables splits declaration indexed accepted r lookupChecked parts.1.2 values one satisfied
    i (by omega) row.1 (rows.getD i default).valueType row.2.2.1 active

#print axioms member_checked
#print axioms initializer
#print axioms selected
#print axioms trace
end ZkBuild.BranchMemberTag
