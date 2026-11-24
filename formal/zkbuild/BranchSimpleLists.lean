import BranchSimpleHeads
import BranchLookupSound
import IndexedSingletonList
set_option autoImplicit false
namespace ZkBuild.BranchSimpleLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def types (token : Nat) : List Nat := if token%4=1 ∨ token/4%4=2 then [] else [token/16]

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : BranchLookupCheck.check matrix tables indexed r=true)
    (merged : BranchMergeCheck.checkStage matrix r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36))
    (image : BranchFrameMetadata.Image values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) token.val)
    (label : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)=1)
    (mode : token.val/4%4=2 ∨ token.val/4%4=3) :
    ∃ head : Fin (2^32),
      E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).size.address=(head.val:F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val (types token.val) ∧
      (token.val/4%4=3 → token.val/16<7) := by
  let row := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
  have mc (family : Nat) (fb : family<4) := List.all_eq_true.mp
    (List.all_eq_true.mp (Bool.and_eq_true_iff.mp merged).2 i (List.mem_range.mpr ib)) family (List.mem_range.mpr fb)
  have inactive := BranchSimpleHeads.metadata_inactive matrix row checked values one satisfied token.val image mode
  have zero := (BranchMergeSound.meaning matrix _ (mc 0 (by decide)) values one satisfied).branchZero inactive
  have heads := BranchSimpleHeads.zero_heads matrix row checked values one satisfied zero.2
  have chosen := BranchSimpleHeads.label_head matrix row checked values one satisfied token.val image label heads.1 heads.2
  have single := BranchSimpleHeads.singleton_query matrix row checked values one satisfied token.val image label
  rcases mode with empty | singleton
  · have inactive : E values (BranchMergeCheck.record r i 3).branch.active=0 := by
      have h := single.1
      simp only [empty,show ¬(2:Nat)=3 from by decide,decide_false,flag,Bool.false_eq_true,ite_false] at h
      simpa only [row,BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,Nat.reduceMul] using h
    have zero := (BranchMergeSound.meaning matrix _ (mc 3 (by decide)) values one satisfied).branchZero inactive
    have sz : E values row.singleton.value=0 := by
      simpa only [row,BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,Nat.reduceMul] using zero.2
    refine ⟨0,?_,?_,by omega⟩
    · rw [sz] at chosen
      simpa only [ite_self,Fin.val_zero,Semiring.natCast_zero] using chosen
    · simpa only [types,empty,or_true,ite_true,Fin.val_zero] using
        (SignatureLists.Represents.nil (table:=IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes))
  · have active : E values (BranchMergeCheck.record r i 3).branch.active=1 := by
      have h := single.1
      simp only [singleton,decide_true,flag,ite_true] at h
      simpa only [row,BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,Nat.reduceMul] using h
    obtain ⟨entry,member,_,key,value⟩ := BranchLookupSound.origin matrix tables indexed r lookups merged values one satisfied i 3 ib (by decide) active
    obtain ⟨tag,head,ti,hi,rep⟩ := IndexedSingletonList.initializer matrix body tables splits declaration indexed accepted values one satisfied entry member
    have sk : E values (BranchMergeCheck.record r i 3).branch.address=((token.val/16:Nat):F) := by
      simpa only [singleton,ite_true,row,BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,Nat.reduceMul] using single.2
    have same := DeclarationLocations.natural_equal (F:=F) tag.val (token.val/16)
      (by have := tag.isLt; omega) (by have := token.isLt; omega) (ti.symm.trans (key.trans sk))
    have vi : E values row.singleton.value=(head.val:F) := by
      simpa only [row,BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,Nat.reduceMul] using value.symm.trans hi
    have tagBound : token.val/16<7 := by have := tag.isLt; omega
    by_cases loop : token.val%4=1
    · refine ⟨0,?_,?_,fun _ => tagBound⟩
      · simpa only [loop,ite_true,Fin.val_zero,Semiring.natCast_zero] using chosen
      · simpa only [types,loop,true_or,ite_true,Fin.val_zero] using
          (SignatureLists.Represents.nil (table:=IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes))
    · refine ⟨head,?_,?_,fun _ => tagBound⟩
      · simpa only [loop,ite_false,vi] using chosen
      · simpa only [types,loop,singleton,show ¬(3:Nat)=2 from by decide,false_or,ite_false,same] using rep

#print axioms selected
end ZkBuild.BranchSimpleLists
