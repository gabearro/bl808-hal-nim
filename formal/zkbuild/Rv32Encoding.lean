import ZkBuild

namespace ZkBuild.Rv32Encoding

abbrev Register := BitVec 5
abbrev Registers := Register → Word

inductive Instruction where
  | addi (destination source : Register) (immediate : BitVec 12)
  | lui (destination : Register) (immediate : BitVec 20)
  | binary (operation : BinOp) (destination left right : Register)
  deriving DecidableEq, Repr

def write (registers : Registers) (destination : Register) (value : Word) : Registers :=
  if destination = 0#5 then registers else fun i => if i = destination then value else registers i

def execute (instruction : Instruction) (registers : Registers) : Registers :=
  match instruction with
  | .addi destination source immediate => write registers destination (registers source + immediate.signExtend 32)
  | .lui destination immediate => write registers destination (immediate.setWidth 32 <<< 12)
  | .binary operation destination left right => write registers destination (operation.eval (registers left) (registers right))

def run : List Instruction → Registers → Registers
  | [], registers => registers
  | instruction :: rest, registers => run rest (execute instruction registers)

def functionBits : BinOp → Word
  | .add => 0
  | .sub => 0x40000000
  | .mul => 0x02000000
  | .band => 0x7000
  | .bor => 0x6000
  | .bxor => 0x4000

def function7 : BinOp → BitVec 7
  | .sub => 0x20
  | .mul => 1
  | _ => 0

def function3 : BinOp → BitVec 3
  | .band => 7
  | .bor => 6
  | .bxor => 4
  | _ => 0

def encode : Instruction → Word
  | .addi destination source immediate =>
    (immediate.setWidth 32 <<< 20) ||| (source.setWidth 32 <<< 15) ||| (destination.setWidth 32 <<< 7) ||| 0x13
  | .lui destination immediate =>
    (immediate.setWidth 32 <<< 12) ||| (destination.setWidth 32 <<< 7) ||| 0x37
  | .binary operation destination left right =>
    (right.setWidth 32 <<< 20) ||| (left.setWidth 32 <<< 15) ||| (destination.setWidth 32 <<< 7) ||| functionBits operation ||| 0x33

def decodeOperation (function7 : BitVec 7) (function3 : BitVec 3) : Option BinOp :=
  if function7 = 0 ∧ function3 = 0 then some .add
  else if function7 = 0x20 ∧ function3 = 0 then some .sub
  else if function7 = 1 ∧ function3 = 0 then some .mul
  else if function7 = 0 ∧ function3 = 7 then some .band
  else if function7 = 0 ∧ function3 = 6 then some .bor
  else if function7 = 0 ∧ function3 = 4 then some .bxor
  else none

