import ConstantSourceValues
set_option autoImplicit false
namespace ZkBuild.ConstantSourceModes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem mode_value {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (r : ConstantSourceMatrix.Record) (i : Nat) (inside : i < 8)
    (choice : ∀ j, j < 8 → E values (selected r j) = (if j = i then 1 else 0)) :
    E values (mode r) = (modes.getD i 0 : F) := by
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have scaled (a : Linear) (n : Int) : E values (scale a n) = (n : F)*E values a := eval_scale values a n
  have z : E values DeclarationMatrix.z = 0 := by simp [DeclarationMatrix.z,eval_constant values oneValue]
  have f0 := choice 0 (by decide)
  have f1 := choice 1 (by decide)
  have f2 := choice 2 (by decide)
  have f3 := choice 3 (by decide)
  have f4 := choice 4 (by decide)
  have f5 := choice 5 (by decide)
  have f6 := choice 6 (by decide)
  have f7 := choice 7 (by decide)
  have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp only [modes,List.getD_cons_zero,List.getD_cons_succ]
    <;> simp [mode,add,scaled,z,f0,f1,f2,f3,f4,f5,f6,f7,
      Semiring.natCast_eq_ofNat] <;> grind

theorem wire_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (field r 0) = 1) :
    E values (field r 3) = 1 ∧ E values (field r 4) = 1 ∧
    E values (field r 10) = E values (field r 8)*E values (field r 5) ∧
    E values (field r 12) = E values (field r 8)*E values (field r 11) ∧
    E values (field r 14) = E values (vector r)*E values (field r 13) ∧
    E values (field r 17) = E values (field r 9)*E values (field r 6) := by
  have all := holds matrix tokens splits r checked values satisfied
  have first := part_holds values tokens splits r all 0 (by decide)
  have third := part_holds values tokens splits r all 2 (by decide)
  have sixth := part_holds values tokens splits r all 5 (by decide)
  have last := part_holds values tokens splits r all 10 (by decide)
  have recordActive := equality_sound values oneValue (field r 3) (field r 0) (first _ (by simp [parts]))
  have count := first (gate (field r 0) (sub (field r 4) o)) (by simp [parts])
  change E values (field r 0)*E values (sub (field r 4) o) = E values DeclarationMatrix.z at count
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values DeclarationMatrix.z = 0 := by simp [DeclarationMatrix.z,eval_constant values oneValue]
  rw [active,eval_sub,one,zero,Semiring.one_mul] at count
  exact ⟨recordActive.trans active,by grind,
    multiply_sound values _ _ _ (third _ (by simp [parts])),
    multiply_sound values _ _ _ (sixth _ (by simp [parts])),
    multiply_sound values _ _ _ (sixth _ (by simp [parts])),
    multiply_sound values _ _ _ (last _ (by simp [parts]))⟩

def encodedOpcode (i : Nat) : Nat := if i = 4 then 0xfd else opcodes.getD i 0

theorem prefix_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (field r 0) = 1) (modern : E values (field r 8) = 1)
    (i : Nat) (inside : i < 8) (opcode : E values (field r 5) = (opcodes.getD i 0 : F))
    (choice : ∀ j, j < 8 → E values (selected r j) = (if j = i then 1 else 0)) :
    E values (layout r 0).2.2 = (encodedOpcode i : F) := by
  have product := (wire_values matrix tokens splits r checked values oneValue satisfied active).2.2.1
  have add : E values (field r 10 ++ scale (vector r) (0xfd-0x302)) = E values (field r 10)+E values (scale (vector r) (0xfd-0x302)) := eval_append values _ _
  have scaled : E values (scale (vector r) (0xfd-0x302)) = ((0xfd-0x302 : Int) : F)*E values (vector r) := eval_scale values _ _
  have vc : E values (vector r) = (if 4 = i then 1 else 0) := choice 4 (by decide)
  change E values (field r 10 ++ scale (vector r) (0xfd-0x302)) = _
  rw [add,product,modern,Semiring.one_mul,opcode,scaled,vc]
  have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp only [encodedOpcode,opcodes,List.getD_cons_zero,List.getD_cons_succ] <;>
    simp [Semiring.natCast_eq_ofNat,Ring.intCast_neg] <;> grind

theorem unused_mode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (disabled : E values (field r 8) = 0) : E values (vector r) = 0 ∧ E values (mode r) = 0 := by
  have zero (j : Nat) (inside : j < 8) : E values (selected r j) = 0 := by
    rw [selector_value matrix tokens splits r checked values oneValue satisfied j inside,disabled,Semiring.zero_mul]
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have scaled (a : Linear) (n : Int) : E values (scale a n) = (n : F)*E values a := eval_scale values a n
  refine ⟨zero 4 (by decide),?_⟩
  have f0 := zero 0 (by decide)
  have f1 := zero 1 (by decide)
  have f2 := zero 2 (by decide)
  have f3 := zero 3 (by decide)
  have f4 := zero 4 (by decide)
  have f5 := zero 5 (by decide)
  have f6 := zero 6 (by decide)
  have f7 := zero 7 (by decide)
  simp only [mode,add,scaled,f0,f1,f2,f3,f4,f5,f6,f7,Semiring.mul_zero,Semiring.add_zero]
  simp [z,eval_constant values oneValue]

#print axioms mode_value
#print axioms wire_values
#print axioms prefix_value
#print axioms unused_mode
end ZkBuild.ConstantSourceModes
