import OwnedRules
set_option autoImplicit false
namespace ZkBuild.OwnedDecode
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem inactive_field {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (active value : Linear) (disabled : E values active = 0) (gate : Holds values (DeclarationMatrix.gate (sub o active) value)) :
    E values value = 0 := by
  change E values (sub o active)*E values value = E values z at gate
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [eval_sub,one,disabled,zero] at gate
  grind

theorem parent_inactive {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Parent) (previous : Linear) (checked : checkParent matrix r previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ParentValue) (image : ParentImage values r d) (bound : ParentBound d) (inactive : d.active = false) : d.count = 0 := by
  have all := OwnedRules.parent_holds matrix r previous checked values satisfied
  have ranges := OwnedRules.parent_part values r previous all 1 (by decide)
  change AllHold values ((List.range 3).flatMap fun i => RangeUse.gates (r.ranges.getD i default)++[gate (sub o (pget r 0)) (pget r (i+1))]) at ranges
  have disabled : E values (pget r 0) = 0 := by simpa [inactive] using image.1
  have zero := inactive_field values oneValue (pget r 0) (pget r 1) disabled (ranges _ (List.mem_flatMap.mpr ⟨0,by simp,List.mem_append_right _ (by simp)⟩))
  exact DeclarationLocations.natural_equal (F := F) d.count 0 (by have b := bound.1; omega) (by decide) (by simpa using image.2.1.symm.trans zero)

theorem parent_empty {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Parent) (previous : Linear) (checked : checkParent matrix r previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ParentValue) (image : ParentImage values r d) (bound : ParentBound d) (empty : d.count = 0) : d.start = d.finish := by
  have all := OwnedRules.parent_holds matrix r previous checked values satisfied
  have last := OwnedRules.parent_part values r previous all 2 (by decide)
  change AllHold values (zeroGates (pget r 1) (wire r.zeroStart) (wire (r.zeroStart+1))++[gate (wire r.zeroStart) (sub (pget r 3) (pget r 2))]) at last
  have z := zero_sound values oneValue (pget r 1) (wire r.zeroStart) (wire (r.zeroStart+1)) (by intro g gm; exact last g (List.mem_append_left _ gm))
  have ci : E values (pget r 1) = 0 := by simpa [empty] using image.2.1
  have zi : E values (wire r.zeroStart) = 1 := by rw [z]; simp [ci]
  have close := last (gate (wire r.zeroStart) (sub (pget r 3) (pget r 2))) (List.mem_append_right _ (by simp))
  change E values (wire r.zeroStart)*E values (sub (pget r 3) (pget r 2)) = E values (DeclarationMatrix.z) at close
  have zero : E values (DeclarationMatrix.z) = 0 := by simp [DeclarationMatrix.z,eval_constant values oneValue]
  rw [zi,eval_sub,image.2.2.2,image.2.2.1,zero] at close
  apply DeclarationLocations.natural_equal (F := F) d.start d.finish (by have b := bound.2.1; omega) (by have b := bound.2.2; omega)
  grind

theorem parents {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (items : List Parent) (previous : Linear) (checked : checkParents matrix items previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ds : List ParentValue, Related (ParentImage values) items ds ∧ (∀ d ∈ ds, ParentBound d) ∧ (∀ d ∈ ds, d.active = false → d.count = 0) := by
  induction items generalizing previous with
  | nil => exact ⟨[],.nil,by simp,by simp⟩
  | cons p rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,bound⟩ := OwnedRules.parent_decode matrix p previous parts.1 values oneValue satisfied
    obtain ⟨ds,images,bounds,inactive⟩ := ih (pget p 0) parts.2
    refine ⟨d::ds,.cons image images,?_,?_⟩
    · intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact bound; exact bounds x later
    · intro x xm; rcases List.mem_cons.mp xm with same | later
      · subst x; exact parent_inactive matrix p previous parts.1 values oneValue satisfied d image bound
      · exact inactive x later

theorem children {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (items : List Child) (prior : Option Child) (checked : checkChildren matrix splits items prior = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ds : List ChildValue, Related (ChildImage values) items ds ∧ (∀ d ∈ ds, ChildBound d) := by
  induction items generalizing prior with
  | nil => exact ⟨[],.nil,by simp⟩
  | cons c rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,bound⟩ := OwnedRules.child_decode matrix splits c prior rest.head? parts.1 values oneValue satisfied
    obtain ⟨ds,images,bounds⟩ := ih (some c) parts.2
    refine ⟨d::ds,.cons image images,?_⟩
    intro x xm; rcases List.mem_cons.mp xm with rfl | later; exact bound; exact bounds x later

def countSum : List ParentValue → Nat | [] => 0 | p::ps => p.count+countSum ps
def activeCount : List ChildValue → Nat | [] => 0 | c::cs => c.active.toNat+activeCount cs

theorem count_bound (ps : List ParentValue) (bounds : ∀ p ∈ ps, ParentBound p) : countSum ps ≤ ps.length*2^32 := by
  induction ps with
  | nil => simp [countSum]
  | cons p ps ih =>
    have b := (bounds p (by simp)).1
    have rest := ih (by intro x xm; exact bounds x (by simp [xm]))
    simp only [countSum,List.length_cons,Nat.add_mul,Nat.one_mul]
    omega

theorem active_bound (cs : List ChildValue) : activeCount cs ≤ cs.length := by
  induction cs with
  | nil => exact Nat.le_refl 0
  | cons c cs ih =>
    have bit : c.active.toNat ≤ 1 := by cases c.active <;> decide
    simp only [activeCount,List.length_cons]
    omega

#print axioms parent_inactive
#print axioms parent_empty
#print axioms parents
#print axioms children
end ZkBuild.OwnedDecode
