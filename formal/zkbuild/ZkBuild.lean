import Std

/-!
The first certified profile: straight-line i32 WASM, two i32 parameters,
one i32 result, and a bounded operand stack. This is an executable mathematical
specification, not a claim that the existing optimizing JIT is verified.
-/
namespace ZkBuild

abbrev Word := BitVec 32

inductive BinOp where
  | add | sub | mul | band | bor | bxor
  deriving DecidableEq, Repr

def BinOp.eval : BinOp → Word → Word → Word
  | .add, a, b => a + b
  | .sub, a, b => a - b
  | .mul, a, b => a * b
  | .band, a, b => a &&& b
  | .bor, a, b => a ||| b
  | .bxor, a, b => a ^^^ b

inductive Op where
  | nop
  | const (value : Word)
  | get (index : Fin 2)
  | binary (op : BinOp)
  deriving DecidableEq, Repr

def checkStep (op : Op) (height : Nat) : Option Nat :=
  match op with
  | .nop => if height ≤ 8 then some height else none
  | .const _ | .get _ => if height < 8 then some (height + 1) else none
  | .binary _ => if 2 ≤ height ∧ height ≤ 8 then some (height - 1) else none

def step (locals : Fin 2 → Word) (op : Op) (stack : List Word) : Option (List Word) :=
  match op with
  | .nop => some stack
  | .const v => some (v :: stack)
  | .get i => some (locals i :: stack)
  | .binary b => match stack with
    | right :: left :: rest => some (b.eval left right :: rest)
    | _ => none

theorem step_safe (locals : Fin 2 → Word) (op : Op) (s : List Word) (h : Nat)
    (ok : checkStep op s.length = some h) :
    ∃ out, step locals op s = some out ∧ out.length = h ∧ h ≤ 8 := by
  cases op with
  | nop =>
    simp only [checkStep] at ok
    split at ok <;> simp_all [step]
  | const value =>
    simp only [checkStep] at ok
    split at ok
    · simp_all [step]
      omega
    · simp_all
  | get index =>
    simp only [checkStep] at ok
    split at ok
    · simp_all [step]
      omega
    · simp_all
  | binary op =>
    cases s with
    | nil => simp [checkStep] at ok
    | cons right tail =>
      cases tail with
      | nil => simp [checkStep] at ok
      | cons left rest =>
        simp only [checkStep, List.length_cons] at ok
        split at ok
        · simp_all [step]
          omega
        · simp_all

def checkProgram : List Op → Nat → Option Nat
  | [], h => some h
  | op :: rest, h => (checkStep op h).bind (checkProgram rest)

def run (locals : Fin 2 → Word) : List Op → List Word → Option (List Word)
  | [], stack => some stack
  | op :: rest, stack => (step locals op stack).bind (run locals rest)

theorem program_safe (locals : Fin 2 → Word) (ops : List Op) :
    ∀ (s : List Word) (height : Nat),
    checkProgram ops s.length = some height →
    ∃ out, run locals ops s = some out ∧ out.length = height := by
  induction ops with
  | nil => intro s height h; simp_all [checkProgram, run]
  | cons op rest ih =>
    intro s height h
    simp only [checkProgram, Option.bind_eq_some_iff] at h
    obtain ⟨nextHeight, stepOk, restOk⟩ := h
    obtain ⟨next, nextOk, nextLen, _⟩ := step_safe locals op s nextHeight stepOk
    rw [← nextLen] at restOk
    obtain ⟨out, runOk, outLen⟩ := ih next height restOk
    exact ⟨out, by simp [run, nextOk, runOk], outLen⟩

theorem admitted_program_has_one_result (locals : Fin 2 → Word) (ops : List Op)
    (ok : checkProgram ops 0 = some 1) :
    ∃ value, run locals ops [] = some [value] := by
  obtain ⟨out, runOk, outLen⟩ := program_safe locals ops [] 1 ok
  cases out with
  | nil => simp at outLen
  | cons value tail =>
    cases tail with
    | nil => exact ⟨value, runOk⟩
    | cons other tail => simp at outLen

