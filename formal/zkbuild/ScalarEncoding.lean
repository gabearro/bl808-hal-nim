import R1CS

/- Canonical 32-byte scalar encodings. A fixed-width subtraction borrow
   decides strict comparison without a data-dependent early return. -/
namespace ZkBuild.ScalarEncoding

open Lean.Grind
attribute [local instance] Ring.intCast Semiring.natCast

def modulusBytes : List (Fin 256) := [
  0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
  0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
  0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
  0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01]

def valueBE (bytes : List (Fin 256)) : Nat := packBytes bytes.reverse
def wideDifference (a b : Fin 256) (incoming : Nat) : Nat := 256+a.val-b.val-incoming
def borrowDigit (a b : Fin 256) (incoming : Nat) : Nat := 1-wideDifference a b incoming/256

def subtractBorrow : List (Fin 256) → List (Fin 256) → Nat → Nat
  | [], [], incoming => incoming
  | a :: rest, b :: other, incoming => subtractBorrow rest other (borrowDigit a b incoming)
  | _, _, _ => 0

def borrowBE (a b : List (Fin 256)) : Nat := subtractBorrow a.reverse b.reverse 0
def canonical (bytes : List (Fin 256)) : Bool :=
  decide (bytes.length = 32) && decide (borrowBE bytes modulusBytes = 1)

theorem wide_bounds (a b : Fin 256) (incoming : Nat) (bound : incoming ≤ 1) :
    b.val+incoming ≤ 256+a.val ∧ wideDifference a b incoming < 512 := by
  have := a.isLt
  have := b.isLt
  unfold wideDifference
  omega

theorem borrow_case (a b : Fin 256) (incoming : Nat) (bound : incoming ≤ 1) :
    borrowDigit a b incoming = if a.val < b.val+incoming then 1 else 0 := by
  have := a.isLt
  have := b.isLt
  unfold borrowDigit wideDifference
  split <;> omega

theorem borrow_bound (a b : Fin 256) (incoming : Nat) (bound : incoming ≤ 1) :
    borrowDigit a b incoming ≤ 1 := by
  rw [borrow_case a b incoming bound]
  split <;> omega

theorem digit_comparison (a b : Fin 256) (incoming upperA upperB : Nat) (bound : incoming ≤ 1) :
    upperA < upperB + borrowDigit a b incoming ↔
      a.val+256*upperA < b.val+256*upperB+incoming := by
  have := a.isLt
  have := b.isLt
  rw [borrow_case a b incoming bound]
  split <;> omega

theorem subtract_bounded (a : List (Fin 256)) : ∀ b incoming, a.length = b.length → incoming ≤ 1 →
    subtractBorrow a b incoming ≤ 1 := by
  induction a with
  | nil =>
    intro b incoming length bound
    cases b with
    | nil => exact bound
    | cons _ _ => simp at length
  | cons a rest ih =>
    intro b incoming length bound
    cases b with
    | nil => simp at length
    | cons b other =>
      exact ih other (borrowDigit a b incoming) (by simpa using length) (borrow_bound a b incoming bound)

theorem subtract_correct (a : List (Fin 256)) : ∀ b incoming, a.length = b.length → incoming ≤ 1 →
    (subtractBorrow a b incoming = 1 ↔ packBytes a < packBytes b + incoming) := by
  induction a with
  | nil =>
    intro b incoming length bound
    cases b with
    | nil => simp only [subtractBorrow, packBytes]; omega
    | cons _ _ => simp at length
  | cons a rest ih =>
    intro b incoming length bound
    cases b with
    | nil => simp at length
    | cons b other =>
      rw [subtractBorrow, ih other (borrowDigit a b incoming) (by simpa using length) (borrow_bound a b incoming bound)]
      exact digit_comparison a b incoming (packBytes rest) (packBytes other) bound

def wordStep (a b : Fin 256) (incoming : Fin 2) : BitVec 16 :=
  1#16 - ((256#16 + BitVec.ofNat 16 a.val - BitVec.ofNat 16 b.val - BitVec.ofNat 16 incoming.val) >>> 8)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem word_step_certificate : ∀ (a b : Fin 256) (incoming : Fin 2),
    (wordStep a b incoming).toNat = borrowDigit a b incoming.val := by native_decide

theorem modulus_length : modulusBytes.length = 32 := by decide
theorem modulus_value : valueBE modulusBytes = scalarModulus := by decide
theorem modulus_fits_255 : scalarModulus < 2^255 := by decide

theorem canonical_iff (bytes : List (Fin 256)) : canonical bytes = true ↔
    bytes.length = 32 ∧ valueBE bytes < scalarModulus := by
  by_cases length : bytes.length = 32
  · have same : bytes.reverse.length = modulusBytes.reverse.length := by simp [length, modulus_length]
    have correct := subtract_correct bytes.reverse modulusBytes.reverse 0 same (by decide)
    have compared : borrowBE bytes modulusBytes = 1 ↔ valueBE bytes < scalarModulus := by
      change borrowBE bytes modulusBytes = 1 ↔ valueBE bytes < valueBE modulusBytes + 0 at correct
      simpa only [modulus_value, Nat.add_zero] using correct
    simp [canonical, length, compared]
  · simp [canonical, length]

