import ZkBuild

namespace ZkBuild.R1CS

open Lean.Grind
attribute [local instance] Semiring.natCast

structure Term (F : Type) where
  wire : Nat
  coefficient : F

abbrev Linear (F : Type) := List (Term F)

def eval {F : Type} [CommRing F] (values : Nat → F) : Linear F → F
  | [] => 0
  | term :: rest => term.coefficient * values term.wire + eval values rest

def wire {F : Type} [CommRing F] (i : Nat) : Linear F := [⟨i, 1⟩]
def constant {F : Type} (value : F) : Linear F := [⟨0, value⟩]
def scale {F : Type} [CommRing F] (a : F) (linear : Linear F) : Linear F :=
  linear.map (fun term => ⟨term.wire, term.coefficient * a⟩)

theorem eval_wire {F : Type} [CommRing F] (values : Nat → F) (i : Nat) :
    eval values (wire i) = values i := by
  simp [eval, wire, Semiring.one_mul, Semiring.add_zero]

theorem eval_constant {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (a : F) : eval values (constant a) = a := by
  simp [eval, constant, one, Semiring.mul_one, Semiring.add_zero]

theorem eval_append {F : Type} [CommRing F] (values : Nat → F) (a b : Linear F) :
    eval values (a ++ b) = eval values a + eval values b := by
  induction a with
  | nil => simp only [List.nil_append, eval]; grind
  | cons term rest ih => simp [eval, ih, Semiring.add_assoc]

theorem eval_scale {F : Type} [CommRing F] (values : Nat → F) (a : F) (linear : Linear F) :
    eval values (scale a linear) = a * eval values linear := by
  induction linear with
  | nil => simp [scale, eval, Semiring.mul_zero]
  | cons term rest ih =>
    simp only [scale, List.map_cons, eval] at *
    grind

structure Constraint (F : Type) where
  a : Linear F
  b : Linear F
  c : Linear F

def Holds {F : Type} [CommRing F] (values : Nat → F) (gate : Constraint F) : Prop :=
  eval values gate.a * eval values gate.b = eval values gate.c

theorem multiplication_gate_sound {F : Type} [CommRing F] (values : Nat → F)
    (a b : Linear F) (output : Nat)
    (ok : Holds values ⟨a, b, wire output⟩) :
    values output = eval values a * eval values b := by
  simpa [Holds, eval_wire] using ok.symm

theorem equality_gate_sound {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (a b : Linear F)
    (ok : Holds values ⟨a ++ scale (-1) b, constant 1, constant 0⟩) :
    eval values a = eval values b := by
  simp only [Holds, eval_append, eval_scale, eval_constant values one] at ok
  grind

theorem boolean_gate_sound {F : Type} [Field F] (values : Nat → F)
    (one : values 0 = 1) (output : Nat)
    (ok : Holds values ⟨wire output, wire output ++ scale (-1) (constant 1), constant 0⟩) :
    values output = 0 ∨ values output = 1 := by
  simp only [Holds, eval_append, eval_wire, eval_scale, eval_constant values one] at ok
  apply r1cs_boolean_sound
  grind

def countTrue : List Bool → Nat
  | [] => 0
  | bit :: rest => bit.toNat + countTrue rest

def boolValue {F : Type} [CommRing F] (bit : Bool) : F := if bit then 1 else 0
def sum {F : Type} [CommRing F] : List F → F
  | [] => 0
  | value :: rest => value + sum rest

theorem countTrue_bound (bits : List Bool) : countTrue bits ≤ bits.length := by
  induction bits with
  | nil => simp [countTrue]
  | cons bit rest ih => cases bit <;> simp [countTrue] <;> omega

theorem bool_sum_count {F : Type} [CommRing F] (bits : List Bool) :
    sum (bits.map (boolValue (F := F))) = (countTrue bits : F) := by
  induction bits with
  | nil => simp [sum, countTrue, Semiring.natCast_zero]
  | cons bit rest ih =>
    cases bit <;>
      simp only [List.map_cons, boolValue, sum, countTrue, Bool.toNat,
        ih, Semiring.natCast_add] <;> grind

theorem constrained_bits_are_booleans {F : Type} [Field F] (values : List F)
    (bits : ∀ value ∈ values, value * (value - 1) = 0) :
    ∃ decoded : List Bool, values = decoded.map boolValue := by
  induction values with
  | nil => exact ⟨[], rfl⟩
  | cons value rest ih =>
    have head := bits value (by simp)
    obtain ⟨decoded, tail⟩ := ih (by intro x hx; exact bits x (by simp [hx]))
    rcases r1cs_boolean_sound value head with zero | one
    · refine ⟨false :: decoded, ?_⟩
      simp [List.map_cons, boolValue, zero, tail]
    · refine ⟨true :: decoded, ?_⟩
      simp [List.map_cons, boolValue, one, tail]

theorem selector_count_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (expected : Fin 2) (length : values.length ≤ 10)
    (bits : ∀ value ∈ values, value * (value - 1) = 0)
    (total : sum values = (expected.val : F)) :
    ∃ decoded : List Bool, values = decoded.map boolValue ∧ countTrue decoded = expected.val := by
  obtain ⟨decoded, same⟩ := constrained_bits_are_booleans values bits
  have countBound := countTrue_bound decoded
  have lenBound : decoded.length ≤ 10 := by simpa [same] using length
  have modulusLarge : 10 < scalarModulus := by decide
  have countSmall : countTrue decoded < scalarModulus := by omega
  have expectedSmall : expected.val < scalarModulus := by have := expected.isLt; omega
  have fieldEq : (countTrue decoded : F) = (expected.val : F) := by
    simpa [same, bool_sum_count] using total
  have countEq := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus countSmall expectedSmall).mp fieldEq
  exact ⟨decoded, same, countEq⟩

def weightedValues {F : Type} [CommRing F] : List Nat → List F → F
  | code :: codes, value :: values => value * (code : F) + weightedValues codes values
  | _, _ => 0

def selectedCode : List Nat → List Bool → Nat
  | code :: codes, bit :: bits => (if bit then code else 0) + selectedCode codes bits
  | _, _ => 0

theorem weighted_booleans {F : Type} [CommRing F] (codes : List Nat) (bits : List Bool) :
    weightedValues codes (bits.map (boolValue (F := F))) = (selectedCode codes bits : F) := by
  induction codes generalizing bits with
  | nil => simp [weightedValues, selectedCode, Semiring.natCast_zero]
  | cons code codes ih =>
    cases bits with
    | nil => simp [weightedValues, selectedCode, Semiring.natCast_zero]
    | cons bit bits =>
      cases bit <;>
        simp [weightedValues, selectedCode, boolValue, ih, Semiring.natCast_add,
          Semiring.zero_mul, Semiring.one_mul] <;> grind

theorem selectedCode_zero (codes : List Nat) (bits : List Bool)
    (zero : countTrue bits = 0) : selectedCode codes bits = 0 := by
  induction codes generalizing bits with
  | nil => rfl
  | cons code codes ih =>
    cases bits with
    | nil => rfl
    | cons bit bits =>
      cases bit <;> simp [countTrue] at zero
      simp [selectedCode, ih bits zero]

theorem selectedCode_one (codes : List Nat) (bits : List Bool)
    (sameLength : codes.length = bits.length) (one : countTrue bits = 1) :
    selectedCode codes bits ∈ codes := by
  induction codes generalizing bits with
  | nil => cases bits <;> simp_all [countTrue]
  | cons code codes ih =>
    cases bits with
    | nil => simp [countTrue] at one
    | cons bit bits =>
      have tailLength : codes.length = bits.length := by simpa using sameLength
      cases bit with
      | false =>
        have tailOne : countTrue bits = 1 := by simpa [countTrue] using one
        simpa [selectedCode] using List.mem_cons_of_mem code (ih bits tailLength tailOne)
      | true =>
        have tailZero : countTrue bits = 0 := by simp [countTrue] at one; omega
        simp [selectedCode, selectedCode_zero codes bits tailZero]

theorem zero_selection_unique (codes : List Nat) (bits : List Bool) (target : Nat)
    (sameLength : codes.length = bits.length) (zero : countTrue bits = 0)
    (absent : target ∉ codes) :
    bits = codes.map (fun code => decide (code = target)) := by
  induction codes generalizing bits with
  | nil => cases bits <;> simp_all
  | cons code codes ih =>
    cases bits with
    | nil => simp at sameLength
    | cons bit bits =>
      have tailLength : codes.length = bits.length := by simpa using sameLength
      have headNe : code ≠ target := by intro h; apply absent; simp [h]
      have tailAbsent : target ∉ codes := by intro h; apply absent; simp [h]
      cases bit with
      | false =>
        have tailZero : countTrue bits = 0 := by simpa [countTrue] using zero
        simp [headNe, ih bits tailLength tailZero tailAbsent]
      | true => simp [countTrue] at zero

theorem one_selection_unique (codes : List Nat) (bits : List Bool) (target : Nat)
    (sameLength : codes.length = bits.length) (unique : codes.Nodup)
    (one : countTrue bits = 1) (binding : selectedCode codes bits = target) :
    bits = codes.map (fun code => decide (code = target)) := by
  induction codes generalizing bits with
  | nil => cases bits <;> simp_all [countTrue]
  | cons code codes ih =>
    cases bits with
    | nil => simp [countTrue] at one
    | cons bit bits =>
      have tailLength : codes.length = bits.length := by simpa using sameLength
      have nodup : code ∉ codes ∧ codes.Nodup := List.nodup_cons.mp unique
      cases bit with
      | false =>
        have tailOne : countTrue bits = 1 := by simpa [countTrue] using one
        have tailBinding : selectedCode codes bits = target := by simpa [selectedCode] using binding
        have present : target ∈ codes := by simpa [tailBinding] using selectedCode_one codes bits tailLength tailOne
        have headNe : code ≠ target := by intro h; apply nodup.1; simpa [h] using present
        simp [headNe, ih bits tailLength nodup.2 tailOne tailBinding]
      | true =>
        have tailZero : countTrue bits = 0 := by simp [countTrue] at one; omega
        have headEq : code = target := by simpa [selectedCode, selectedCode_zero codes bits tailZero] using binding
        have tailAbsent : target ∉ codes := by simpa [headEq] using nodup.1
        simp [headEq, zero_selection_unique codes bits target tailLength tailZero tailAbsent]

-- This is a field-valued soundness statement, not enumeration of honest
-- witnesses: arbitrary selector values satisfying the actual Boolean and
-- sum constraints must select an allowed opcode, without modular aliasing.
theorem opcode_selection_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (codes : List Nat) (byte : Fin 256)
    (sameLength : codes.length = values.length) (length : values.length ≤ 10)
    (smallCodes : ∀ code ∈ codes, code < 256)
    (bits : ∀ value ∈ values, value * (value - 1) = 0)
    (total : sum values = 1)
    (binding : weightedValues codes values = (byte.val : F)) :
    byte.val ∈ codes := by
  have total' : sum values = ((1 : Fin 2).val : F) := by simpa [Semiring.natCast_one] using total
  obtain ⟨decoded, same, count⟩ := selector_count_sound values (1 : Fin 2) length bits total'
  have decodedLength : codes.length = decoded.length := by simpa [same] using sameLength
  have selected := selectedCode_one codes decoded decodedLength count
  have selectedSmall : selectedCode codes decoded < scalarModulus := by
    have := smallCodes _ selected
    have : 256 < scalarModulus := by decide
    omega
  have byteSmall : byte.val < scalarModulus := by
    have := byte.isLt
    have : 256 < scalarModulus := by decide
    omega
  have fieldEq : (selectedCode codes decoded : F) = (byte.val : F) := by
    simpa [same, weighted_booleans] using binding
  have eq := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus selectedSmall byteSmall).mp fieldEq
  simpa [eq] using selected