-- These three theorems check the exact RV32 immediate construction used by
-- the certified emitter, including the signed low-12-bit carry.
def rv32SignExtend12 (v : Word) : Word := (v.extractLsb' 0 12).signExtend 32
def rv32Upper (v : Word) : Word := (v + 0x800) &&& 0xfffff000

theorem materialize_constant_correct (v : Word) :
    rv32Upper v + rv32SignExtend12 v = v := by
  unfold rv32Upper rv32SignExtend12
  bv_decide

theorem addition_modular (a b : Word) :
    ((a.toNat + b.toNat) % 2^32) = (a + b).toNat := by
  simp

theorem subtraction_operand_order (a b : Word) :
    BinOp.eval .sub a b = a - b := rfl

def stackRegister (depth : Nat) : Nat :=
  if depth < 3 then depth + 5 else depth + 7

theorem stack_registers_distinct (i j : Nat)
    (eq : stackRegister i = stackRegister j) : i = j := by
  unfold stackRegister at eq
  split at eq <;> split at eq <;> omega

theorem stack_registers_caller_saved (i : Nat) (bound : i < 8) :
    stackRegister i ∈ [5, 6, 7, 10, 11, 12, 13, 14] := by
  simp only [List.mem_cons]
  unfold stackRegister
  split <;> omega

def leb5 (v : Word) : BitVec 8 × BitVec 8 × BitVec 8 × BitVec 8 × BitVec 8 :=
  (v.setWidth 8 &&& 0x7f ||| 0x80,
   (v >>> 7).setWidth 8 &&& 0x7f ||| 0x80,
   (v >>> 14).setWidth 8 &&& 0x7f ||| 0x80,
   (v >>> 21).setWidth 8 &&& 0x7f ||| 0x80,
   (v >>> 28).setWidth 8 ||| if v.getLsbD 31 then 0x70 else 0)

def decodeLeb5 (b : BitVec 8 × BitVec 8 × BitVec 8 × BitVec 8 × BitVec 8) : Word :=
  (b.1 &&& 0x7f).setWidth 32 |||
  ((b.2.1 &&& 0x7f).setWidth 32 <<< 7) |||
  ((b.2.2.1 &&& 0x7f).setWidth 32 <<< 14) |||
  ((b.2.2.2.1 &&& 0x7f).setWidth 32 <<< 21) |||
  ((b.2.2.2.2 &&& 0x0f).setWidth 32 <<< 28)

theorem constant_leb_roundtrip (v : Word) : decodeLeb5 (leb5 v) = v := by
  simp only [decodeLeb5, leb5]
  bv_decide

-- Portable 64-bit fallback used while compiling the Nim arithmetic backend
-- for RV32, where a C uint128 type is unavailable.
theorem carry64_correct (a b : BitVec 64) (carry : Bool) :
    let input : BitVec 64 := if carry then 1 else 0
    let interim := a + b
    let total := interim + input
    (decide (interim < a) || decide (total < interim)) =
      (a.zeroExtend 65 + b.zeroExtend 65 + input.zeroExtend 65).getLsbD 64 := by
  dsimp
  bv_decide

theorem borrow64_correct (a b : BitVec 64) (borrow : Bool) :
    let input : BitVec 64 := if borrow then 1 else 0
    let interim := a - b
    (decide (a < b) || decide (interim < input)) =
      decide (a.zeroExtend 65 < b.zeroExtend 65 + input.zeroExtend 65) := by
  dsimp
  bv_decide

def packBytes : List (Fin 256) → Nat
  | [] => 0
  | b :: rest => b.val + 256 * packBytes rest

theorem pack_bytes_injective (xs : List (Fin 256)) :
    ∀ ys, xs.length = ys.length → packBytes xs = packBytes ys → xs = ys := by
  induction xs with
  | nil =>
    intro ys lengthEq _
    cases ys <;> simp_all
  | cons x xs ih =>
    intro ys lengthEq packedEq
    cases ys with
    | nil => simp_all
    | cons y ys =>
      have xb := x.isLt
      have yb := y.isLt
      simp only [packBytes] at packedEq
      have headEq : x.val = y.val := by omega
      have tailEq : packBytes xs = packBytes ys := by omega
      have lengthTail : xs.length = ys.length := by simpa using lengthEq
      have heads : x = y := Fin.ext headEq
      cases heads
      rw [ih ys lengthTail tailEq]

theorem packed_bytes_below_capacity (xs : List (Fin 256)) :
    packBytes xs < 256 ^ xs.length := by
  induction xs with
  | nil => simp [packBytes]
  | cons x xs ih =>
    have bound := x.isLt
    simp only [packBytes, List.length_cons, Nat.pow_succ]
    omega

def scalarModulus : Nat :=
  52435875175126190479447740508185965837690552500527637822603658699938581184513

theorem packing_capacity : 256^31 < scalarModulus := by decide

theorem pack_mod_injective (xs ys : List (Fin 256)) (p : Nat)
    (sameLength : xs.length = ys.length)
    (xBound : packBytes xs < p) (yBound : packBytes ys < p)
    (encodedEqual : packBytes xs % p = packBytes ys % p) : xs = ys := by
  rw [Nat.mod_eq_of_lt xBound, Nat.mod_eq_of_lt yBound] at encodedEqual
  exact pack_bytes_injective xs ys sameLength encodedEqual

/- The following are algebraic lemmas for the R1CS/prover construction.
   They do not assume or assert discrete-log hardness or implementation
   correctness of the external curve library. -/
theorem r1cs_boolean_sound {F : Type} [Lean.Grind.Field F] (s : F)
    (constraint : s * (s - 1) = 0) : s = 0 ∨ s = 1 := by
  rcases Lean.Grind.Field.of_mul_eq_zero constraint with left | right
  · exact Or.inl left
  · right
    grind

theorem r1cs_select_sound {F : Type} [Lean.Grind.Field F]
    (s yes no output : F) (bit : s * (s - 1) = 0)
    (selection : output = no + s * (yes - no)) :
    (s = 0 ∧ output = no) ∨ (s = 1 ∧ output = yes) := by
  rcases r1cs_boolean_sound s bit with zero | one <;> grind

theorem groth16_exponent_completeness {F : Type} [Lean.Grind.CommRing F]
    (alpha beta gamma delta a b c publicTerm privateTerm quotient r s : F)
    (keyRelation : gamma * publicTerm + delta * privateTerm = beta * a + alpha * b + c)
    (qap : delta * quotient = a * b - c) :
    let proofA := alpha + a + r * delta
    let proofB := beta + b + s * delta
    let proofC := privateTerm + quotient + s * proofA + r * proofB - r * s * delta
    proofA * proofB = alpha * beta + gamma * publicTerm + delta * proofC := by
  grind

#print axioms step_safe
#print axioms program_safe
#print axioms admitted_program_has_one_result
#print axioms materialize_constant_correct
#print axioms constant_leb_roundtrip
#print axioms r1cs_boolean_sound
#print axioms groth16_exponent_completeness
#print axioms carry64_correct
#print axioms borrow64_correct
#print axioms pack_mod_injective

end ZkBuild
