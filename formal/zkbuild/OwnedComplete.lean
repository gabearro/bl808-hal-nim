import OwnedMembership
set_option autoImplicit false
namespace ZkBuild.OwnedComplete
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules OwnedDecode ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def keys (ds : List ChildValue) := DeclarationCompleteness.keys (ds.map OwnedOrder.entry)

theorem parent_sum {F : Type} [Field F] (values : Nat → F) (ps : List Parent) (ds : List ParentValue)
    (images : Related (ParentImage values) ps ds) : E values (ps.flatMap (fun p => pget p 1)) = (countSum ds : F) := by
  induction images with
  | nil => simp [countSum,E,evalLinear,CircuitShape.interpretLinear,R1CS.eval]
  | @cons p d ps ds image images ih =>
    have cat := eval_append values (pget p 1) (ps.flatMap (fun p => pget p 1))
    change E values (pget p 1++ps.flatMap (fun p => pget p 1)) = E values (pget p 1)+E values (ps.flatMap (fun p => pget p 1)) at cat
    simp only [List.flatMap_cons,countSum,Semiring.natCast_add]
    rw [cat,image.2.1,ih]

theorem child_sum {F : Type} [Field F] (values : Nat → F) (cs : List Child) (ds : List ChildValue)
    (images : Related (ChildImage values) cs ds) : E values (cs.flatMap (fun c => cget c 0)) = (activeCount ds : F) := by
  induction images with
  | nil => simp [activeCount,E,evalLinear,CircuitShape.interpretLinear,R1CS.eval]
  | @cons c d cs ds image images ih =>
    have cat := eval_append values (cget c 0) (cs.flatMap (fun c => cget c 0))
    change E values (cget c 0++cs.flatMap (fun c => cget c 0)) = E values (cget c 0)+E values (cs.flatMap (fun c => cget c 0)) at cat
    simp only [List.flatMap_cons,activeCount,Semiring.natCast_add]
    rw [cat,image.1,ih]

