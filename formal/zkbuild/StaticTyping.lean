import WasmNumericTyping

/- Fixed signatures for the repository's raw opcode set. Class 8 accepts
   any stack tag, class 9 accepts reference tags. Input order is top-first. -/
namespace ZkBuild.StaticTyping

structure Rule where
  inputs : List Nat
  output : Option Nat
  clears : Bool := false
  deriving DecidableEq, Repr

def mk (inputs : List Nat) (output : Option Nat := none) (clears := false) : Option Rule :=
  some ⟨inputs, output, clears⟩

def other (code : Nat) : Option Rule :=
  if code = 0 then mk [] none true
  else if code = 1 then mk []
  else if code = 0x1a then mk [8]
  else if code = 0x28 ∨ 0x2c ≤ code ∧ code ≤ 0x2f then mk [0] (some 0)
  else if code = 0x29 ∨ 0x30 ≤ code ∧ code ≤ 0x35 then mk [0] (some 1)
  else if code = 0x2a then mk [0] (some 2)
  else if code = 0x2b then mk [0] (some 3)
  else if code = 0x36 ∨ code = 0x3a ∨ code = 0x3b then mk [0,0]
  else if code = 0x37 ∨ 0x3c ≤ code ∧ code ≤ 0x3e then mk [1,0]
  else if code = 0x38 then mk [2,0]
  else if code = 0x39 then mk [3,0]
  else if code = 0x3f ∨ code = 0x110 then mk [] (some 0)
  else if code = 0x40 then mk [0] (some 0)
  else if code = 0xd1 then mk [9] (some 0)
  else if code = 0xd2 then mk [] (some 5)
  else if code = 0x108 ∨ 0x10a ≤ code ∧ code ≤ 0x10c ∨ code = 0x10e then mk [0,0,0]
  else if code = 0x109 ∨ code = 0x10d then mk []
  else if code = 0x300 then mk [0] (some 4)
  else if code = 0x301 then mk [4,0]
  else if code = 0x302 then mk [] (some 4)
  else if 0x303 ≤ code ∧ code ≤ 0x305 then mk [0] (some 4)
  else if code = 0x306 then mk [1] (some 4)
  else if code = 0x307 then mk [2] (some 4)
  else if code = 0x308 then mk [3] (some 4)
  else if code = 0x309 ∨ code = 0x318 ∨ code = 0x319 ∨ code = 0x31b ∨ code = 0x31c then mk [4] (some 0)
  else if code = 0x30a ∨ code = 0x31a ∨ code = 0x31d ∨ 0x332 ≤ code ∧ code ≤ 0x334 then mk [0,4] (some 4)
  else if code = 0x30b then mk [4] (some 2)
  else if code = 0x30c then mk [2,4] (some 4)
  else if code = 0x30d ∨ 0x323 ≤ code ∧ code ≤ 0x324 ∨ 0x32b ≤ code ∧ code ≤ 0x32c ∨
      0x330 ≤ code ∧ code ≤ 0x331 ∨ 0x33b ≤ code ∧ code ≤ 0x33e then mk [4] (some 4)
  else if 0x30e ≤ code ∧ code ≤ 0x317 ∨ code = 0x322 ∨ 0x325 ≤ code ∧ code ≤ 0x32a ∨
      0x32d ≤ code ∧ code ≤ 0x32f ∨ 0x335 ≤ code ∧ code ≤ 0x33a ∨ 0x33f ≤ code ∧ code ≤ 0x342 then mk [4,4] (some 4)
  else if code = 0x31e then mk [4] (some 1)
  else if code = 0x31f then mk [1,4] (some 4)
  else if code = 0x320 then mk [4] (some 3)
  else if code = 0x321 then mk [3,4] (some 4)
  else none

def signature (code : Nat) : Option Rule :=
  match WasmNumericTyping.signature code with
  | some numeric => mk (List.replicate numeric.inputs numeric.inputType.val) (some numeric.outputType.val)
  | none => other code

def allowed (expected actual : Nat) : Prop :=
  actual < 8 ∧ (actual = 7 ∨ expected = 8 ∨ expected = 9 ∧ (actual = 5 ∨ actual = 6) ∨ actual = expected)

instance (expected actual : Nat) : Decidable (allowed expected actual) := by
  unfold allowed
  infer_instance

def popAllowed (rule : Rule) (index actual : Nat) : Bool :=
  match rule.inputs[index]? with
  | none => false
  | some expected => decide (allowed expected actual)

def validShape (rule : Rule) : Bool :=
  decide (rule.inputs.length ≤ 3) && rule.inputs.all (fun t => decide (t < 10)) &&
    (match rule.output with | none => true | some t => decide (t < 7)) &&
    (!rule.clears || decide (rule.inputs = [] ∧ rule.output = none))

set_option maxRecDepth 8192 in
theorem rule_shapes : ((List.range 2048).filterMap signature).all validShape = true := by decide

set_option maxRecDepth 8192 in
theorem rule_count : ((List.range 2048).filterMap signature).length = 245 := by decide

set_option maxRecDepth 4096 in
theorem simd_coverage : (List.range 67).all (fun i => (signature (0x300+i)).isSome) = true := by decide

theorem any_class (actual : Fin 8) : allowed 8 actual.val := by
  simp [allowed, actual.isLt]

theorem reference_class (actual : Fin 8) : allowed 9 actual.val ↔ actual.val = 5 ∨ actual.val = 6 ∨ actual.val = 7 := by
  simp [allowed, actual.isLt]
  omega

#print axioms rule_shapes
#print axioms rule_count
#print axioms simd_coverage

end ZkBuild.StaticTyping
