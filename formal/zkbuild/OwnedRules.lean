import OwnedSound
set_option autoImplicit false
namespace ZkBuild.OwnedRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure ParentValue where
  active : Bool
  count : Nat
  start : Nat
  finish : Nat
  deriving Inhabited
structure ChildValue where
  active : Bool
  owner : Nat
  ordinal : Nat
  start : Nat
  finish : Nat
  deriving Inhabited

def ParentImage {F : Type} [Field F] (values : Nat → F) (r : Parent) (d : ParentValue) : Prop :=
  E values (pget r 0) = (d.active.toNat : F) ∧ E values (pget r 1) = (d.count : F) ∧
  E values (pget r 2) = (d.start : F) ∧ E values (pget r 3) = (d.finish : F)
def ChildImage {F : Type} [Field F] (values : Nat → F) (r : Child) (d : ChildValue) : Prop :=
  E values (cget r 0) = (d.active.toNat : F) ∧ E values (cget r 1) = (d.owner : F) ∧
  E values (cget r 2) = (d.ordinal : F) ∧ E values (cget r 3) = (d.start : F) ∧ E values (cget r 4) = (d.finish : F)
def ParentBound (d : ParentValue) : Prop := d.count < 2^32 ∧ d.start < 2^32 ∧ d.finish < 2^32
def ChildBound (d : ChildValue) : Prop := d.owner < 2^32 ∧ d.ordinal < 2^32 ∧ d.start < 2^32 ∧ d.finish < 2^32

theorem parent_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Parent) (previous : Linear) (checked : checkParent matrix r previous = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (parentGates r previous) :=
  MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem parent_part {F : Type} [Field F] (values : Nat → F) (r : Parent) (previous : Linear)
    (all : AllHold values (parentGates r previous)) (i : Nat) (ib : i < 3) : AllHold values ((parentParts r previous).getD i []) := by
  have bound : i < (parentParts r previous).length := by simpa [parentParts] using ib
  have member : (parentParts r previous).getD i [] ∈ parentParts r previous := by rw [← List.getElem_eq_getD []]; exact List.getElem_mem bound
  intro g gm; exact all g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem child_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child)
    (checked : checkChild matrix splits r prior next = true) (values : Nat → F) (satisfied : Satisfied matrix values) :
    AllHold values (childGates splits r prior next) :=
  MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem child_part {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : Child) (prior next : Option Child)
    (all : AllHold values (childGates splits r prior next)) (i : Nat) (ib : i < 7) : AllHold values ((childParts splits r prior next).getD i []) := by
  have bound : i < (childParts splits r prior next).length := by simpa [childParts] using ib
  have member : (childParts splits r prior next).getD i [] ∈ childParts splits r prior next := by rw [← List.getElem_eq_getD []]; exact List.getElem_mem bound
  intro g gm; exact all g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem boolean_image {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1) (active : Linear)
    (holds : Holds values (boolGate active)) : ∃ flag : Bool, E values active = (flag.toNat : F) := by
  rcases boolean_sound values oneValue active holds with no | yes
  · exact ⟨false,by simpa using no⟩
  · exact ⟨true,by simpa using yes⟩

theorem parent_decode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Parent) (previous : Linear) (checked : checkParent matrix r previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ d : ParentValue, ParentImage values r d ∧ ParentBound d := by
  have checks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have getRange (i : Nat) (ib : i < 3) : RangeUse.check matrix (r.ranges.getD i default) (pget r (i+1)) 32 = true :=
    List.all_eq_true.mp checks i (List.mem_range.mpr ib)
  obtain ⟨count,cb,ci,_⟩ := TokenInteger.certificate_nat values oneValue (pget r 1) (RangeUse.bits (r.ranges.getD 0 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 0 (by decide)) values oneValue satisfied)
  obtain ⟨start,sb,si,_⟩ := TokenInteger.certificate_nat values oneValue (pget r 2) (RangeUse.bits (r.ranges.getD 1 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 1 (by decide)) values oneValue satisfied)
  obtain ⟨finish,fb,fi,_⟩ := TokenInteger.certificate_nat values oneValue (pget r 3) (RangeUse.bits (r.ranges.getD 2 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 2 (by decide)) values oneValue satisfied)
  have all := parent_holds matrix r previous checked values satisfied
  have first := parent_part values r previous all 0 (by decide)
  obtain ⟨active,ai⟩ := boolean_image values oneValue (pget r 0) (first _ (by simp [parentParts]))
  exact ⟨⟨active,count,start,finish⟩,⟨ai,ci,si,fi⟩,cb,sb,fb⟩

theorem child_decode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child)
    (checked : checkChild matrix splits r prior next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ d : ChildValue, ChildImage values r d ∧ ChildBound d := by
  have ch := checked
  simp only [checkChild,Bool.and_eq_true_iff] at ch
  have checks : (List.range 4).all (fun i => RangeUse.check matrix (r.ranges.getD i default) (cget r (i+1)) 32) = true := by grind only
  have getRange (i : Nat) (ib : i < 4) : RangeUse.check matrix (r.ranges.getD i default) (cget r (i+1)) 32 = true :=
    List.all_eq_true.mp checks i (List.mem_range.mpr ib)
  obtain ⟨owner,ob,oi,_⟩ := TokenInteger.certificate_nat values oneValue (cget r 1) (RangeUse.bits (r.ranges.getD 0 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 0 (by decide)) values oneValue satisfied)
  obtain ⟨ordinal,db,di,_⟩ := TokenInteger.certificate_nat values oneValue (cget r 2) (RangeUse.bits (r.ranges.getD 1 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 1 (by decide)) values oneValue satisfied)
  obtain ⟨start,sb,si,_⟩ := TokenInteger.certificate_nat values oneValue (cget r 3) (RangeUse.bits (r.ranges.getD 2 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 2 (by decide)) values oneValue satisfied)
  obtain ⟨finish,fb,fi,_⟩ := TokenInteger.certificate_nat values oneValue (cget r 4) (RangeUse.bits (r.ranges.getD 3 default)) 32
    (RangeUse.checked_certificate matrix _ _ _ (getRange 3 (by decide)) values oneValue satisfied)
  have all := child_holds matrix splits r prior next checked values satisfied
  have first := child_part values splits r prior next all 0 (by decide)
  obtain ⟨active,ai⟩ := boolean_image values oneValue (cget r 0) (first _ (by simp [childParts]))
  exact ⟨⟨active,owner,ordinal,start,finish⟩,⟨ai,oi,di,si,fi⟩,ob,db,sb,fb⟩

#print axioms parent_decode
#print axioms child_decode
end ZkBuild.OwnedRules
