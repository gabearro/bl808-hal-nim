import ParametricState
set_option autoImplicit false
namespace ZkBuild.ParametricTransition
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricRowCheck ParametricState
attribute [local instance] Ring.intCast Semiring.natCast

theorem flag_mul {F : Type} [Field F] (a b : Bool) : flag (F := F) a*flag b = flag (a && b) := by
  cases a <;> cases b <;> simp [flag] <;> grind only

theorem cast_flag {F : Type} [Field F] (a : Bool) : (a.toNat : F) = flag a := by
  cases a <;> simp [flag,Semiring.natCast_zero,Semiring.natCast_one]

theorem zero_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ParametricRowCheck.Record) (meaning : ParametricRowSound.Meaning values r)
    (input : Linear) (value i : Nat) (bound : value < 2^64) (image : E values input = (value : F))
    (member : (input,i) ∈ zeros r) : E values (f r.after i) = flag (decide (value = 0)) := by
  have same : (value : F) = (0 : F) ↔ value = 0 := by
    simpa only [Semiring.natCast_zero] using IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans bound (by decide)) (show 0 < scalarModulus from by decide)
  simpa only [image,same,flag,decide_eq_true_eq] using meaning.zero input i member

structure Masks {F : Type} [Field F] (values : Nat → F) (r : ParametricRowCheck.Record)
    (s : State) (kind : Kind) (code : Nat) (actual : Fin 8) : Prop where
  pop : E values (f r.after 19) = flag (popping kind code)
  push : E values (f r.after 20) = flag (pushing kind code)
  zero : E values (f r.after 21) = flag (decide (s.pops = 0))
  one : E values (f r.after 22) = flag (decide (s.pops = 1))
  two : E values (f r.after 23) = flag (decide (s.pops = 2))
  condition : E values (f r.after 24) = flag (popping kind code && decide (s.pops = 0))
  unknown : E values (f r.after 25) = flag (decide (actual.val = 7))
  actualZero : E values (f r.after 26) = flag (decide (actual.val = 0))
  first : E values (f r.after 32) = flag (firstPop s kind code)
  second : E values (f r.after 33) = flag (secondPop s kind code)
  finish : E values (f r.after 45) = flag (ParametricMode.active code && decide (kind = .instructionEnd))

theorem masks {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record) (meaning : ParametricRowSound.Meaning values r)
    (kind : Kind) (tags : ParametricRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (actual : Fin 8) (ai : E values (f r.row 4) = (actual.val : F))
    (s : State) (image : Image values (ready r) s) (pb : s.pops < 2^64) : Masks values r s kind code actual := by
  have mode := ParametricMode.images values one r meaning code cb ci
  have pi : E values (f r.after 15) = (s.pops : F) := image.2.1
  obtain ⟨_,_,t2,t3,_,_,_,t7,_⟩ := InstructionRowSound.selectors values _ kind tags
  change E values (f r.flags 2) = _ at t2
  change E values (f r.flags 3) = _ at t3
  change E values (f r.flags 7) = _ at t7
  have pop := meaning.multiply (present r) (f r.flags 3) 19 (by simp [multiplies])
  have push := meaning.multiply (present r) (f r.flags 2) 20 (by simp [multiplies])
  have finish := meaning.multiply (present r) (f r.flags 7) 45 (by simp [multiplies])
  simp only [mode.2.2.2.2,t2,t3,t7,ControlEvents.selected,flag_mul] at pop push finish
  have z0 := zero_image values r meaning _ s.pops 21 pb pi (by simp [zeros])
  have z1 := ParametricMode.indicator values one r meaning _ s.pops 1 22 pb (by decide) pi (by simp [zeros,n,o])
  have z2 := ParametricMode.indicator values one r meaning _ s.pops 2 23 pb (by decide) pi (by simp [zeros,n,o])
  have unknown := ParametricMode.indicator values one r meaning _ actual.val 7 25 (by have := actual.isLt; omega) (by decide) ai (by simp [zeros])
  have actualZero := zero_image values r meaning _ actual.val 26 (by have := actual.isLt; omega) ai (by simp [zeros])
  have condition := meaning.multiply (f r.after 19) (f r.after 21) 24 (by simp [multiplies])
  have first := meaning.multiply (f r.after 19) (f r.after 22) 32 (by simp [multiplies])
  have second := meaning.multiply (f r.after 19) (f r.after 23) 33 (by simp [multiplies])
  simp only [pop,z0,z1,z2,flag_mul] at condition first second
  exact ⟨pop,push,z0,z1,z2,condition,unknown,actualZero,first,second,finish⟩

theorem image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ParametricRowCheck.Record) (meaning : ParametricRowSound.Meaning values r)
    (kind : Kind) (code : Nat) (actual : Fin 8) (ai : E values (f r.row 4) = (actual.val : F))
    (s : State) (before : Image values (ready r) s) (masks : Masks values r s kind code actual) :
    Image values (after r) (advance s kind code actual) := by
  have d : E values (f r.after 14) = (s.declared : F) := before.1
  have p : E values (f r.after 15) = (s.pops : F) := before.2.1
  have q : E values (f r.after 16) = (s.pushes : F) := before.2.2.1
  have a : E values (f r.after 17) = (s.first.val : F) := before.2.2.2.1
  have b : E values (f r.after 18) = (s.second.val : F) := before.2.2.2.2
  have pEq := meaning.equality (f r.after 15++f r.after 19) 43 (by simp [equalities])
  have qEq := meaning.equality (f r.after 16++f r.after 20) 44 (by simp [equalities])
  have aEq := meaning.select (f r.after 32) (f r.row 4) (f r.after 17) 34 (by simp [selects])
  have bEq := meaning.select (f r.after 33) (f r.row 4) (f r.after 18) 35 (by simp [selects])
  simp only [eval_append,p,q,a,b,ai,masks.pop,masks.push,masks.first,masks.second] at pEq qEq aEq bEq
  refine ⟨d,?_,?_,?_,?_⟩
  · change E values (f r.after 43) = ((s.pops+(popping kind code).toNat : Nat) : F)
    simpa only [Semiring.natCast_add,cast_flag] using pEq
  · change E values (f r.after 44) = ((s.pushes+(pushing kind code).toNat : Nat) : F)
    simpa only [Semiring.natCast_add,cast_flag] using qEq
  · change E values (f r.after 34) = ((if firstPop s kind code then actual else s.first).val : F)
    cases h : firstPop s kind code <;> simp [h,flag] at aEq ⊢ <;> grind only
  · change E values (f r.after 35) = ((if secondPop s kind code then actual else s.second).val : F)
    cases h : secondPop s kind code <;> simp [h,flag] at bEq ⊢ <;> grind only

#print axioms zero_image
#print axioms masks
#print axioms image
end ZkBuild.ParametricTransition
