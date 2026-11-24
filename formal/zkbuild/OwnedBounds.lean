import OwnedLinks
set_option autoImplicit false
namespace ZkBuild.OwnedBounds
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem split_bounds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : OwnedMatrix.Record) (checked : OwnedMatrix.check matrix tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ps : List ParentValue) (images : Related (ParentImage values) r.parents ps) (bounds : ∀ p ∈ ps, ParentBound p)
    (c : Child) (member : c ∈ r.children) (d : ChildValue) (image : ChildImage values c d) (db : ChildBound d) (active : d.active = true) :
    d.owner < ps.length ∧ d.ordinal < (ps.getD d.owner default).count ∧
      E values (split splits c.heads).low = ((ps.getD d.owner default).start : F) ∧
      E values (split splits c.heads).high = ((ps.getD d.owner default).finish : F) := by
  obtain ⟨inside,_,ordinal,_,span⟩ := OwnedMembership.child_parent matrix tables tableChecks splits r checked values oneValue satisfied ps images bounds c member d image db active
  have ch := checked
  simp only [OwnedMatrix.check,Bool.and_eq_true_iff] at ch
  have children : checkChildren matrix splits r.children none = true := by grind only
  obtain ⟨prior,next,cc⟩ := OwnedMembership.child_member matrix splits r.children none children c member
  have cs := cc
  simp only [checkChild,Bool.and_eq_true_iff] at cs
  have shape : childShape splits c prior next := _root_.of_decide_eq_true (by grind only)
  have si : c.heads < splits.length := by unfold childShape at shape; grind only
  have fields : splitMatches (split splits c.heads) c.spanQuery.value 32 32 := by unfold childShape at shape; grind only
  have sm : split splits c.heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem si
  obtain ⟨n,low,high,nb,lb,hb,ni,li,hi,packed,_,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ sm) values oneValue satisfied
  have pm : ps.getD d.owner default ∈ ps := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem inside
  have pb := bounds _ pm
  unfold splitMatches at fields
  simp only [fields.2.1,fields.2.2] at nb lb hb packed
  have equal : n = (ps.getD d.owner default).start+2^32*(ps.getD d.owner default).finish :=
    DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have a := pb.2.1; have b := pb.2.2; omega)
      (ni.symm.trans (by rw [fields.1]; exact span))
  have same : low = (ps.getD d.owner default).start ∧ high = (ps.getD d.owner default).finish :=
    DeclarationLocations.packed_unique _ _ _ _ lb pb.2.1 (packed.symm.trans equal)
  exact ⟨inside,ordinal,by simpa [same.1] using li,by simpa [same.2] using hi⟩

#print axioms split_bounds
end ZkBuild.OwnedBounds