theorem totals {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : OwnedMatrix.Record)
    (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (pi : Related (ParentImage values) r.parents ps) (pb : ∀ p ∈ ps, ParentBound p)
    (cs : List ChildValue) (ci : Related (ChildImage values) r.children cs) : countSum ps = activeCount cs := by
  have checks := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at checks
  have links : OwnedMatrix.links tables r := _root_.of_decide_eq_true (by grind only)
  have lengths : r.parents.length < 2^32 ∧ r.children.length < 2^32 := by unfold OwnedMatrix.links at links; grind only
  have close : MemoryEvidence.checkSpan matrix r.closeStart r.closeEnd [eqGate (OwnedMatrix.total r) (seen r)] = true := by grind only
  have eq := equality_sound values oneValue (OwnedMatrix.total r) (seen r) (MemoryEvidence.span_sound matrix _ _ _ close values satisfied _ (by simp))
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have pcat := eval_append values z (r.parents.flatMap (fun p => pget p 1))
  change E values (OwnedMatrix.total r) = E values z+E values (r.parents.flatMap (fun p => pget p 1)) at pcat
  have ccat := eval_append values z (r.children.flatMap (fun c => cget c 0))
  change E values (seen r) = E values z+E values (r.children.flatMap (fun c => cget c 0)) at ccat
  rw [pcat,ccat,zero,parent_sum values _ _ pi,child_sum values _ _ ci] at eq
  have psum := count_bound ps pb
  have plen := related_length _ _ _ pi
  have csum := active_bound cs
  have clen := related_length _ _ _ ci
  apply DeclarationLocations.natural_equal (F := F) (countSum ps) (activeCount cs) (by omega) (by omega)
  grind

theorem entry_key (d : ChildValue) (bound : ChildBound d) : DeclarationCompleteness.key (OwnedOrder.entry d) = (d.owner,d.ordinal) := by
  have shape : d.owner*2^32+d.ordinal = d.ordinal+2^32*d.owner := by omega
  simp only [DeclarationCompleteness.key,OwnedOrder.entry,shape]
  simp [Nat.add_mul_div_left,Nat.div_eq_of_lt bound.2.1,Nat.add_mod,Nat.mod_eq_of_lt bound.2.1]

theorem keys_length (ds : List ChildValue) : (keys ds).length = activeCount ds := by
  rw [keys,DeclarationCompleteness.keys_length]
  induction ds with
  | nil => rfl
  | cons d ds ih => simp [DeclarationCounts.vectorActive,OwnedOrder.entry,activeCount,ih]

theorem count_sum (ps : List ParentValue) : (ps.map ParentValue.count).sum = countSum ps := by
  induction ps with
  | nil => rfl
  | cons p ps ih => simp [countSum,ih]

theorem keys_bounded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (pi : Related (ParentImage values) r.parents ps) (pb : ∀ p ∈ ps, ParentBound p)
    (cs : List ChildValue) (ci : Related (ChildImage values) r.children cs) (cb : ∀ c ∈ cs, ChildBound c) :
    keys cs ⊆ BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) := by
  intro k member
  obtain ⟨entry,em,ea,ek⟩ := (DeclarationCompleteness.keys_member (cs.map OwnedOrder.entry) k).mp member
  obtain ⟨d,dm,same⟩ := List.mem_map.mp em
  subst entry
  have da : d.active = true := ea
  obtain ⟨row,rm,image⟩ := BinaryReadMemory.right_member _ _ _ ci d dm
  obtain ⟨ib,_,ordinal,_,_⟩ := OwnedMembership.child_parent matrix tables tableChecks splits r checked values oneValue satisfied ps pi pb row rm d image (cb d dm) da
  have arity : (ps.map ParentValue.count).getD d.owner 0 = (ps.getD d.owner default).count := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some]
  have found := DeclarationCompleteness.vector_keys_at (ps.map ParentValue.count) 0 d.owner d.ordinal (by simpa using ib) (by rw [arity]; exact ordinal)
  have pair := entry_key d (cb d dm)
  rw [pair] at ek
  rw [← ek]
  simpa using found

/-- Complete coverage is obtained from exact counts and strictly ordered keys;
    no child coverage list or host-decoder assertion is assumed. -/
theorem checked_complete {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ps : List ParentValue, ∃ cs : List ChildValue,
      Related (ParentImage values) r.parents ps ∧ Related (ChildImage values) r.children cs ∧
      (∀ p ∈ ps, ParentBound p) ∧ (∀ c ∈ cs, ChildBound c) ∧ (∀ p ∈ ps, p.active = false → p.count = 0) ∧
      countSum ps = activeCount cs ∧ (keys cs).Nodup ∧
      keys cs ⊆ BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ∧
      BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ⊆ keys cs := by
  have checks := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at checks
  have pc : checkParents matrix r.parents o = true := by grind only
  have cc : checkChildren matrix splits r.children none = true := by grind only
  obtain ⟨ps,pi,pb,inactive⟩ := OwnedDecode.parents matrix r.parents o pc values oneValue satisfied
  obtain ⟨cs,ci,cb,unique⟩ := OwnedOrder.checked_order matrix splits r.children cc values oneValue satisfied
  have total := totals matrix tables splits r checked values oneValue satisfied ps pi pb cs ci
  have ku := DeclarationCompleteness.keys_unique (cs.map OwnedOrder.entry) unique
  have bounded := keys_bounded matrix tables tableChecks splits r checked values oneValue satisfied ps pi pb cs ci cb
  have full := BinaryDeclarations.complete_vectors (ps.map ParentValue.count) 0 (keys cs) ku bounded (by rw [keys_length,count_sum]; exact total.symm)
  exact ⟨ps,cs,pi,ci,pb,cb,inactive,total,ku,bounded,full⟩

#print axioms totals
#print axioms checked_complete
end ZkBuild.OwnedComplete
