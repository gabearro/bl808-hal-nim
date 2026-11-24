import BranchTypeScalar
set_option autoImplicit false
namespace ZkBuild.BranchTypeScratch
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix BranchTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem clock_image {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) : E values r.scratch.clock = (r.index : F) := by
  rw [(BranchTypeRowImages.interface matrix r checked values).scratchClock]
  simp only [n,eval_constant values one]
  exact Ring.intCast_natCast _

theorem stored {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4) = (actual.val : F))
    (argument : E values (BranchTypeRowCheck.argument r) = 1) (push : E values (f r.after 34) = 0) :
    MemoryPacking.Represents values r.scratch ⟨true,true,r.index,actual.val,r.index⟩ := by
  have faces := BranchTypeRowImages.interface matrix r checked values
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have address := m.multiply (f r.after 34) (f r.after 29++f r.after 44) 46 (by simp [multiplies])
  have value := m.multiply (BranchTypeRowCheck.argument r++f r.after 34) (f r.row 4) 47 (by simp [multiplies])
  simp only [eval_append,argument,push,image] at address value
  unfold MemoryPacking.Represents
  simp only [Bool.toNat_true,Semiring.natCast_one]
  refine ⟨?_,faces.scratchWrite.trans argument,?_,?_,clock_image matrix r checked values one⟩
  · rw [faces.scratchActive]
    change evalLinear values (_ ++ _) = _
    rw [eval_append]
    change E values (BranchTypeRowCheck.argument r)+E values (f r.after 34) = _
    rw [argument,push]; grind only
  · rw [faces.scratchAddress]
    simp only [E,eval_append,eval_scale]
    change (Int.ofNat r.index : F)*E values (BranchTypeRowCheck.argument r)+E values (f r.after 46) = _
    rw [argument,address,show ((Int.ofNat r.index : Int) : F) = (r.index : F) from Ring.intCast_natCast r.index]
    grind only
  · rw [faces.scratchValue,value]; grind only

theorem loaded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4) = (actual.val : F))
    (start length pushed : Fin (2^32)) (si : E values (f r.after 29) = (start.val : F))
    (li : E values (f r.after 26) = (length.val : F)) (pi : E values (f r.after 28) = (pushed.val : F))
    (argument : E values (BranchTypeRowCheck.argument r) = 0) (push : E values (f r.after 34) = 1) :
    pushed.val < length.val ∧
    MemoryPacking.Represents values r.scratch ⟨true,false,start.val+(length.val-1-pushed.val),actual.val,r.index⟩ := by
  have faces := BranchTypeRowImages.interface matrix r checked values
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have ordinal := BranchTypeScalar.restore_ordinal matrix r checked values one satisfied length pushed li pi push
  have address := m.multiply (f r.after 34) (f r.after 29++f r.after 44) 46 (by simp [multiplies])
  have value := m.multiply (BranchTypeRowCheck.argument r++f r.after 34) (f r.row 4) 47 (by simp [multiplies])
  simp only [eval_append,argument,push,image,si,ordinal.2] at address value
  refine ⟨ordinal.1,?_⟩
  unfold MemoryPacking.Represents
  simp only [Bool.toNat_true,Bool.toNat_false,Semiring.natCast_one,Semiring.natCast_zero]
  refine ⟨?_,faces.scratchWrite.trans argument,?_,?_,clock_image matrix r checked values one⟩
  · rw [faces.scratchActive]
    change evalLinear values (_ ++ _) = _
    rw [eval_append]
    change E values (BranchTypeRowCheck.argument r)+E values (f r.after 34) = _
    rw [argument,push]; grind only
  · rw [faces.scratchAddress]
    simp only [E,eval_append,eval_scale]
    change (Int.ofNat r.index : F)*E values (BranchTypeRowCheck.argument r)+E values (f r.after 46) = _
    rw [argument,address]
    simp only [Semiring.natCast_add]
    grind only
  · rw [faces.scratchValue,value]; grind only

theorem consecutive {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (start popped : Fin (2^32)) (si : E values (f r.after 29) = (start.val : F))
    (pi : E values (f r.after 27) = (popped.val : F)) (ib : r.index < 2^32)
    (argument : E values (BranchTypeRowCheck.argument r) = 1) : r.index = start.val+popped.val := by
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have position := m.guard (BranchTypeRowCheck.argument r)
    (sub (sub (n r.index) (f r.after 29)) (f r.after 27)) (by simp [guards])
  simp only [argument,eval_sub,n,eval_constant values one,si,pi,Semiring.one_mul,
    show ((Int.ofNat r.index : Int) : F) = (r.index : F) from Ring.intCast_natCast r.index] at position
  apply DeclarationLocations.natural_equal (F := F) r.index (start.val+popped.val) (by omega)
    (by have := start.isLt; have := popped.isLt; omega)
  simp only [Semiring.natCast_add]
  grind only

#print axioms clock_image
#print axioms stored
#print axioms loaded
#print axioms consecutive
end ZkBuild.BranchTypeScratch
