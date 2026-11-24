import SlotTrace
import Rv32Compiler

namespace ZkBuild.SlotProgram

open Lean.Grind CircuitShape SlotTrace

def operationKind (kind : Fin 10) : Op :=
  match kind.val with
  | 0 => .nop
  | 1 => .get 0
  | 2 => .get 1
  | 3 => .const (0#32)
  | 4 => .binary .add
  | 5 => .binary .sub
  | 6 => .binary .mul
  | 7 => .binary .band
  | 8 => .binary .bor
  | _ => .binary .bxor

def withImmediate (operation : Op) (value : Word) : Op :=
  match operation with
  | .const _ => .const value
  | other => other

theorem immediate_preserves_check (operation : Op) (value : Word) (height : Nat) :
    checkStep (withImmediate operation value) height = checkStep operation height := by
  cases operation <;> rfl

theorem kind_step_certificate : ∀ (kind : Fin 10) (height : Fin 9),
    checkStep (operationKind kind) height.val =
      if SlotShape.valid kind.val height.val then some (SlotShape.nextDepth kind.val height.val) else none := by
  native_decide

def operations (values : Nat → Word) : Nat → List (Fin 10) → List Op
  | _, [] => []
  | start, kind :: rest => withImmediate (operationKind kind) (values start) :: operations values (start+1) rest

theorem operations_length (values : Nat → Word) (start : Nat) (kinds : List (Fin 10)) :
    (operations values start kinds).length = kinds.length := by
  induction kinds generalizing start <;> simp_all [operations]

theorem kind_program_refines (values : Nat → Word) (kinds : List (Fin 10)) :
    ∀ (start : Nat) (height : Fin 9) (final : Nat), checkKinds kinds height.val = some final →
      checkProgram (operations values start kinds) height.val = some final := by
  induction kinds with
  | nil => intro start height final checked; exact checked
  | cons kind rest ih =>
    intro start height final checked
    by_cases valid : SlotShape.valid kind.val height.val = true
    · let next : Fin 9 := ⟨SlotShape.nextDepth kind.val height.val, next_depth_bounded kind height valid⟩
      have tail : checkKinds rest next.val = some final := by simpa [checkKinds, valid] using checked
      simp only [operations, checkProgram, immediate_preserves_check, kind_step_certificate, valid,
        ite_true, Option.bind_some]
      exact ih (start+1) next final tail
    · simp [checkKinds, valid] at checked

theorem satisfying_matrix_has_checked_program {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ kinds : List (Fin 10), kinds.length = 16 ∧ SelectedProgram ctx 0 kinds ∧
      ∀ values : Nat → Word, checkProgram (operations values 0 kinds) 0 = some 1 := by
  obtain ⟨kinds, length, checked, selected⟩ := full_stack_trace ctx one holds
  exact ⟨kinds, length, selected, fun values => kind_program_refines values kinds 0 ⟨0, by decide⟩ 1 checked⟩

-- This concerns bytes emitted by the specified compiler for the recovered
-- opcode sequence. SlotCompilation supplies the later theorem binding both
-- submitted artifacts to the same recovered program.
theorem recovered_program_compiles {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ kinds : List (Fin 10), kinds.length = 16 ∧ SelectedProgram ctx 0 kinds ∧
      ∀ (values : Nat → Word) (registers : Rv32Encoding.Registers),
        ∃ value, ZkBuild.run (Rv32Compiler.inputLocals registers) (operations values 0 kinds) [] = some [value] ∧
          Rv32Encoding.runBytes (Rv32Compiler.compileBytes (operations values 0 kinds)) registers = some value := by
  obtain ⟨kinds, length, selected, checked⟩ := satisfying_matrix_has_checked_program ctx one holds
  exact ⟨kinds, length, selected, fun values registers => Rv32Compiler.compiled_bytes_correct _ (checked values) registers⟩

#print axioms satisfying_matrix_has_checked_program
#print axioms recovered_program_compiles

end ZkBuild.SlotProgram
