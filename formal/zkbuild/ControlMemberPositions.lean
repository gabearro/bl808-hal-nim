import ControlMemberRouting
set_option autoImplicit false
namespace ZkBuild.ControlMemberPositions
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def index (reverse : Bool) (length offset : Nat) := if reverse then length-1-offset else offset

/-- A bounded field subtraction cannot stand for a wrapped natural ordinal. -/
theorem ordinal {F : Type} [Field F] [IsCharP F scalarModulus]
    (reverse : Bool) (found : Fin (2^32)) (length offset : Nat)
    (lengthBound : length<2^32) (offsetBound : offset<2^32) (inside : found.val<length)
    (image : (found.val:F)=(if reverse then (length:F)-1-(offset:F) else (offset:F))) :
    offset<length ∧ found.val=index reverse length offset := by
  cases reverse
  case false =>
    have same := DeclarationLocations.natural_equal (F:=F) found.val offset
      (by have := found.isLt; omega) (by omega) image
    exact ⟨by omega,by simpa only [index,Bool.false_eq_true,ite_false] using same⟩
  case true =>
    have sumImage : ((found.val+1+offset:Nat):F)=(length:F) := by
      simp only [Semiring.natCast_add,Semiring.natCast_one]
      simp only [ite_true] at image
      grind only
    have sum := DeclarationLocations.natural_equal (F:=F) (found.val+1+offset) length
      (by have := found.isLt; omega) (by omega) sumImage
    exact ⟨by omega,by simp only [index,ite_true]; omega⟩

def Image {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record)
    (comparison reverse : Bool) (tags : List Nat) (offset : Nat) : Prop :=
  offset<tags.length ∧ tags.getD (index reverse tags.length offset) 0<7 ∧
    E values (ControlMemberLists.packed row comparison).low=(tags.getD (index reverse tags.length offset) 0:F)

/-- The lookup's complete list and ordinal are identified with the routed list,
    rather than assuming that the selected index is in range. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : ControlTypeRowCheck.Record) (comparison reverse : Bool)
    (head found expectedHead : Fin (2^32)) (tags expected : List Nat) (offset : Nat)
    (member : ControlMemberLists.Image values tables indexed row comparison head found tags)
    (expectedRep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) expectedHead.val expected)
    (expectedBound : expected.length<2^32) (offsetBound : offset<2^32)
    (headImage : E values (f row.after (ControlMemberLists.headSlot comparison))=(expectedHead.val:F))
    (ordinalImage : E values (f row.after (ControlMemberLists.ordinalSlot comparison))=
      (if reverse then (expected.length:F)-1-(offset:F) else (offset:F))) :
    Image values row comparison reverse expected offset := by
  obtain ⟨hi,oi,rep,inside,tb,ti⟩ := member
  have same := ControlSignatureLists.identify values _ _ head expectedHead tags expected hi headImage rep expectedRep
  have sameTags := same.2
  subst tags
  have position := ordinal (F:=F) reverse found expected.length offset expectedBound offsetBound inside (oi.symm.trans ordinalImage)
  exact ⟨position.1,by simpa only [position.2] using tb,by simpa only [position.2] using ti⟩

theorem empty_lists {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (row : ControlTypeRowCheck.Record)
    (empty : ControlHeadTrace.after values row=ControlHeadTrace.empty) :
    ControlLengthLists.Image values tables indexed row 0 0 [] [] := by
  simp only [ControlHeadTrace.after,ControlHeadTrace.empty,ControlHeadTrace.Heads.mk.injEq] at empty
  exact ⟨by simpa only [Fin.val_zero,Semiring.natCast_zero] using empty.1,
    by simpa only [Fin.val_zero,Semiring.natCast_zero] using empty.2.1,
    by simpa only [List.length_nil,Semiring.natCast_zero] using empty.2.2.1,
    by simpa only [List.length_nil,Semiring.natCast_zero] using empty.2.2.2,
    by decide,by decide,.nil,.nil⟩

#print axioms ordinal
#print axioms selected
#print axioms empty_lists
end ZkBuild.ControlMemberPositions
