import Rv32Encoding

namespace ZkBuild.Rv32Compiler

open Rv32Encoding

def stackReg (depth : Nat) : Register := BitVec.ofNat 5 (stackRegister depth)

theorem stack_register_facts : ∀ i : Fin 8,
    stackReg i.val ≠ 0#5 ∧ stackReg i.val ≠ 28#5 ∧ stackReg i.val ≠ 29#5 ∧ stackReg i.val ≠ 1#5 := by
  decide +kernel

theorem stack_register_injective : ∀ i j : Fin 8, stackReg i.val = stackReg j.val → i = j := by
  decide +kernel

theorem stack_reg_ne (i j : Nat) (ib : i < 8) (jb : j < 8) (different : i ≠ j) : stackReg i ≠ stackReg j := by
  intro eq
  have same := stack_register_injective ⟨i, ib⟩ ⟨j, jb⟩ eq
  exact different (congrArg Fin.val same)

def StackInRegisters : List Word → Registers → Prop
  | [], _ => True
  | value :: rest, registers => registers (stackReg rest.length) = value ∧ StackInRegisters rest registers

def Saved (locals : Fin 2 → Word) (registers : Registers) : Prop :=
  registers (28#5) = locals 0 ∧ registers (29#5) = locals 1

theorem stack_write_outside (stack : List Word) (registers : Registers) (destination : Register) (value : Word)
    (outside : ∀ i, i < stack.length → stackReg i ≠ destination)
    (represented : StackInRegisters stack registers) :
    StackInRegisters stack (write registers destination value) := by
  induction stack with
  | nil => trivial
  | cons top rest ih =>
    obtain ⟨head, tail⟩ := represented
    constructor
    · rw [write_other registers destination (stackReg rest.length) value (outside _ (by simp))]
      exact head
    · exact ih (fun i bound => outside i (by simp only [List.length_cons]; omega)) tail

theorem saved_write_stack (locals : Fin 2 → Word) (registers : Registers) (depth : Nat)
    (bound : depth < 8) (value : Word) (saved : Saved locals registers) :
    Saved locals (write registers (stackReg depth) value) := by
  have facts := stack_register_facts ⟨depth, bound⟩
  unfold Saved at saved ⊢
  rw [write_other registers _ (28#5) value (Ne.symm facts.2.1),
    write_other registers _ (29#5) value (Ne.symm facts.2.2.1)]
  exact saved

theorem stack_push (stack : List Word) (registers : Registers) (value : Word)
    (space : stack.length < 8) (represented : StackInRegisters stack registers) :
    StackInRegisters (value :: stack) (write registers (stackReg stack.length) value) := by
  constructor
  · exact write_same registers _ value (stack_register_facts ⟨stack.length, space⟩).1
  · apply stack_write_outside stack registers _ value _ represented
    intro i bound
    exact stack_reg_ne i stack.length (by omega) space (by omega)

theorem stack_binary (rest : List Word) (registers : Registers) (left right : Word) (operation : BinOp)
    (bounded : rest.length+2 ≤ 8) (represented : StackInRegisters (right :: left :: rest) registers) :
    StackInRegisters (operation.eval left right :: rest)
      (write registers (stackReg rest.length) (operation.eval left right)) := by
  constructor
  · exact write_same registers _ _ (stack_register_facts ⟨rest.length, by omega⟩).1
  · apply stack_write_outside rest registers _ _ _ represented.2.2
    intro i bound
    exact stack_reg_ne i rest.length (by omega) (by omega) (by omega)

def upperImmediate (value : Word) : BitVec 20 := (value + 0x800).extractLsb' 12 20
def lowerImmediate (value : Word) : BitVec 12 := value.extractLsb' 0 12

def emitOperation (height : Nat) : Op → List Instruction
  | .nop => [nop, nop]
  | .get i => [.addi (stackReg height) (if i.val = 0 then 28#5 else 29#5) (0#12), nop]
  | .const value => [.lui (stackReg height) (upperImmediate value), .addi (stackReg height) (stackReg height) (lowerImmediate value)]
  | .binary operation => [.binary operation (stackReg (height-2)) (stackReg (height-2)) (stackReg (height-1)), nop]

theorem constant_value (value : Word) :
    (upperImmediate value).setWidth 32 <<< 12 + (lowerImmediate value).signExtend 32 = value := by
  unfold upperImmediate lowerImmediate
  bv_decide

theorem write_overwrite (registers : Registers) (destination : Register) (first second : Word) :
    write (write registers destination first) destination second = write registers destination second := by
  funext i
  by_cases zero : destination = 0#5 <;> by_cases same : i = destination <;> simp [write, zero, same]

theorem run_constant (height : Nat) (bound : height < 8) (value : Word) (registers : Registers) :
    Rv32Encoding.run (emitOperation height (.const value)) registers =
      write registers (stackReg height) value := by
  have nonzero := (stack_register_facts ⟨height, bound⟩).1
  simp only [emitOperation, Rv32Encoding.run, execute, write_same _ _ _ nonzero,
    constant_value, write_overwrite]

theorem run_get (height : Nat) (index : Fin 2) (registers : Registers) :
    Rv32Encoding.run (emitOperation height (.get index)) registers =
      write registers (stackReg height) (registers (if index.val = 0 then 28#5 else 29#5)) := by
  simp only [emitOperation, Rv32Encoding.run]
  rw [execute_nop]
  simp only [execute]
  have zero : (0#12).signExtend 32 = 0#32 := by decide
  rw [zero, BitVec.add_zero]

theorem run_binary (height : Nat) (operation : BinOp) (registers : Registers) :
    Rv32Encoding.run (emitOperation height (.binary operation)) registers =
      write registers (stackReg (height-2))
        (operation.eval (registers (stackReg (height-2))) (registers (stackReg (height-1)))) := by
  simp only [emitOperation, Rv32Encoding.run]
  rw [execute_nop]
  rfl

theorem operation_correct (locals : Fin 2 → Word) (op : Op) (stack : List Word) (height : Nat)
    (checked : checkStep op stack.length = some height) (registers : Registers)
    (saved : Saved locals registers) (represented : StackInRegisters stack registers) :
    ∃ out, step locals op stack = some out ∧ out.length = height ∧
      Saved locals (Rv32Encoding.run (emitOperation stack.length op) registers) ∧
      StackInRegisters out (Rv32Encoding.run (emitOperation stack.length op) registers) := by
  cases op with
  | nop =>
    have outHeight : stack.length = height := by
      unfold checkStep at checked
      split at checked <;> simp_all
    exact ⟨stack, rfl, outHeight, by simpa [emitOperation, Rv32Encoding.run, execute_nop] using saved,
      by simpa [emitOperation, Rv32Encoding.run, execute_nop] using represented⟩
  | const value =>
    have space : stack.length < 8 := by unfold checkStep at checked; split at checked <;> simp_all
    have outHeight : stack.length+1 = height := by simp [checkStep, space] at checked; exact checked
    refine ⟨value :: stack, rfl, by simpa using outHeight, ?_, ?_⟩
    · rw [run_constant _ space]; exact saved_write_stack locals registers _ space value saved
    · rw [run_constant _ space]; exact stack_push stack registers value space represented
  | get index =>
    have space : stack.length < 8 := by unfold checkStep at checked; split at checked <;> simp_all
    have outHeight : stack.length+1 = height := by simp [checkStep, space] at checked; exact checked
    have source : registers (if index.val = 0 then 28#5 else 29#5) = locals index := by
      have bound := index.isLt
      by_cases zero : index.val = 0
      · have eq : index = 0 := Fin.ext zero
        simpa [eq] using saved.1
      · have eq : index = 1 := by apply Fin.ext; omega
        simpa [eq] using saved.2
    refine ⟨locals index :: stack, rfl, by simpa using outHeight, ?_, ?_⟩
    · rw [run_get, source]; exact saved_write_stack locals registers _ space _ saved
    · rw [run_get, source]; exact stack_push stack registers _ space represented
  | binary operation =>
    cases stack with
    | nil => simp [checkStep] at checked
    | cons right tail =>
      cases tail with
      | nil => simp [checkStep] at checked
      | cons left rest =>
        have bounded : rest.length+2 ≤ 8 := by
          unfold checkStep at checked
          split at checked <;> simp_all
        have outHeight : rest.length+1 = height := by
          simp [checkStep, show rest.length+1+1 ≤ 8 by omega] at checked
          omega
        have rightRegister : registers (stackReg (rest.length+1)) = right := by
          simpa only [List.length_cons] using represented.1
        have leftRegister : registers (stackReg rest.length) = left := represented.2.1
        refine ⟨operation.eval left right :: rest, rfl, by simpa using outHeight, ?_, ?_⟩
        all_goals
          rw [run_binary]
          simp only [List.length_cons, show rest.length+1+1-2 = rest.length by omega,
            show rest.length+1+1-1 = rest.length+1 by omega]
          rw [rightRegister, leftRegister]
        · exact saved_write_stack locals registers _ (by omega) _ saved
        · exact stack_binary rest registers left right operation bounded represented

def nextHeight (height : Nat) : Op → Nat
  | .nop => height
  | .const _ | .get _ => height+1
  | .binary _ => height-1

def emitBody : List Op → Nat → List Instruction
  | [], _ => []
  | op :: rest, height => emitOperation height op ++ emitBody rest (nextHeight height op)

theorem checked_height (op : Op) (height next : Nat) (checked : checkStep op height = some next) :
    nextHeight height op = next := by
  cases op <;> simp only [checkStep] at checked <;> split at checked <;> simp_all [nextHeight]

theorem body_correct (locals : Fin 2 → Word) (ops : List Op) (stack : List Word) (height : Nat)
    (checked : checkProgram ops stack.length = some height) (registers : Registers)
    (saved : Saved locals registers) (represented : StackInRegisters stack registers) :
    ∃ out, ZkBuild.run locals ops stack = some out ∧ out.length = height ∧
      Saved locals (Rv32Encoding.run (emitBody ops stack.length) registers) ∧
      StackInRegisters out (Rv32Encoding.run (emitBody ops stack.length) registers) := by
  induction ops generalizing stack height registers with
  | nil =>
    have same : stack.length = height := by simpa [checkProgram] using checked
    exact ⟨stack, rfl, same, saved, represented⟩
  | cons op rest ih =>
    simp only [checkProgram, Option.bind_eq_some_iff] at checked
    obtain ⟨next, headCheck, tailCheck⟩ := checked
    obtain ⟨middle, headRun, middleLength, middleSaved, middleRep⟩ :=
      operation_correct locals op stack next headCheck registers saved represented
    have tailChecked : checkProgram rest middle.length = some height := by rw [middleLength]; exact tailCheck
    obtain ⟨out, tailRun, outLength, outSaved, outRep⟩ :=
      ih middle height tailChecked (Rv32Encoding.run (emitOperation stack.length op) registers) middleSaved middleRep
    have nextEq := checked_height op stack.length next headCheck
    refine ⟨out, ?_, outLength, ?_, ?_⟩
    · simp only [ZkBuild.run, headRun, Option.bind_some, tailRun]
    · simpa only [emitBody, run_append, nextEq, middleLength] using outSaved
    · simpa only [emitBody, run_append, nextEq, middleLength] using outRep

def prologue : List Instruction := [.addi (28#5) (10#5) (0#12), .addi (29#5) (11#5) (0#12)]
def epilogue : List Instruction := [.addi (10#5) (stackReg 0) (0#12)]
def compile (ops : List Op) : List Instruction := prologue ++ emitBody ops 0 ++ epilogue
def inputLocals (registers : Registers) (i : Fin 2) : Word :=
  if i.val = 0 then registers (10#5) else registers (11#5)

theorem prologue_saved (registers : Registers) :
    Saved (inputLocals registers) (Rv32Encoding.run prologue registers) := by
  have zero : (0#12).signExtend 32 = 0#32 := by decide
  simp [Saved, inputLocals, prologue, Rv32Encoding.run, execute, write, zero]

theorem epilogue_result (registers : Registers) (value : Word)
    (represented : StackInRegisters [value] registers) :
    Rv32Encoding.run epilogue registers (10#5) = value := by
  have zero : (0#12).signExtend 32 = 0#32 := by decide
  simpa [epilogue, Rv32Encoding.run, execute, write, zero] using represented.1

theorem compiled_correct (ops : List Op) (checked : checkProgram ops 0 = some 1) (registers : Registers) :
    ∃ value, ZkBuild.run (inputLocals registers) ops [] = some [value] ∧
      runEncoded ((compile ops).map encode ++ [returnWord]) registers = some value := by
  obtain ⟨out, sourceRun, length, _, represented⟩ :=
    body_correct (inputLocals registers) ops [] 1 checked (Rv32Encoding.run prologue registers)
      (prologue_saved registers) trivial
  cases out with
  | nil => simp at length
  | cons value tail =>
    cases tail with
    | cons other tail => simp at length
    | nil =>
      refine ⟨value, sourceRun, ?_⟩
      rw [encoded_execution, compile, run_append, run_append]
      exact congrArg some (epilogue_result _ value represented)

def compileBytes (ops : List Op) : List (BitVec 8) :=
  ((compile ops).map encode ++ [returnWord]).flatMap wordBytes

theorem compiled_bytes_correct (ops : List Op) (checked : checkProgram ops 0 = some 1) (registers : Registers) :
    ∃ value, ZkBuild.run (inputLocals registers) ops [] = some [value] ∧ runBytes (compileBytes ops) registers = some value := by
  obtain ⟨value, source, native⟩ := compiled_correct ops checked registers
  refine ⟨value, source, ?_⟩
  simpa only [compileBytes, runBytes, load_word_stream, Option.bind_some] using native

def callerSaved : List Register :=
  [5#5, 6#5, 7#5, 10#5, 11#5, 12#5, 13#5, 14#5, 15#5, 16#5, 17#5, 28#5, 29#5, 30#5, 31#5]

theorem stack_register_caller_saved : ∀ i : Fin 8, stackReg i.val ∈ callerSaved := by decide +kernel

theorem write_preserves (registers : Registers) (destination : Register) (value : Word)
    (allowed : destination ∈ callerSaved) (q : Register) (outside : q ∉ callerSaved) :
    write registers destination value q = registers q := by
  apply write_other
  intro eq
  exact outside (eq ▸ allowed)

theorem operation_preserves (op : Op) (height next : Nat) (checked : checkStep op height = some next)
    (registers : Registers) (q : Register) (outside : q ∉ callerSaved) :
    Rv32Encoding.run (emitOperation height op) registers q = registers q := by
  cases op with
  | nop => simp [emitOperation, Rv32Encoding.run, execute_nop]
  | const value =>
    have bound : height < 8 := by unfold checkStep at checked; split at checked <;> simp_all
    rw [run_constant height bound]
    exact write_preserves registers _ value (stack_register_caller_saved ⟨height, bound⟩) q outside
  | get index =>
    have bound : height < 8 := by unfold checkStep at checked; split at checked <;> simp_all
    rw [run_get]
    exact write_preserves registers _ _ (stack_register_caller_saved ⟨height, bound⟩) q outside
  | binary operation =>
    have bound : height-2 < 8 := by
      unfold checkStep at checked
      split at checked <;> simp_all <;> omega
    rw [run_binary]
    exact write_preserves registers _ _ (stack_register_caller_saved ⟨height-2, bound⟩) q outside

theorem body_preserves (ops : List Op) (height next : Nat) (checked : checkProgram ops height = some next)
    (registers : Registers) (q : Register) (outside : q ∉ callerSaved) :
    Rv32Encoding.run (emitBody ops height) registers q = registers q := by
  induction ops generalizing height registers with
  | nil => rfl
  | cons op rest ih =>
    simp only [checkProgram, Option.bind_eq_some_iff] at checked
    obtain ⟨middle, headCheck, tailCheck⟩ := checked
    rw [emitBody, run_append, checked_height op height middle headCheck, ih middle tailCheck]
    exact operation_preserves op height middle headCheck registers q outside

theorem compile_preserves (ops : List Op) (checked : checkProgram ops 0 = some 1)
    (registers : Registers) (q : Register) (outside : q ∉ callerSaved) :
    Rv32Encoding.run (compile ops) registers q = registers q := by
  have not28 : q ≠ 28#5 := by intro eq; apply outside; rw [eq]; decide
  have not29 : q ≠ 29#5 := by intro eq; apply outside; rw [eq]; decide
  have not10 : q ≠ 10#5 := by intro eq; apply outside; rw [eq]; decide
  have zero : (0#12).signExtend 32 = 0#32 := by decide
  rw [compile, run_append, run_append]
  simp only [epilogue, Rv32Encoding.run, execute, zero, BitVec.add_zero, write_other _ _ q _ not10]
  rw [body_preserves ops 0 1 checked _ q outside]
  simp only [prologue, Rv32Encoding.run, execute, zero, BitVec.add_zero,
    write_other _ _ q _ not29, write_other _ _ q _ not28]

theorem return_address_preserved (ops : List Op) (checked : checkProgram ops 0 = some 1) (registers : Registers) :
    Rv32Encoding.run (compile ops) registers (1#5) = registers (1#5) :=
  compile_preserves ops checked registers (1#5) (by decide)

#print axioms operation_correct
#print axioms body_correct
#print axioms compiled_correct
#print axioms compiled_bytes_correct
#print axioms compile_preserves

end ZkBuild.Rv32Compiler