theorem canonical_fits (bytes : List (Fin 256)) (accepted : canonical bytes = true) : valueBE bytes < 2^255 :=
  Nat.lt_trans ((canonical_iff bytes).mp accepted).2 modulus_fits_255

def littleEndian : Nat → Nat → List (Fin 256)
  | 0, _ => []
  | width+1, value => ⟨value%256, Nat.mod_lt _ (by decide)⟩ :: littleEndian width (value/256)

def encode (value : Nat) : List (Fin 256) := (littleEndian 32 value).reverse

theorem little_endian_length (width value : Nat) : (littleEndian width value).length = width := by
  induction width generalizing value with
  | zero => rfl
  | succ width ih => simp [littleEndian, ih]

theorem little_endian_value (width : Nat) : ∀ value, value < 256^width → packBytes (littleEndian width value) = value := by
  induction width with
  | zero =>
    intro value bound
    have zero : value = 0 := by simpa using bound
    simp [littleEndian, packBytes, zero]
  | succ width ih =>
    intro value bound
    have smaller : value/256 < 256^width := by
      apply (Nat.div_lt_iff_lt_mul (by decide)).mpr
      simpa only [Nat.pow_succ] using bound
    rw [littleEndian, packBytes, ih (value/256) smaller]
    exact Nat.mod_add_div value 256

theorem encode_length (value : Nat) : (encode value).length = 32 := by
  simp [encode, little_endian_length]

theorem encode_value (value : Nat) (bound : value < scalarModulus) : valueBE (encode value) = value := by
  have capacity : scalarModulus < 256^32 := by decide
  simp only [encode, valueBE, List.reverse_reverse]
  exact little_endian_value 32 value (Nat.lt_trans bound capacity)

theorem encoded_canonical (value : Nat) (bound : value < scalarModulus) : canonical (encode value) = true := by
  apply (canonical_iff _).mpr
  exact ⟨encode_length value, by rw [encode_value value bound]; exact bound⟩

theorem canonical_roundtrip (bytes : List (Fin 256)) (accepted : canonical bytes = true) :
    encode (valueBE bytes) = bytes := by
  have bounds := (canonical_iff bytes).mp accepted
  have values : packBytes (encode (valueBE bytes)).reverse = packBytes bytes.reverse :=
    encode_value _ bounds.2
  have same := pack_bytes_injective (encode (valueBE bytes)).reverse bytes.reverse
    (by simp [encode_length, bounds.1]) values
  simpa using congrArg List.reverse same

theorem no_truncation (bytes : List (Fin 256)) (accepted : canonical bytes = true) :
    (BitVec.ofNat 255 (valueBE bytes)).toNat = valueBE bytes := by
  rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (canonical_fits bytes accepted)]

def decodeInto {F : Type} [CommRing F] (bytes : List (Fin 256)) (previous : F) : Bool × F :=
  if canonical bytes then (true, (valueBE bytes : F)) else (false, previous)

theorem decode_encoded {F : Type} [CommRing F] (value : Nat) (bound : value < scalarModulus) (previous : F) :
    decodeInto (encode value) previous = (true, (value : F)) := by
  simp [decodeInto, encoded_canonical value bound, encode_value value bound]

theorem decode_success {F : Type} [CommRing F] (bytes : List (Fin 256)) (previous : F)
    (accepted : (decodeInto bytes previous).1 = true) :
    bytes.length = 32 ∧ valueBE bytes < scalarModulus ∧
      (decodeInto bytes previous).2 = (valueBE bytes : F) := by
  cases decision : canonical bytes
  · simp [decodeInto, decision] at accepted
  · have canonical : canonical bytes = true := decision
    exact ⟨(canonical_iff bytes).mp canonical |>.1, (canonical_iff bytes).mp canonical |>.2,
      by simp [decodeInto, decision]⟩

theorem decode_failure {F : Type} [CommRing F] (bytes : List (Fin 256)) (previous : F)
    (rejected : (decodeInto bytes previous).1 = false) : (decodeInto bytes previous).2 = previous := by
  cases decision : canonical bytes
  · simp [decodeInto, decision]
  · simp [decodeInto, decision] at rejected

theorem canonical_unique {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Fin 256)) (acceptedA : canonical a = true) (acceptedB : canonical b = true)
    (same : (valueBE a : F) = (valueBE b : F)) : a = b := by
  have left := (canonical_iff a).mp acceptedA
  have right := (canonical_iff b).mp acceptedB
  have equal := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus left.2 right.2).mp same
  have reversed := pack_bytes_injective a.reverse b.reverse (by simp [left.1, right.1]) equal
  simpa using congrArg List.reverse reversed

#print axioms canonical_iff
#print axioms canonical_unique
#print axioms word_step_certificate
#print axioms no_truncation
#print axioms decode_failure
#print axioms encoded_canonical
#print axioms canonical_roundtrip
#print axioms decode_encoded

end ZkBuild.ScalarEncoding
