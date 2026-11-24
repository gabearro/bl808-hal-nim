import OwnedOrder
set_option autoImplicit false
namespace ZkBuild.OwnedMembership
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem child_member (matrix : Shape) (splits : Splits) (items : List Child) (prior : Option Child)
    (checked : checkChildren matrix splits items prior = true) (target : Child) (member : target ∈ items) :
    ∃ p n, checkChild matrix splits target p n = true := by
  induction items generalizing prior with
  | nil => simp at member
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with same | later
    · subst target; exact ⟨prior,rest.head?,parts.1⟩
    · exact ih (some row) parts.2 later

theorem parent_member (matrix : Shape) (items : List Parent) (previous : Linear)
    (checked : checkParents matrix items previous = true) (target : Parent) (member : target ∈ items) :
    ∃ p, checkParent matrix target p = true := by
  induction items generalizing previous with
  | nil => simp at member
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with same | later
    · subst target; exact ⟨previous,parts.1⟩
    · exact ih (pget row 0) parts.2 later

theorem child_context (matrix : Shape) (splits : Splits) (items : List Child) (prior : Option Child)
    (checked : checkChildren matrix splits items prior = true) (target : Child) (member : target ∈ items) :
    ∃ p n, checkChild matrix splits target p n = true ∧
      ∀ after, n = some after → after ∈ items ∧ ∃ following, checkChild matrix splits after (some target) following = true := by
  induction items generalizing prior with
  | nil => simp at member
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with same | later
    · subst target
      refine ⟨prior,rest.head?,parts.1,?_⟩
      intro after same
      cases rest with
      | nil => simp at same
      | cons next remaining =>
        have eq : next = after := by simpa using same
        subst after
        exact ⟨by simp,remaining.head?,(Bool.and_eq_true_iff.mp parts.2).1⟩
    · obtain ⟨p,n,ck,following⟩ := ih (some row) parts.2 later
      refine ⟨p,n,ck,?_⟩
      intro after same
      obtain ⟨am,other⟩ := following after same
      exact ⟨by simp [am],other⟩

theorem bank (tables : List ReadOnlyMatrix.Record) (r : OwnedMatrix.Record) (checked : links tables r) (span : Bool) :
    OwnedMatrix.table tables r (if span then 1 else 0) ∈ tables ∧
    (OwnedMatrix.table tables r (if span then 1 else 0)).entries = entries r.parents span ∧
    (OwnedMatrix.table tables r (if span then 1 else 0)).queries = r.children.map (if span then Child.spanQuery else Child.countQuery) := by
  have len : r.tables.length = 2 := by unfold links at checked; grind only
  have indices : ∀ i ∈ r.tables, i < tables.length := by unfold links at checked; grind only
  have inside : (if span then 1 else 0) < r.tables.length := by rw [len]; cases span <;> decide
  have member : r.tables.getD (if span then 1 else 0) 0 ∈ r.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem inside
  have tm : OwnedMatrix.table tables r (if span then 1 else 0) ∈ tables := by
    unfold OwnedMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (indices _ member)
  refine ⟨tm,?_⟩
  cases span <;> unfold links at checked <;> simp only [Bool.false_eq_true,ite_false,ite_true] <;> grind only