theorem opcode_selectors_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (codes : List Nat) (byte : Fin 256)
    (sameLength : codes.length = values.length) (length : values.length ≤ 10)
    (unique : codes.Nodup) (smallCodes : ∀ code ∈ codes, code < 256)
    (bits : ∀ value ∈ values, value * (value - 1) = 0)
    (total : sum values = 1)
    (binding : weightedValues codes values = (byte.val : F)) :
    values = (codes.map fun code => decide (code = byte.val)).map boolValue := by
  have total' : sum values = ((1 : Fin 2).val : F) := by simpa [Semiring.natCast_one] using total
  obtain ⟨decoded, same, count⟩ := selector_count_sound values (1 : Fin 2) length bits total'
  have decodedLength : codes.length = decoded.length := by simpa [same] using sameLength
  have present := selectedCode_one codes decoded decodedLength count
  have pickedBound : selectedCode codes decoded < scalarModulus := by
    have := smallCodes _ present
    have : 256 < scalarModulus := by decide
    omega
  have byteBound : byte.val < scalarModulus := by
    have := byte.isLt
    have : 256 < scalarModulus := by decide
    omega
  have fieldEq : (selectedCode codes decoded : F) = (byte.val : F) := by
    simpa [same, weighted_booleans] using binding
  have pickedEq := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus pickedBound byteBound).mp fieldEq
  have exactBits := one_selection_unique codes decoded byte.val decodedLength unique count pickedEq
  simpa [exactBits] using same

