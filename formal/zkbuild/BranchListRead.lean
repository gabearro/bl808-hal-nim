import IndexedMemberRead
import BranchMemberTag
set_option autoImplicit false
namespace ZkBuild.BranchListRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

/-- An argument pop checks the exact ordinal of the complete list at its
    held head, including the polymorphic-unknown rule for the actual operand. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : BranchLookupCheck.check matrix tables indexed r=true)
    (merged : BranchMergeCheck.checkStage matrix r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (actualImage : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 4)=(actual.val:F))
    (active : E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1) :
    ∃ head ordinal : Fin (2^32),
      E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 25)=(head.val:F) ∧
      E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 38)=(ordinal.val:F) ∧
      ∃ tags : List Nat,
        SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags ∧
        ordinal.val<tags.length ∧ CallEvents.InputOk (tags.getD ordinal.val 0) actual.val := by
  let row := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
  have banks := IndexedLengths.checked_banks (F:=F) matrix body tables splits declaration indexed accepted
  have interface := BranchTypeRowImages.interface matrix row checked values
  have qs := BranchLookupSound.query_selected matrix tables indexed r lookups merged values one satisfied i 2 ib (by decide) (interface.memberActive.trans active)
  obtain ⟨head,ordinal,_,hi,oi,_⟩ := BranchTypeRowImages.ranges matrix row checked values one satisfied
  have key : E values (BranchLookupCheck.query tables indexed r i 2).address=((ordinal.val+2^32*head.val:Nat):F) := by
    have h := qs.2.2.1.trans interface.memberAddress
    simp only [eval_append,eval_scale,hi,oi,Int.ofNat_eq_natCast,Ring.intCast_natCast] at h
    simp only [Semiring.natCast_add,Semiring.natCast_mul]
    grind only
  obtain ⟨h,o,cursor,tag,tags,ki,vi,rep,inside,atIndex⟩ := IndexedMemberRead.queried matrix body tables splits declaration indexed accepted
    _ banks.membersChecked banks.memberEntries _ qs.1 values one satisfied (qs.2.1.trans (interface.memberActive.trans active))
  have packed := DeclarationLocations.natural_equal (F:=F) (o.val+2^32*h.val) (ordinal.val+2^32*head.val)
    (by have := o.isLt; have := h.isLt; omega) (by have := ordinal.isLt; have := head.isLt; omega) (ki.symm.trans key)
  have parts := DeclarationLocations.packed_unique o.val h.val ordinal.val head.val o.isLt ordinal.isLt packed
  have sameHead : h=head := Fin.ext parts.2
  have sameOrdinal : o=ordinal := Fin.ext parts.1
  subst h; subst o
  obtain ⟨expected,next,ei,_,payload⟩ := BranchTypeRowImages.payload matrix row checked values one satisfied
  have encoded := DeclarationLocations.natural_equal (F:=F) (tag.val+8*cursor.val) (expected.val+8*next.val)
    (by have := tag.isLt; have := cursor.isLt; omega) (by have := expected.isLt; have := next.isLt; omega)
    (vi.symm.trans (qs.2.2.2.trans payload))
  have sameTag : expected.val=tag.val := by have := expected.isLt; have := tag.isLt; omega
  obtain ⟨guardTag,gi,_,guard⟩ := BranchTypeScalar.type_guards matrix row checked values one satisfied actual actualImage
  have guardSame := DeclarationLocations.natural_equal (F:=F) guardTag.val expected.val
    (by have := guardTag.isLt; omega) (by have := expected.isLt; omega) (gi.symm.trans ei)
  have facts := BranchTypeRowSound.meaning matrix row checked values one satisfied
  have held := facts.multiply (BranchTypeRowCheck.argument row) (f row.after 25) 39 (by simp [BranchTypeRowCheck.multiplies])
  have ord := facts.multiply (BranchTypeRowCheck.argument row) (f row.after 38) 40 (by simp [BranchTypeRowCheck.multiplies])
  rw [active,hi] at held
  rw [active,oi] at ord
  exact ⟨head,ordinal,by grind only,by grind only,tags,rep,inside,by simpa only [guardSame,sameTag,atIndex] using guard active⟩

def Inputs {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (rows : List Row) : Prop :=
  ∀ i, i<rows.length →
    E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1 →
    ∃ head ordinal : Fin (2^32), ∃ tags : List Nat,
      E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 25)=(head.val:F) ∧
      E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 38)=(ordinal.val:F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags ∧
      ordinal.val<tags.length ∧ CallEvents.InputOk (tags.getD ordinal.val 0) (rows.getD i default).valueType.val

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookups : BranchLookupCheck.check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Inputs values splits tables indexed r rows := by
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size := images.1.trans links.1
  intro i ib active
  have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  obtain ⟨head,ordinal,hi,oi,tags,rep,inside,ok⟩ := selected matrix body tables splits declaration indexed accepted r lookups parts.1.2
    i (by omega) row.1 values one satisfied (rows.getD i default).valueType row.2.2.1 active
  exact ⟨head,ordinal,tags,hi,oi,rep,inside,ok⟩

#print axioms selected
#print axioms trace
end ZkBuild.BranchListRead
