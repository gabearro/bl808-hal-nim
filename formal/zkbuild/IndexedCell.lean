import IndexedSound
import IndexedSignatures

namespace ZkBuild.IndexedCell
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix IndexedMatrix
open DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem metadata (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true) :
    r.addressSplit < splits.length ∧ r.cellSplit < splits.length ∧ r.nodeSplit < splits.length ∧
    splitMatches (address splits r) r.entry.address 32 32 ∧ splitMatches (cell splits r) r.entry.value 3 32 ∧
    splitMatches (node splits r) r.nodeQuery.value 3 32 ∧ r.nodeQuery.active = r.entry.active ∧ r.lengthQuery.active = r.entry.active ∧
    (index = 0 → r.continuing = z ∧ r.continuationZero = 0) :=
  _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1

theorem holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (memberGates splits r index ph po pn) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem part_holds {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : MemberRow)
    (index : Nat) (ph po pn : Linear) (all : AllHold values (memberGates splits r index ph po pn))
    (i : Nat) (bound : i < 11) : AllHold values ((memberParts splits r index ph po pn).getD i []) := by
  have b : i < (memberParts splits r index ph po pn).length := by simpa [memberParts] using bound
  have member : (memberParts splits r index ph po pn).getD i [] ∈ memberParts splits r index ph po pn := by
    rw [← List.getElem_eq_getD []]; exact List.getElem_mem b
  intro g gm; exact all g (List.mem_flatten.mpr ⟨_,member,gm⟩)

structure Decoded where
  head : Nat
  ordinal : Nat
  cursor : Nat
  tag : Fin 7
  next : Nat

def Bounded (d : Decoded) : Prop := d.head < 2^32 ∧ d.ordinal < 2^32 ∧ d.cursor < 2^32 ∧ d.next < 2^32
def Represents {F : Type} [CommRing F] (values : Nat → F) (splits : Splits) (r : MemberRow) (d : Decoded) : Prop :=
  E values (address splits r).high = (d.head : F) ∧ E values (address splits r).low = (d.ordinal : F) ∧
  E values (cell splits r).high = (d.cursor : F) ∧ E values (cell splits r).low = (d.tag.val : F) ∧
  E values (node splits r).high = (d.next : F) ∧ E values (node splits r).low = (d.tag.val : F) ∧
  E values r.entry.address = ((d.ordinal+2^32*d.head : Nat) : F) ∧
  E values r.entry.value = ((d.tag.val+8*d.cursor : Nat) : F) ∧
  E values r.nodeQuery.address = (d.cursor : F) ∧ E values r.nodeQuery.value = ((d.tag.val+8*d.next : Nat) : F) ∧
  E values r.lengthQuery.address = (d.head : F)

