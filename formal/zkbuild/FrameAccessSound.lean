import FrameDescriptor
set_option autoImplicit false
namespace ZkBuild.FrameAccessSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem read_slot {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (count depth : Fin (2^32)) (ci : E values (f r.before 0) = (count.val : F))
    (di : E values (f r.after 15) = (depth.val : F))
    (active : E values (readActive r) = 1) (returns : Bool)
    (ri : E values (f r.after 8) = OperandEvents.flag returns) :
    0 < count.val ∧
    (returns = false → depth.val < count.val) ∧
    E values (f r.after 17) = ((if returns then 0 else count.val-1-depth.val : Nat) : F) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  obtain ⟨slot,sb,si⟩ := FrameRowImages.bounded matrix r checked values one satisfied 2 (by decide)
  change slot < 2^32 at sb
  change E values (f r.after 17) = (slot : F) at si
  have nonempty := facts.guard (readActive r) (sub o (sub o (f r.after 12))) (by simp [guards])
  have empty := facts.zero (f r.before 0) 12 (by simp [zeros])
  have positive : 0 < count.val := by
    by_cases cz : count.val = 0
    · simp only [ci,cz,Semiring.natCast_zero,ite_true] at empty
      simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,active,empty] at nonempty
      exact False.elim (Field.zero_ne_one (α := F) (by grind only))
    · omega
  have selected := facts.select (f r.after 8) z (sub (sub (f r.before 0) o) (f r.after 15)) 16 (by simp [selects])
  have used := facts.multiply (readActive r) (f r.after 16) 17 (by simp [multiplies])
  simp only [eval_sub,z,o,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] at selected
  rw [ci,di,ri] at selected
  rw [active,Semiring.one_mul,selected] at used
  cases returns with
  | false =>
    have eq : (slot : F) = (count.val : F)-1-(depth.val : F) := by
      simpa [OperandEvents.flag,Semiring.zero_mul,AddCommMonoid.add_zero] using si.symm.trans used
    have exactSlot := SignatureFrames.target_slot_sound count.val depth.val slot count.isLt depth.isLt sb eq
    exact ⟨positive,fun _ => exactSlot.1,by simpa only [Bool.false_eq_true,ite_false,exactSlot.2] using si⟩
  | true =>
    refine ⟨positive,by simp,?_⟩
    simp only [ite_true,Semiring.natCast_zero]
    simp only [OperandEvents.flag] at used
    grind only

theorem read_address {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (functionIndex slot : Nat) (fi : E values (f r.row 1) = (functionIndex : F))
    (si : E values (f r.after 17) = (slot : F)) (active : E values (readActive r) = 1) :
    E values r.read.active = 1 ∧ E values r.read.write = 0 ∧
    E values r.read.address = ((functionIndex*2^32+slot : Nat) : F) := by
  have faces := FrameRowImages.interface matrix r checked values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have ns := facts.multiply (readActive r) (space r) 19 (by simp [multiplies])
  refine ⟨faces.1.trans active,?_,?_⟩
  · simpa only [z,eval_constant values one,Ring.intCast_zero] using faces.2.1
  · rw [faces.2.2.1]
    simp only [eval_append]
    change E values (f r.after 19)+E values (f r.after 17) = _
    rw [ns,active,Semiring.one_mul]
    simp only [space,eval_scale,fi,si,Int.ofNat_eq_natCast,Ring.intCast_natCast,
      Semiring.natCast_add,Semiring.natCast_mul]
    try grind only

theorem write_address {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (functionIndex count : Nat) (fi : E values (f r.row 1) = (functionIndex : F))
    (ci : E values (f r.before 0) = (count : F)) (push : E values (f r.flags 4) = 1) :
    E values r.write.active = 1 ∧ E values r.write.write = 1 ∧
    E values r.write.address = ((functionIndex*2^32+count : Nat) : F) ∧
    E values r.write.value = E values (f r.after 43) := by
  have faces := FrameRowImages.interface matrix r checked values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have addr := facts.multiply (f r.flags 4) (space r++f r.before 0) 44 (by simp [multiplies])
  have val := facts.multiply (f r.flags 4) (f r.after 43) 45 (by simp [multiplies])
  refine ⟨faces.2.2.2.2.1.trans push,faces.2.2.2.2.2.1.trans push,?_,?_⟩
  · rw [faces.2.2.2.2.2.2.1,addr,push,Semiring.one_mul]
    simp only [eval_append,space,eval_scale,fi,ci,Int.ofNat_eq_natCast,Ring.intCast_natCast,
      Semiring.natCast_add,Semiring.natCast_mul]
    try grind only
  · rw [faces.2.2.2.2.2.2.2.1,val,push,Semiring.one_mul]

theorem else_kind {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36)) (image : FrameDescriptor.Image values r token.val)
    (begin : E values (f r.flags 1) = 1) (otherwise : E values (f r.after 3) = 1) :
    token.val%4 = 2 ∧ E values (f r.after 42) = ((4*(token.val/4)+3 : Nat) : F) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have enabled := facts.multiply (f r.flags 1) (f r.after 3) 41 (by simp [multiplies])
  rw [begin,otherwise,Semiring.one_mul] at enabled
  have guard := facts.guard (f r.after 41) (sub (f (descriptor r) 1) (n 2)) (by simp [guards])
  simp only [eval_sub,n,eval_constant values one,Ring.intCast_ofNat 2] at guard
  change E values (f r.after 41)*(E values (f (descriptor r) 1)-(Int.ofNat 2 : F)) = 0 at guard
  rw [enabled,image.kind] at guard
  have ki : ((token.val%4 : Nat) : F) = ((2:Nat):F) := by grind only
  have exactKind := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans (Nat.mod_lt _ (by decide : 0<4)) (by decide)) (by decide : 2<scalarModulus)).mp ki
  have written := facts.select (f r.after 3) (scale (f r.after 38) 4++n 3) (f r.after 31) 42 (by simp [selects])
  simp only [eval_append,eval_scale,n,eval_constant values one,Ring.intCast_ofNat 3,Ring.intCast_ofNat 4] at written
  simp only [otherwise,image.key] at written
  refine ⟨exactKind,?_⟩
  simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_eq_ofNat 3,Semiring.natCast_eq_ofNat 4]
  grind only

#print axioms read_slot
#print axioms read_address
#print axioms write_address
#print axioms else_kind
end ZkBuild.FrameAccessSound