theorem zero_count_all_zero {F : Type} [CommRing F] (bits : List Bool)
    (zero : countTrue bits = 0) :
    bits.map (boolValue (F := F)) = List.replicate bits.length 0 := by
  induction bits with
  | nil => rfl
  | cons bit bits ih =>
    cases bit with
    | false =>
      have tail : countTrue bits = 0 := by simpa [countTrue] using zero
      simp [boolValue, ih tail, List.replicate_succ]
    | true => simp [countTrue] at zero

theorem zero_sum_selectors_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (length : values.length ≤ 10)
    (bits : ∀ value ∈ values, value * (value - 1) = 0) (total : sum values = 0) :
    values = List.replicate values.length 0 := by
  have total' : sum values = ((0 : Fin 2).val : F) := by simpa [Semiring.natCast_zero] using total
  obtain ⟨decoded, same, count⟩ := selector_count_sound values (0 : Fin 2) length bits total'
  simpa [same] using zero_count_all_zero (F := F) decoded count

theorem row_selectors_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : List F) (codes : List Nat) (byte : Fin 256) (ready : F)
    (readyBit : ready = 0 ∨ ready = 1)
    (aLength : codes.length = a.length) (bLength : codes.length = b.length)
    (length : codes.length ≤ 10) (unique : codes.Nodup)
    (smallCodes : ∀ code ∈ codes, code < 256)
    (aBits : ∀ value ∈ a, value * (value - 1) = 0)
    (bBits : ∀ value ∈ b, value * (value - 1) = 0)
    (aTotal : sum a = ready) (bTotal : sum b = ready)
    (aBinding : weightedValues codes a = ready * (byte.val : F))
    (bBinding : weightedValues codes b = ready * (byte.val : F)) : a = b := by
  rcases readyBit with zero | one
  · have aZero := zero_sum_selectors_determined a (by omega) aBits (by simpa [zero] using aTotal)
    have bZero := zero_sum_selectors_determined b (by omega) bBits (by simpa [zero] using bTotal)
    rw [aZero, bZero, ← aLength, ← bLength]
  · have aExact := opcode_selectors_determined a codes byte aLength (by omega) unique smallCodes
      aBits (by simpa [one] using aTotal) (by simpa [one, Semiring.one_mul] using aBinding)
    have bExact := opcode_selectors_determined b codes byte bLength (by omega) unique smallCodes
      bBits (by simpa [one] using bTotal) (by simpa [one, Semiring.one_mul] using bBinding)
    rw [aExact, bExact]

