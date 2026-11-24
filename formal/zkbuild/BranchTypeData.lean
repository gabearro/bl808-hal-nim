import BranchLookupSound
import BranchRowImages
set_option autoImplicit false
namespace ZkBuild.BranchTypeData
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Data where
  size : Fin (2^32)
  terminal : Bool
  deriving Inhabited

def Images {F : Type} [Field F] (values : Nat → F) (r : BranchTypeRowCheck.Record) (d : Data) : Prop :=
  E values r.size.value = (d.size.val : F) ∧ E values r.terminal = flag d.terminal

theorem exists_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (r : StructuredMatrix.Record) (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (i : Nat) (ib : i < rows.length) :
    ∃ data : Data, Images values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) data := by
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have sb : i < (StructuredMatrix.stage r 5).rows.length := by have := images.1.trans links.1; omega
  have typed := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  let mark := decide ((rows.getD i default).kind = .labelCheck ∧ ops.getD i 0 = 14)
  have active : E values (BranchMergeCheck.record r i 1).branch.active = flag mark :=
    (BranchTypeRowImages.interface matrix _ typed.1 values).sizeActive.trans typed.2.1.label
  have size : ∃ length : Fin (2^32), E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).size.value = (length.val : F) := by
    cases h : mark with
    | true =>
      have a : E values (BranchMergeCheck.record r i 1).branch.active = 1 := by simpa only [h,flag,ite_true] using active
      obtain ⟨_,v,_,vb,_,vi⟩ := BranchLookupSound.bounded matrix tables indexed r lookupChecked parts.1.2 values one satisfied i 1 sb (by decide) a
      exact ⟨⟨v,by simpa [BranchLookupCheck.valueBits] using vb⟩,vi⟩
    | false =>
      have a : E values (BranchMergeCheck.record r i 1).branch.active = 0 := by simpa only [h,flag,Bool.false_eq_true,ite_false] using active
      have mc := List.all_eq_true.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1.2).2 i (List.mem_range.mpr sb)) 1 (by simp)
      have zero := (BranchMergeSound.meaning matrix _ mc values one satisfied).branchZero a
      refine ⟨⟨0,by decide⟩,?_⟩
      simpa only [BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,
        Semiring.natCast_zero] using zero.2
  obtain ⟨length,li⟩ := size
  have branch := BranchCertificate.row matrix splits tables statics events r parts.1.1.1 values one satisfied rows ops images schedule i ib
  let b := BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i
  have meaning := BranchRowSound.meaning matrix b branch.1 values one satisfied
  have zero := meaning.zero b.payload.high 7 (by simp [BranchRowCheck.zeros])
  have last := meaning.multiply (f b.flags 9) (f b.after 7) 8 (by simp [BranchRowCheck.multiplies])
  let terminal := mark && decide (E values b.payload.high = 0)
  have ti : E values (f b.after 8) = flag terminal := by
    rw [last,branch.2.1.2.2.2,zero]
    change flag (F := F) mark * (if E values b.payload.high = 0 then 1 else 0) = flag terminal
    cases h : mark <;> by_cases z : E values b.payload.high = 0 <;> simp [terminal,h,z,flag] <;> grind only
  have out := (BranchRowImages.outputs matrix b branch.1 values).2
  have same := BranchTypeCertificate.terminal events r parts.2 values i sb
  exact ⟨⟨length,terminal⟩,li,same.trans (out.trans ti)⟩

#print axioms exists_image
end ZkBuild.BranchTypeData
