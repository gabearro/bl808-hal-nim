import ControlFrameMetadata
import ControlLookupSound
import IndexedSingletonList
set_option autoImplicit false
namespace ZkBuild.ControlSimpleLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def types (token : Nat) : List Nat := if token/4%4=2 then [] else [token/16]

theorem empty_index {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36)) (image : ControlFrameMetadata.Image values row token.val)
    (lookup : E values (ControlTypeRowCheck.lookup row)=1) (empty : token.val/4%4=2) : token.val/16=0 := by
  have facts := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have mask := facts.multiply (ControlTypeRowCheck.lookup row) (f row.frame 6) 5 (by simp [ControlTypeRowCheck.multiplies])
  have guard := facts.guard (f row.after 5) (f row.frame 3) (by simp [ControlTypeRowCheck.guards])
  simp only [lookup,image.empty,empty,decide_true,flag,ite_true,Semiring.one_mul] at mask
  simp only [mask,image.index,Semiring.one_mul] at guard
  exact DeclarationLocations.natural_equal (F:=F) (token.val/16) 0 (by have := token.isLt; omega) (by decide)
    (by simpa only [Semiring.natCast_zero] using guard)

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36))
    (image : ControlFrameMetadata.Image values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) token.val)
    (lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (mode : token.val/4%4=2 ∨ token.val/4%4=3) :
    ∃ rh : Fin (2^32), E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 7)=0 ∧
      E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 8)=(rh.val:F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) rh.val (types token.val) ∧
      (token.val/4%4=2 → token.val/16=0) ∧ (token.val/4%4=3 → token.val/16<7) := by
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have single := ControlFrameMetadata.simple matrix row checked values one satisfied token.val image lookup
  have zero := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 0 ib (by decide) (single.2.2 mode)).2
  have heads := ControlFrameMetadata.zero_heads matrix row checked values one satisfied zero
  have chosen := ControlFrameMetadata.reset_heads matrix row checked values one satisfied token.val image reset
  have pi : E values (f row.after 7)=0 := by
    rw [chosen.1,heads.1]; simp only [ite_self]
  have ri : E values (f row.after 8)=E values row.singleton.value := by
    rw [chosen.2,heads.2]; exact AddCommMonoid.zero_add _
  have empty := empty_index matrix row checked values one satisfied token image lookup
  rcases mode with nilMode | singleton
  · have inactive : E values (ControlLookupCheck.control r i 3).active=0 := by
      have h := single.1
      simpa only [row,ControlTypeRowCheck.record,ControlLookupCheck.control,BranchMergeCheck.queryAt,Nat.reduceMul,nilMode,show ¬(2:Nat)=3 from by decide,decide_false,flag,Bool.false_eq_true,ite_false] using h
    have zero := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 3 ib (by decide) inactive).2
    have zero : E values row.singleton.value=0 := zero
    refine ⟨0,pi,?_,?_,empty,by omega⟩
    · simpa only [Fin.val_zero,Semiring.natCast_zero] using ri.trans zero
    · simpa only [types,nilMode,ite_true,Fin.val_zero] using
        (SignatureLists.Represents.nil (table:=IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes))
  · have active : E values (ControlLookupCheck.control r i 3).active=1 := by
      have h := single.1
      simpa only [row,ControlTypeRowCheck.record,ControlLookupCheck.control,BranchMergeCheck.queryAt,Nat.reduceMul,singleton,decide_true,flag,ite_true] using h
    obtain ⟨entry,member,_,key,value⟩ := ControlLookupSound.origin matrix tables indexed r lookups values one satisfied i 3 ib (by decide) active
    obtain ⟨tag,head,ti,hi,rep⟩ := IndexedSingletonList.initializer matrix body tables splits declaration indexed accepted values one satisfied entry member
    have sk : E values (ControlLookupCheck.control r i 3).address=((token.val/16:Nat):F) := by
      simpa only [row,ControlTypeRowCheck.record,ControlLookupCheck.control,BranchMergeCheck.queryAt,Nat.reduceMul,singleton,ite_true] using single.2.1
    have same := DeclarationLocations.natural_equal (F:=F) tag.val (token.val/16)
      (by have := tag.isLt; omega) (by have := token.isLt; omega) (ti.symm.trans (key.trans sk))
    have vi : E values row.singleton.value=(head.val:F) := value.symm.trans hi
    refine ⟨head,pi,ri.trans vi,?_,empty,?_⟩
    · simpa only [types,singleton,show ¬(3:Nat)=2 from by decide,ite_false,same] using rep
    · intro _; have := tag.isLt; omega

#print axioms empty_index
#print axioms selected
end ZkBuild.ControlSimpleLists
