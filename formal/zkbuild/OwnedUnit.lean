import OwnedBounds
set_option autoImplicit false
namespace ZkBuild.OwnedUnit
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def UnitWidth {F : Type} [Field F] (values : Nat → F) (items : List Child) : Prop :=
  ∀ c ∈ items, E values (cget c 0) = 1 → E values (cget c 4) = E values (cget c 3)+1

def Previous {F : Type} [Field F] (values : Nat → F) (parents : List ParentValue) : Option Child → Prop
  | none => True
  | some c => ∃ d : ChildValue, ChildImage values c d ∧ ChildBound d ∧
      (d.active = true → d.finish = (parents.getD d.owner default).start+d.ordinal+1)

def Position (parents : List ParentValue) (d : ChildValue) : Prop :=
  d.active = true → d.owner < parents.length ∧
    d.start = (parents.getD d.owner default).start+d.ordinal ∧
    d.finish = (parents.getD d.owner default).start+d.ordinal+1

/-- A consumer proving one-byte children gets exact byte positions, derived
    from the concrete first-child and neighbor-link constraints. -/
theorem positions {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (parentImages : Related (ParentImage values) r.parents ps) (parentBounds : ∀ p ∈ ps, ParentBound p)
    (items : List Child) (ds : List ChildValue) (images : Related (ChildImage values) items ds)
    (bounds : ∀ d ∈ ds, ChildBound d) (members : ∀ c ∈ items, c ∈ r.children)
    (prior : Option Child) (checkItems : checkChildren matrix splits items prior = true)
    (before : Previous values ps prior) (unit : UnitWidth values r.children) :
    ∀ d ∈ ds, Position ps d := by
  induction images generalizing prior with
  | nil => simp
  | @cons child d rest ds image images ih =>
    have checks := Bool.and_eq_true_iff.mp checkItems
    have db := bounds d (by simp)
    have cm := members child (by simp)
    have position : Position ps d := by
      intro active
      obtain ⟨inside,_,low,_⟩ := OwnedBounds.split_bounds matrix tables tableChecks splits splitChecks r checked values oneValue satisfied ps parentImages parentBounds child cm d image db active
      have pm : ps.getD d.owner default ∈ ps := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem inside
      have pb := parentBounds _ pm
      have start : d.start = (ps.getD d.owner default).start+d.ordinal := by
        cases prior with
        | none =>
          have first := (OwnedLinks.absent_flags matrix splits child none rest.head? checks.1 values oneValue).1 rfl
          have base := OwnedLinks.first_child matrix splits child none rest.head? checks.1 values oneValue satisfied d image db active first _ pb.2.1 low
          omega
        | some previous =>
          obtain ⟨p,pi,pb,placed⟩ := before
          by_cases same : d.owner = p.owner
          · have link := OwnedLinks.adjacent matrix splits child previous rest.head? checks.1 values oneValue satisfied d p image pi db pb active same
            have priorActive := (OwnedOrder.step_order matrix splits child previous rest.head? checks.1 values oneValue satisfied p d pi image pb db active).1
            have priorEnd := placed priorActive
            rw [← same] at priorEnd
            omega
          · have first : E values child.same = 0 := by
              simpa [same] using OwnedLinks.same_owner matrix splits child previous rest.head? checks.1 values oneValue satisfied d p image pi db pb active
            have base := OwnedLinks.first_child matrix splits child (some previous) rest.head? checks.1 values oneValue satisfied d image db active first _ (parentBounds _ pm).2.1 low
            omega
      have on : E values (cget child 0) = 1 := by simpa [active] using image.1
      have step := unit child cm on
      rw [image.2.2.2.2,image.2.2.2.1] at step
      have finish : d.finish = d.start+1 := by
        apply DeclarationLocations.natural_equal (F := F) _ _ (by have b := db.2.2.2; omega) (by have b := db.2.2.1; omega)
        simpa only [Semiring.natCast_add,Semiring.natCast_one] using step
      exact ⟨inside,start,by omega⟩
    have nextBefore : Previous values ps (some child) := ⟨d,image,db,fun active => (position active).2.2⟩
    have tail := ih (by intro x xm; exact bounds x (by simp [xm])) (by intro c cm; exact members c (by simp [cm])) (some child) checks.2 nextBefore
    intro x xm
    rcases List.mem_cons.mp xm with same | later
    · subst x; exact position
    · exact tail x later

theorem checked_positions {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (parentImages : Related (ParentImage values) r.parents ps) (parentBounds : ∀ p ∈ ps, ParentBound p)
    (cs : List ChildValue) (images : Related (ChildImage values) r.children cs) (bounds : ∀ c ∈ cs, ChildBound c)
    (unit : UnitWidth values r.children) : ∀ c ∈ cs, Position ps c := by
  have checks := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at checks
  have cc : checkChildren matrix splits r.children none = true := by grind only
  exact positions matrix tables tableChecks splits splitChecks r checked values oneValue satisfied ps parentImages parentBounds r.children cs images bounds (by simp) none cc True.intro unit

/-- Unit-width children cover precisely the parent's declared byte span. -/
theorem checked_parent_spans {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (unit : UnitWidth values r.children) :
    ∃ ps : List ParentValue, Related (ParentImage values) r.parents ps ∧ (∀ p ∈ ps, ParentBound p) ∧
      ∀ i, i < ps.length → (ps.getD i default).finish = (ps.getD i default).start+(ps.getD i default).count := by
  obtain ⟨ps,cs,pi,ci,pb,cb,_,_,_,_,full⟩ := OwnedComplete.checked_complete matrix tables tableChecks splits r checked values oneValue satisfied
  have placed := checked_positions matrix tables tableChecks splits splitChecks r checked values oneValue satisfied ps pi pb cs ci cb unit
  have ck := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at ck
  have parentChecks : checkParents matrix r.parents o = true := by grind only
  have childChecks : checkChildren matrix splits r.children none = true := by grind only
  refine ⟨ps,pi,pb,?_⟩
  intro i ib
  let parent := ps.getD i default
  have pm : parent ∈ ps := by
    change ps.getD i default ∈ ps
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem ib
  have pbound := pb parent pm
  by_cases empty : parent.count = 0
  · have sizes := related_length _ _ _ pi
    have rb : i < r.parents.length := by omega
    have rm : r.parents.getD i default ∈ r.parents := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem rb
    obtain ⟨previous,parentCheck⟩ := OwnedMembership.parent_member matrix r.parents o parentChecks _ rm
    have pimage := DeclarationLocations.related_at (ParentImage values) r.parents ps pi i rb
    have same := OwnedDecode.parent_empty matrix _ previous parentCheck values oneValue satisfied parent pimage pbound empty
    change parent.finish = parent.start+parent.count
    omega
  · have arity : (ps.map ParentValue.count).getD i 0 = parent.count := by
      simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some,parent]
    have desired := DeclarationCompleteness.vector_keys_at (ps.map ParentValue.count) 0 i (parent.count-1) (by simpa using ib) (by rw [arity]; omega)
    have present : (i,parent.count-1) ∈ OwnedComplete.keys cs := full (by simpa using desired)
    obtain ⟨entry,em,ea,ek⟩ := (DeclarationCompleteness.keys_member (cs.map OwnedOrder.entry) (i,parent.count-1)).mp present
    obtain ⟨d,dm,entryEq⟩ := List.mem_map.mp em
    subst entry
    have db := cb d dm
    have da : d.active = true := ea
    have pair := (OwnedComplete.entry_key d db).symm.trans ek
    have owner : d.owner = i := congrArg Prod.fst pair
    have ordinal : d.ordinal = parent.count-1 := congrArg Prod.snd pair
    obtain ⟨child,cm,image⟩ := BinaryReadMemory.right_member _ _ _ ci d dm
    obtain ⟨prior,next,rowCheck,following⟩ := OwnedMembership.child_context matrix splits r.children none childChecks child cm
    have noNext : E values child.continues = 0 := by
      cases next with
      | none => exact (OwnedLinks.absent_flags matrix splits child prior none rowCheck values oneValue).2 rfl
      | some after =>
        obtain ⟨am,afterNext,afterCheck⟩ := following after rfl
        obtain ⟨n,nm,ni⟩ := BinaryReadMemory.left_member _ _ _ ci after am
        have nb := cb n nm
        have flag := OwnedLinks.next_owner matrix splits child after prior rowCheck values oneValue satisfied d n image ni db nb
        by_cases enabled : n.active = true
        · by_cases same : n.owner = d.owner
          · have bound := OwnedMembership.child_parent matrix tables tableChecks splits r checked values oneValue satisfied ps pi pb after am n ni nb enabled
            have limit : n.ordinal < parent.count := by simpa [same,owner,parent] using bound.2.2.1
            have link := OwnedLinks.adjacent matrix splits after child afterNext afterCheck values oneValue satisfied n d ni image nb db enabled same
            omega
          · simpa [enabled,same] using flag
        · simpa [enabled] using flag
    obtain ⟨_,_,_,countImage,_⟩ := OwnedMembership.child_parent matrix tables tableChecks splits r checked values oneValue satisfied ps pi pb child cm d image db da
    obtain ⟨_,_,_,finishImage⟩ := OwnedBounds.split_bounds matrix tables tableChecks splits splitChecks r checked values oneValue satisfied ps pi pb child cm d image db da
    have last := OwnedLinks.last_child matrix splits child prior next rowCheck values oneValue satisfied d image db da noNext parent.count parent.finish pbound.1 pbound.2.2
      (by simpa [owner,parent] using countImage) (by simpa [owner,parent] using finishImage)
    have position := placed d dm da
    have ending : d.finish = parent.start+d.ordinal+1 := by simpa [owner,parent] using position.2.2
    change parent.finish = parent.start+parent.count
    omega

#print axioms positions
#print axioms checked_positions
#print axioms checked_parent_spans
end ZkBuild.OwnedUnit