theorem decode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : MemberRow) (index : Nat) (ph po pn : Linear) (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (active : E values r.entry.active = 1) :
    ∃ d : Decoded, Bounded d ∧ Represents values splits r d ∧ d.head ≠ 0 ∧ d.cursor ≠ 0 := by
  have shape := metadata matrix splits r index ph po pn checked
  have aMember : address splits r ∈ splits := by rw [address,split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.1
  have cMember : cell splits r ∈ splits := by rw [cell,split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.1
  have nMember : node splits r ∈ splits := by rw [node,split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.1
  obtain ⟨_,ordinal,head,_,ob,hb,_,oi,hi,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ aMember) values oneValue satisfied
  obtain ⟨_,tag,cursor,_,tb,cb,_,ti,ci,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ cMember) values oneValue satisfied
  obtain ⟨_,nodeTag,next,_,ntb,nb,_,nti,ni,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ nMember) values oneValue satisfied
  have as := shape.2.2.2.1
  have cs := shape.2.2.2.2.1
  have ns := shape.2.2.2.2.2.1
  have ordinalBound : ordinal < 2^32 := by simpa [as.2.1] using ob
  have headBound : head < 2^32 := by simpa [as.2.2] using hb
  have tagBound : tag < 8 := by simpa [cs.2.1] using tb
  have cursorBound : cursor < 2^32 := by simpa [cs.2.2] using cb
  have nextBound : next < 2^32 := by simpa [ns.2.2] using nb
  have all := holds matrix splits r index ph po pn checked values satisfied
  have tagGates := part_holds values splits r index ph po pn all 4 (by decide)
  have zi := zero_sound values oneValue (sub (cell splits r).low (n 7)) (wire r.tagZero) (wire (r.tagZero+1))
    (by intro g gm; exact tagGates g (List.mem_append_left _ gm))
  have ze := equality_sound values oneValue (wire r.tagZero) z (tagGates _ (by simp [memberParts]))
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have seven : E values (n 7) = ((7 : Nat) : F) := (eval_constant values oneValue (Int.ofNat 7)).trans (Ring.intCast_natCast 7)
  have tagSmall : tag < 7 := by
    by_cases same : tag = 7
    · have zt : E values (sub (cell splits r).low (n 7)) = 0 := by rw [eval_sub,ti,seven,same]; grind
      rw [zt,ite_eq_left rfl] at zi
      rw [zero] at ze
      exact False.elim (Field.zero_ne_one (ze.symm.trans zi))
    · omega
  have body := part_holds values splits r index ph po pn all 7 (by decide)
  have sameTag := body (gate r.entry.active (sub (cell splits r).low (node splits r).low)) (by simp [memberParts])
  change E values r.entry.active*E values (sub (cell splits r).low (node splits r).low) = E values z at sameTag
  rw [active,eval_sub,ti,nti,zero] at sameTag
  have nodeTagImage : E values (node splits r).low = (tag : F) := by rw [nti]; grind
  have nodeQuery := part_holds values splits r index ph po pn all 5 (by decide)
  have nq := multiply_sound values r.entry.active (cell splits r).high r.nodeQuery.address (nodeQuery _ (by simp [memberParts,queryGate]))
  have lq := multiply_sound values r.entry.active (address splits r).high r.lengthQuery.address (body _ (by simp [memberParts,queryGate]))
  have ai := split_recombine matrix _ (List.all_eq_true.mp splitChecks _ aMember) as.2.1 values oneValue satisfied
  have packed3 (p : PackedFields.Record) (pm : p ∈ splits) (width : p.lowWidth = 3) : E values p.value = E values p.low+((8 : Nat) : F)*E values p.high := by
    obtain ⟨v,lo,high,_,_,_,vi,li,hi,same,_,_⟩ := PackedFields.checked_split matrix p (List.all_eq_true.mp splitChecks p pm) values oneValue satisfied
    rw [vi,li,hi,same,width,Semiring.natCast_add,Semiring.natCast_mul]
  have cp := packed3 _ cMember cs.2.1
  have np := packed3 _ nMember ns.2.1
  have aImage : E values r.entry.address = ((ordinal+2^32*head : Nat) : F) := by
    rw [as.1,oi,hi] at ai
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using ai
  have cImage : E values r.entry.value = ((tag+8*cursor : Nat) : F) := by
    rw [cs.1,ti,ci] at cp
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using cp
  have nImage : E values r.nodeQuery.value = ((tag+8*next : Nat) : F) := by
    rw [ns.1,nodeTagImage,ni] at np
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using np
  have nonzero (term : Linear) (value : Nat) (image : E values term = (value : F)) (start : Nat)
      (zs : AllHold values (zeroGates term (wire start) (wire (start+1))++[gate r.entry.active (wire start)])) : value ≠ 0 := by
    intro isZero
    have indicator := zero_sound values oneValue term (wire start) (wire (start+1)) (by intro g gm; exact zs g (List.mem_append_left _ gm))
    have forced := zs (gate r.entry.active (wire start)) (by simp)
    change E values r.entry.active*E values (wire start) = E values z at forced
    rw [image,isZero,Semiring.natCast_zero,ite_eq_left rfl] at indicator
    rw [active,indicator,zero] at forced
    exact Field.zero_ne_one (by simpa [Semiring.one_mul] using forced.symm)
  refine ⟨⟨head,ordinal,cursor,⟨tag,tagSmall⟩,next⟩,⟨headBound,ordinalBound,cursorBound,nextBound⟩,?_,?_,?_⟩
  · exact ⟨hi,oi,ci,ti,ni,nodeTagImage,aImage,cImage,by simpa [active,ci,Semiring.one_mul] using nq,nImage,by simpa [active,hi,Semiring.one_mul] using lq⟩
  · exact nonzero _ head hi r.headZero (by simpa [memberParts] using part_holds values splits r index ph po pn all 2 (by decide))
  · exact nonzero _ cursor ci r.cursorZero (by simpa [memberParts] using part_holds values splits r index ph po pn all 3 (by decide))

#print axioms decode
end ZkBuild.IndexedCell
