import SlotModuleCompleteness

namespace ZkBuild.SlotCheckedTrace

open SlotWitness

def heightAt : List Op → Nat → Nat → Nat
  | _, height, 0 => height
  | [], height, _+1 => height
  | op :: rest, height, index+1 => heightAt rest (Rv32Compiler.nextHeight height op) index

theorem step_bounded (op : Op) (height next : Nat) (checked : checkStep op height = some next) : next < 9 := by
  cases op <;> simp only [checkStep] at checked <;> split at checked <;> simp_all <;> omega

theorem height_bounded (ops : List Op) : ∀ (height final : Nat), height < 9 → checkProgram ops height = some final →
    ∀ index, index ≤ ops.length → heightAt ops height index < 9 := by
  induction ops with
  | nil =>
    intro height final bounded checked index limit
    have zero : index = 0 := by simpa using limit
    simp [zero, heightAt, bounded]
  | cons op rest ih =>
    intro height final bounded checked index limit
    obtain ⟨middle, head, tail⟩ := Option.bind_eq_some_iff.mp checked
    have next := Rv32Compiler.checked_height op height middle head
    cases index with
    | zero => exact bounded
    | succ index =>
      simp only [heightAt, next]
      exact ih middle final (step_bounded op height middle head) tail index (by simp only [List.length_cons] at limit; omega)

theorem height_end (ops : List Op) : ∀ (height final : Nat), checkProgram ops height = some final →
    heightAt ops height ops.length = final := by
  induction ops with
  | nil => intro height final checked; simpa [checkProgram, heightAt] using checked
  | cons op rest ih =>
    intro height final checked
    obtain ⟨middle, head, tail⟩ := Option.bind_eq_some_iff.mp checked
    simpa only [List.length_cons, heightAt, Rv32Compiler.checked_height op height middle head] using ih middle final tail

theorem height_step (ops : List Op) : ∀ (height final : Nat), checkProgram ops height = some final →
    ∀ (index : Nat) (bound : index < ops.length),
      checkStep ops[index] (heightAt ops height index) = some (heightAt ops height (index+1)) := by
  induction ops with
  | nil => intro height final checked index bound; simp at bound
  | cons op rest ih =>
    intro height final checked index bound
    obtain ⟨middle, head, tail⟩ := Option.bind_eq_some_iff.mp checked
    have next := Rv32Compiler.checked_height op height middle head
    cases index with
    | zero => simpa only [List.getElem_cons_zero, heightAt, next] using head
    | succ index =>
      simpa only [List.getElem_cons_succ, heightAt, next] using
        ih middle final tail index (by simp only [List.length_cons] at bound; omega)

def actionFor : Op → Fin 10 × Word
  | .nop => (0, 0)
  | .get i => (if i.val = 0 then 1 else 2, 0)
  | .const value => (3, value)
  | .binary .add => (4, 0)
  | .binary .sub => (5, 0)
  | .binary .mul => (6, 0)
  | .binary .band => (7, 0)
  | .binary .bor => (8, 0)
  | .binary .bxor => (9, 0)

theorem action_operation (op : Op) : SlotNative.operation (actionFor op).1 (actionFor op).2 = op := by
  cases op with
  | nop => rfl
  | const value => rfl
  | binary operation => cases operation <;> rfl
  | get i =>
    have cases : i.val = 0 ∨ i.val = 1 := by have := i.isLt; omega
    rcases cases with zero | one
    · have same : i = (0 : Fin 2) := Fin.ext zero
      subst i
      rfl
    · have same : i = (1 : Fin 2) := Fin.ext one
      subst i
      rfl

theorem action_step (op : Op) (height : Fin 9) : checkStep op height.val =
    if SlotShape.valid (actionFor op).1.val height.val then
      some (SlotShape.nextDepth (actionFor op).1.val height.val) else none := by
  conv => lhs; rw [← action_operation op]
  simp only [SlotNative.operation, SlotProgram.immediate_preserves_check, SlotProgram.kind_step_certificate]

def actionsFor (ops : List Op) (i : Fin 16) : Fin 10 × Word := actionFor (ops[i.val]?.getD .nop)

def heightsFor (ops : List Op) (i : Fin 17) : Fin 9 :=
  ⟨heightAt ops 0 i.val % 9, Nat.mod_lt _ (by decide)⟩

theorem height_value (ops : List Op) (length : ops.length = 16) (checked : checkProgram ops 0 = some 1) (i : Fin 17) :
    (heightsFor ops i).val = heightAt ops 0 i.val := by
  apply Nat.mod_eq_of_lt
  exact height_bounded ops 0 1 (by decide) checked i.val (by have := i.isLt; omega)

theorem checked_trace (ops : List Op) (length : ops.length = 16) (checked : checkProgram ops 0 = some 1) :
    ValidTrace (actionsFor ops) (heightsFor ops) := by
  refine ⟨?_, ?_, ?_⟩
  · rw [height_value ops length checked]
    simp [heightAt]
  · rw [height_value ops length checked]
    simpa only [length] using height_end ops 0 1 checked
  · intro i
    have bound : i.val < ops.length := by rw [length]; exact i.isLt
    have step := height_step ops 0 1 checked i.val bound
    have formula := action_step ops[i.val] (before (heightsFor ops) i)
    have beforeValue : (before (heightsFor ops) i).val = heightAt ops 0 i.val := height_value ops length checked _
    have afterValue : (after (heightsFor ops) i).val = heightAt ops 0 (i.val+1) := height_value ops length checked _
    have action : actionsFor ops i = actionFor ops[i.val] := by
      simp only [actionsFor, List.getElem?_eq_getElem bound, Option.getD_some]
    rw [beforeValue, step] at formula
    by_cases valid : SlotShape.valid (actionFor ops[i.val]).1.val (heightAt ops 0 i.val) = true
    · simp only [valid, ite_true, Option.some.injEq] at formula
      constructor
      · simpa only [action, beforeValue] using valid
      · simpa only [action, beforeValue, afterValue] using formula
    · simp only [valid, ite_false, reduceCtorEq] at formula

#print axioms checked_trace

theorem checked_program_matrix {F : Type} [Lean.Grind.CommRing F]
    (ops : List Op) (length : ops.length = 16) (checked : checkProgram ops 0 = some 1) :
    CircuitShape.Satisfied SlotShape.compileShape
      (SlotModuleCompleteness.context (F := F) (actionsFor ops) (heightsFor ops)).get :=
  SlotModuleCompleteness.constructed_matrix (actionsFor ops) (heightsFor ops) (checked_trace ops length checked)

#print axioms checked_program_matrix

end ZkBuild.SlotCheckedTrace