theorem parent_value {F : Type} [Field F] (values : Nat → F) (r : Parent) (d : ParentValue)
    (image : ParentImage values r d) (index : Nat) (span : Bool) :
    E values (parentEntry r index span).value = ((if span then d.start+2^32*d.finish else d.count : Nat) : F) := by
  cases span with
  | false => exact image.2.1
  | true =>
    have add := eval_append values (pget r 2) (scale (pget r 3) (Int.ofNat (2^32)))
    have scaled := eval_scale values (pget r 3) (Int.ofNat (2^32))
    change E values (pget r 2++scale (pget r 3) (Int.ofNat (2^32))) = E values (pget r 2)+E values (scale (pget r 3) (Int.ofNat (2^32))) at add
    change E values (scale (pget r 3) (Int.ofNat (2^32))) = (Int.ofNat (2^32) : F)*E values (pget r 3) at scaled
    have cast : (Int.ofNat (2^32) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast (2^32)
    change E values (pget r 2++scale (pget r 3) (Int.ofNat (2^32))) = ((d.start+2^32*d.finish : Nat) : F)
    rw [add,scaled,cast,image.2.2.1,image.2.2.2,Semiring.natCast_add,Semiring.natCast_mul]

theorem lookup_parent {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (table : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix table = true)
    (parents : List Parent) (ps : List ParentValue) (span : Bool)
    (entries : table.entries = OwnedMatrix.entries parents span) (size : parents.length < 2^32)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (images : Related (ParentImage values) parents ps) (bounds : ∀ p ∈ ps, ParentBound p)
    (query : Entry) (member : query ∈ table.queries) (owner : Nat) (ownerBound : owner < 2^32)
    (active : E values query.active = 1) (address : E values query.address = (owner : F)) :
    owner < ps.length ∧ (ps.getD owner default).active = true ∧
      E values query.value = ((if span then (ps.getD owner default).start+2^32*(ps.getD owner default).finish else (ps.getD owner default).count : Nat) : F) := by
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix table checked values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership query member active
  rw [entries] at em
  obtain ⟨i,im,same⟩ := List.mem_map.mp em
  have ib : i < parents.length := List.mem_range.mp im
  subst entry
  have image := DeclarationLocations.related_at (ParentImage values) parents ps images i ib
  have len := related_length _ _ _ images
  have inside : i < ps.length := by omega
  have on : E values (pget (parents.getD i default) 0) = 1 := ea
  have enabled : (ps.getD i default).active = true := by
    have bit := image.1.symm.trans on
    cases flag : (ps.getD i default).active with
    | true => rfl
    | false => simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at bit; exact False.elim (Field.zero_ne_one bit)
  have scaled := eval_scale values (pget (parents.getD i default) 0) (Int.ofNat i)
  change E values (scale (pget (parents.getD i default) 0) (Int.ofNat i)) = (Int.ofNat i : F)*E values (pget (parents.getD i default) 0) at scaled
  have cast : (Int.ofNat i : F) = (i : F) := Ring.intCast_natCast i
  have addressImage : (i : F) = (owner : F) := by
    change E values (scale (pget (parents.getD i default) 0) (Int.ofNat i)) = E values query.address at ek
    rw [scaled,cast,on,Semiring.mul_one,address] at ek
    exact ek
  have sameIndex : i = owner := DeclarationLocations.natural_equal (F := F) i owner (by omega) (by omega) addressImage
  have value := parent_value values (parents.getD i default) (ps.getD i default) image i span
  have output := ev.symm.trans value
  subst i
  exact ⟨inside,enabled,output⟩

theorem child_parent {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (images : Related (ParentImage values) r.parents ps) (bounds : ∀ p ∈ ps, ParentBound p)
    (c : Child) (member : c ∈ r.children) (d : ChildValue) (image : ChildImage values c d) (db : ChildBound d) (active : d.active = true) :
    d.owner < ps.length ∧ (ps.getD d.owner default).active = true ∧ d.ordinal < (ps.getD d.owner default).count ∧
      E values c.countQuery.value = ((ps.getD d.owner default).count : F) ∧
      E values c.spanQuery.value = (((ps.getD d.owner default).start+2^32*(ps.getD d.owner default).finish : Nat) : F) := by
  have ch := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at ch
  have links : OwnedMatrix.links tables r := _root_.of_decide_eq_true (by grind only)
  have size : r.parents.length < 2^32 := by unfold OwnedMatrix.links at links; grind only
  have children : checkChildren matrix splits r.children none = true := by grind only
  obtain ⟨prior,next,cc⟩ := child_member matrix splits r.children none children c member
  have pieces := cc
  simp only [checkChild,Bool.and_eq_true_iff] at pieces
  have shape : childShape splits c prior next := _root_.of_decide_eq_true (by grind only)
  have ca : c.countQuery.active = cget c 0 := by unfold childShape at shape; grind only
  have ck : c.countQuery.address = cget c 1 := by unfold childShape at shape; grind only
  have sa : c.spanQuery.active = cget c 0 := by unfold childShape at shape; grind only
  have sk : c.spanQuery.address = cget c 1 := by unfold childShape at shape; grind only
  have on : E values (cget c 0) = 1 := by simpa [active] using image.1
  have countBank := bank tables r links false
  have spanBank := bank tables r links true
  obtain ⟨ib,pa,ci⟩ := lookup_parent matrix _ (List.all_eq_true.mp tableChecks _ countBank.1) r.parents ps false countBank.2.1 size values oneValue satisfied images bounds
    c.countQuery (by rw [countBank.2.2]; exact List.mem_map.mpr ⟨c,member,rfl⟩) d.owner db.1 (by rw [ca]; exact on) (by rw [ck]; exact image.2.1)
  obtain ⟨_,_,si⟩ := lookup_parent matrix _ (List.all_eq_true.mp tableChecks _ spanBank.1) r.parents ps true spanBank.2.1 size values oneValue satisfied images bounds
    c.spanQuery (by rw [spanBank.2.2]; exact List.mem_map.mpr ⟨c,member,rfl⟩) d.owner db.1 (by rw [sa]; exact on) (by rw [sk]; exact image.2.1)
  have withinCheck : RangeUse.check matrix c.withinRange c.within 32 = true := by grind only
  obtain ⟨delta,deltaBound,deltaImage,_⟩ := TokenInteger.certificate_nat values oneValue c.within (RangeUse.bits c.withinRange) 32
    (RangeUse.checked_certificate matrix _ _ _ withinCheck values oneValue satisfied)
  have all := child_holds matrix splits c prior next cc values satisfied
  have second := child_part values splits c prior next all 2 (by decide)
  have eq := multiply_sound values (cget c 0) (sub (sub c.countQuery.value (cget c 2)) o) c.within (second _ (by simp [childParts]))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [deltaImage,on,eval_sub,eval_sub,ci,image.2.2.1,one,Semiring.one_mul] at eq
  have pm : ps.getD d.owner default ∈ ps := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have pb := bounds _ pm
  have ordinalBound := ReadOnlyMemory.order_gate (F := F) (2^32) d.ordinal (ps.getD d.owner default).count delta db.2.1 pb.1 deltaBound (by decide) eq.symm
  exact ⟨ib,pa,ordinalBound,ci,si⟩

#print axioms lookup_parent
#print axioms child_parent
end ZkBuild.OwnedMembership