def decode (word : Word) : Option Instruction :=
  let opcode := word.extractLsb' 0 7
  let destination := word.extractLsb' 7 5
  let source := word.extractLsb' 15 5
  if opcode = 0x13 ∧ word.extractLsb' 12 3 = 0 then
    some (.addi destination source (word.extractLsb' 20 12))
  else if opcode = 0x37 then some (.lui destination (word.extractLsb' 12 20))
  else if opcode = 0x33 then
    (decodeOperation (word.extractLsb' 25 7) (word.extractLsb' 12 3)).map fun operation =>
      .binary operation destination source (word.extractLsb' 20 5)
  else none

def nop : Instruction := .addi (0#5) (0#5) (0#12)
def returnWord : Word := 0x00008067

def runEncoded : List Word → Registers → Option Word
  | [], _ => none
  | word :: rest, registers =>
    if word = returnWord then
      if rest.isEmpty then some (registers (10#5)) else none
    else (decode word).bind fun instruction => runEncoded rest (execute instruction registers)

theorem run_append (first second : List Instruction) (registers : Registers) :
    run (first ++ second) registers = run second (run first registers) := by
  induction first generalizing registers with
  | nil => rfl
  | cons instruction rest ih => simp only [List.cons_append, run, ih]

theorem write_same (registers : Registers) (destination : Register) (value : Word)
    (nonzero : destination ≠ 0#5) : write registers destination value destination = value := by
  simp [write, nonzero]

theorem write_other (registers : Registers) (destination source : Register) (value : Word)
    (distinct : source ≠ destination) : write registers destination value source = registers source := by
  by_cases zero : destination = 0#5 <;> simp [write, zero, distinct]

theorem execute_nop (registers : Registers) : execute nop registers = registers := by
  simp [nop, execute, write]

theorem addi_fields (destination source : Register) (immediate : BitVec 12) :
    let word := encode (.addi destination source immediate)
    word.extractLsb' 0 7 = 0x13 ∧ word.extractLsb' 7 5 = destination ∧
      word.extractLsb' 12 3 = 0 ∧ word.extractLsb' 15 5 = source ∧ word.extractLsb' 20 12 = immediate := by
  simp only [encode]
  bv_decide

theorem lui_fields (destination : Register) (immediate : BitVec 20) :
    let word := encode (.lui destination immediate)
    word.extractLsb' 0 7 = 0x37 ∧ word.extractLsb' 7 5 = destination ∧ word.extractLsb' 12 20 = immediate := by
  simp only [encode]
  bv_decide

theorem binary_fields (operation : BinOp) (destination left right : Register) :
    let word := encode (.binary operation destination left right)
    word.extractLsb' 0 7 = 0x33 ∧ word.extractLsb' 7 5 = destination ∧
      word.extractLsb' 15 5 = left ∧ word.extractLsb' 20 5 = right ∧
      word.extractLsb' 25 7 = function7 operation ∧ word.extractLsb' 12 3 = function3 operation := by
  cases operation <;> simp only [encode, functionBits, function7, function3] <;> bv_decide

theorem decode_function (operation : BinOp) :
    decodeOperation (function7 operation) (function3 operation) = some operation := by
  cases operation <;> decide

theorem decode_encode (instruction : Instruction) : decode (encode instruction) = some instruction := by
  cases instruction with
  | addi destination source immediate =>
    obtain ⟨opcode, rd, function3, rs, imm⟩ := addi_fields destination source immediate
    simp only [decode, opcode, rd, function3, rs, imm, and_self, ite_true]
  | lui destination immediate =>
    obtain ⟨opcode, rd, imm⟩ := lui_fields destination immediate
    simp [decode, opcode, rd, imm]
  | binary operation destination left right =>
    obtain ⟨opcode, rd, rs1, rs2, f7, f3⟩ := binary_fields operation destination left right
    simp [decode, opcode, rd, rs1, rs2, f7, f3, decode_function]

theorem encoded_not_return (instruction : Instruction) : encode instruction ≠ returnWord := by
  cases instruction with
  | addi destination source immediate => simp only [encode, returnWord]; bv_decide
  | lui destination immediate => simp only [encode, returnWord]; bv_decide
  | binary operation destination left right =>
    cases operation <;> simp only [encode, functionBits, returnWord] <;> bv_decide

theorem encoded_execution (instructions : List Instruction) (registers : Registers) :
    runEncoded (instructions.map encode ++ [returnWord]) registers = some (run instructions registers (10#5)) := by
  induction instructions generalizing registers with
  | nil => simp [runEncoded, run]
  | cons instruction rest ih =>
    simp only [List.map_cons, List.cons_append, runEncoded, encoded_not_return, ite_false,
      decode_encode, Option.bind_some, ih, run]

def wordBytes (word : Word) : List (BitVec 8) :=
  [word.extractLsb' 0 8, word.extractLsb' 8 8, word.extractLsb' 16 8, word.extractLsb' 24 8]

def loadWord (a b c d : BitVec 8) : Word :=
  a.setWidth 32 ||| (b.setWidth 32 <<< 8) ||| (c.setWidth 32 <<< 16) ||| (d.setWidth 32 <<< 24)

def loadWords : List (BitVec 8) → Option (List Word)
  | [] => some []
  | a :: b :: c :: d :: rest => (loadWords rest).map fun words => loadWord a b c d :: words
  | _ => none

theorem load_word_bytes (word : Word) :
    loadWord (word.extractLsb' 0 8) (word.extractLsb' 8 8) (word.extractLsb' 16 8) (word.extractLsb' 24 8) = word := by
  unfold loadWord
  bv_decide

theorem load_word_stream (words : List Word) : loadWords (words.flatMap wordBytes) = some words := by
  induction words with
  | nil => rfl
  | cons word rest ih => simp only [List.flatMap_cons, wordBytes, List.cons_append, List.nil_append,
      loadWords, ih, Option.map_some, load_word_bytes]

def runBytes (bytes : List (BitVec 8)) (registers : Registers) : Option Word :=
  (loadWords bytes).bind fun words => runEncoded words registers

theorem bytes_execution (instructions : List Instruction) (registers : Registers) :
    runBytes ((instructions.map encode ++ [returnWord]).flatMap wordBytes) registers =
      some (run instructions registers (10#5)) := by
  rw [runBytes, load_word_stream, Option.bind_some, encoded_execution]

#print axioms decode_encode
#print axioms encoded_execution
#print axioms bytes_execution

end ZkBuild.Rv32Encoding
