import OwnedDecode
set_option autoImplicit false
namespace ZkBuild.OwnedOrder
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def entry (d : ChildValue) : MemoryTrace.Entry := ⟨d.active,false,d.owner*2^32+d.ordinal,0,0⟩

theorem key_bound (d : ChildValue) (bounded : ChildBound d) : (entry d).address < 2^64 := by
  simp only [entry]
  have ob := bounded.1
  have ib := bounded.2.1
  omega

theorem key_image {F : Type} [Field F] (values : Nat → F) (r : Child) (d : ChildValue) (image : ChildImage values r d) :
    E values (OwnedMatrix.key r) = ((entry d).address : F) := by
  have add := eval_append values (scale (cget r 1) (Int.ofNat (2^32))) (cget r 2)
  have scale := eval_scale values (cget r 1) (Int.ofNat (2^32))
  change E values (OwnedMatrix.key r) = E values (CircuitShape.scale (cget r 1) (Int.ofNat (2^32)))+E values (cget r 2) at add
  change E values (CircuitShape.scale (cget r 1) (Int.ofNat (2^32))) = (Int.ofNat (2^32) : F)*E values (cget r 1) at scale
  have cast : (Int.ofNat (2^32) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast (2^32)
  rw [add,scale,cast,image.2.1,image.2.2.1]
  simp only [entry,Semiring.natCast_add,Semiring.natCast_mul]
  grind

theorem step_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r prior : Child) (next : Option Child)
    (checked : checkChild matrix splits r (some prior) next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (p d : ChildValue) (priorImage : ChildImage values prior p) (image : ChildImage values r d)
    (pb : ChildBound p) (db : ChildBound d) :
    d.active = true → p.active = true ∧ (entry p).address < (entry d).address := by
  intro enabled
  have chk := checked
  simp only [checkChild,Bool.and_eq_true_iff] at chk
  have orderCheck : RangeUse.check matrix r.orderRange r.order 64 = true := by grind only
  obtain ⟨delta,deltaBound,deltaImage,_⟩ := TokenInteger.certificate_nat values oneValue r.order (RangeUse.bits r.orderRange) 64
    (RangeUse.checked_certificate matrix _ _ _ orderCheck values oneValue satisfied)
  have all := child_holds matrix splits r (some prior) next checked values satisfied
  have first := child_part values splits r (some prior) next all 0 (by decide)
  have gate := first (DeclarationMatrix.gate (cget r 0) (sub o (cget prior 0))) (by simp [childParts])
  change E values (cget r 0)*E values (sub o (cget prior 0)) = E values z at gate
  have active : E values (cget r 0) = 1 := by simpa [enabled] using image.1
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [active,eval_sub,one,priorImage.1,zero] at gate
  have priorActive : p.active = true := by
    cases flag : p.active with
    | true => rfl
    | false =>
      simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at gate
      have bad : (0 : F) = 1 := by grind
      exact False.elim (Field.zero_ne_one bad)
  have third := child_part values splits r (some prior) next all 3 (by decide)
  have dg := multiply_sound values (cget r 0) (sub (sub (OwnedMatrix.key r) (OwnedMatrix.key prior)) o) r.order
    (third _ (by simp [childParts,priorGates]))
  rw [deltaImage,active,eval_sub,eval_sub,key_image values r d image,key_image values prior p priorImage,one,Semiring.one_mul] at dg
  exact ⟨priorActive,ReadOnlyMemory.order_gate (F := F) (2^64) (entry p).address (entry d).address delta
    (key_bound p pb) (key_bound d db) deltaBound (by decide) dg.symm⟩

theorem tail_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (items : List Child) (prior : Child)
    (checked : checkChildren matrix splits items (some prior) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (p : ChildValue) (priorImage : ChildImage values prior p) (pb : ChildBound p) :
    ∃ ds : List ChildValue, Related (ChildImage values) items ds ∧ (∀ d ∈ ds, ChildBound d) ∧
      ReadOnlyMemory.InitializerOrder (some (entry p)) (ds.map entry) := by
  induction items generalizing prior p with
  | nil => exact ⟨[],.nil,by simp,True.intro⟩
  | cons r rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,bound⟩ := child_decode matrix splits r (some prior) rest.head? parts.1 values oneValue satisfied
    obtain ⟨ds,images,bounds,order⟩ := ih r parts.2 d image bound
    have step := step_order matrix splits r prior rest.head? parts.1 values oneValue satisfied p d priorImage image pb bound
    refine ⟨d::ds,.cons image images,?_,?_⟩
    · intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact bound; exact bounds x later
    · change (∀ before, some (entry p) = some before → (entry d).active = true → before.active = true ∧ before.address < (entry d).address) ∧ _
      refine ⟨?_,order⟩
      intro before same active
      cases same
      exact step active

theorem checked_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (items : List Child)
    (checked : checkChildren matrix splits items none = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ds : List ChildValue, Related (ChildImage values) items ds ∧ (∀ d ∈ ds, ChildBound d) ∧
      ReadOnlyMemory.Unique (ds.map entry) := by
  cases items with
  | nil => exact ⟨[],.nil,by simp,List.Pairwise.nil⟩
  | cons r rest =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,bound⟩ := child_decode matrix splits r none rest.head? parts.1 values oneValue satisfied
    obtain ⟨ds,images,bounds,order⟩ := tail_order matrix splits rest r parts.2 values oneValue satisfied d image bound
    have fullOrder : ReadOnlyMemory.InitializerOrder none ((d::ds).map entry) := by
      refine ⟨?_,order⟩
      intro before same
      cases same
    refine ⟨d::ds,.cons image images,?_,ReadOnlyMemory.strict_unique _ (ReadOnlyMemory.ordered_initializers _ _ fullOrder)⟩
    intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact bound; exact bounds x later

#print axioms step_order
#print axioms checked_order
end ZkBuild.OwnedOrder