-- The optimized Nim row computes the finished phase as the residual after
-- other next phases, saving a materialization and a redundant phase-sum gate.
-- These are precisely the selector, prior-phase and fifth-LEB hypotheses of
-- appendByteRow. The identity holds for arbitrary field values.
theorem phase_residual_done {F : Type} [Field F]
    (ready index done leb continuation nop get constOp binary endOp : F)
    (lastLeb : F)
    (phaseSum : ready + index + leb + done = 1)
    (selectorSum : nop + get + constOp + binary + endOp = ready)
    (lastStops : lastLeb * continuation = 0) :
    1 - (nop + binary + index + leb * (1 - continuation)) - get -
      (constOp + (leb - lastLeb) * continuation) = done + endOp := by
  grind

def packedField {F : Type} [CommRing F] : List (Fin 256) → F
  | [] => 0
  | byte :: rest => (byte.val : F) + (256 : F) * packedField rest

theorem packedField_is_natCast {F : Type} [CommRing F] (bytes : List (Fin 256)) :
    packedField (F := F) bytes = (packBytes bytes : F) := by
  induction bytes with
  | nil => simp [packedField, packBytes, Semiring.natCast_zero]
  | cons byte rest ih =>
    simp only [packedField, packBytes, ih, Semiring.natCast_add, Semiring.natCast_mul]
    grind

theorem bounded_packing_no_wrap (bytes : List (Fin 256)) (length : bytes.length ≤ 31) :
    packBytes bytes < scalarModulus := by
  have capacity := packed_bytes_below_capacity bytes
  have limit := Nat.pow_le_pow_right (n := 256) (by decide) length
  have modulus := packing_capacity
  omega

theorem packed_field_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Fin 256)) (sameLength : a.length = b.length) (length : a.length ≤ 31)
    (binding : packedField (F := F) a = packedField (F := F) b) : a = b := by
  have aBound := bounded_packing_no_wrap a length
  have bBound := bounded_packing_no_wrap b (by simpa [← sameLength] using length)
  rw [packedField_is_natCast, packedField_is_natCast] at binding
  have equal := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp binding
  exact pack_bytes_injective a b sameLength equal

#print axioms multiplication_gate_sound
#print axioms equality_gate_sound
#print axioms boolean_gate_sound
#print axioms selector_count_sound
#print axioms opcode_selection_sound
#print axioms opcode_selectors_determined
#print axioms row_selectors_unique
#print axioms phase_residual_done
#print axioms packed_field_injective

end ZkBuild.R1CS
