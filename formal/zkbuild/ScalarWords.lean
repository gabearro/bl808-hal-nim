import ScalarEncoding

/- Native-word packing used between the canonical scalar gate and the
   pinned field ABI. These proofs cover both RV32 and 64-bit word layouts. -/
namespace ZkBuild.ScalarWords

open ScalarEncoding

def horner : List (Fin 256) → Nat → Nat
  | [], value => value
  | byte :: rest, value => horner rest (value*256+byte.val)

def machineRead (bits : Nat) : List (Fin 256) → BitVec bits → BitVec bits
  | [], value => value
  | byte :: rest, value => machineRead bits rest ((value <<< 8) + BitVec.ofNat bits byte.val)

def wordIndices (wordBytes : Nat) : List (List Nat) :=
  (List.range (32/wordBytes)).map fun word =>
    (List.range wordBytes).map fun byte => 32-(word+1)*wordBytes+byte

def chunks (wordBytes : Nat) (bytes : Nat → Fin 256) : List (List (Fin 256)) :=
  (wordIndices wordBytes).map fun indices => indices.map bytes

def words (wordBytes : Nat) (bytes : Nat → Fin 256) : List (BitVec (8*wordBytes)) :=
  (chunks wordBytes bytes).map fun chunk => machineRead (8*wordBytes) chunk 0

def recombine (base : Nat) : List Nat → Nat
  | [] => 0
  | word :: rest => word + base * recombine base rest

theorem pack_append (left right : List (Fin 256)) :
    packBytes (left ++ right) = packBytes left + 256^left.length * packBytes right := by
  induction left with
  | nil => simp [packBytes]
  | cons first rest ih =>
    simp only [List.cons_append, packBytes, ih, List.length_cons, Nat.pow_succ]
    simp [Nat.mul_add, Nat.mul_assoc, Nat.mul_comm, Nat.add_assoc]

theorem value_cons (byte : Fin 256) (rest : List (Fin 256)) :
    valueBE (byte :: rest) = byte.val*256^rest.length + valueBE rest := by
  simp only [valueBE, List.reverse_cons, pack_append, List.length_reverse,
    packBytes, Nat.mul_zero, Nat.add_zero]
  simp [Nat.mul_comm, Nat.add_comm]

theorem horner_spec (bytes : List (Fin 256)) (value : Nat) :
    horner bytes value = value*256^bytes.length + valueBE bytes := by
  induction bytes generalizing value with
  | nil => simp [horner, valueBE, packBytes]
  | cons byte rest ih =>
    rw [horner, ih, value_cons]
    simp [Nat.pow_succ, Nat.add_mul, Nat.mul_assoc, Nat.mul_comm, Nat.add_assoc]

theorem machine_of_nat (bits : Nat) (bytes : List (Fin 256)) (value : Nat) :
    machineRead bits bytes (BitVec.ofNat bits value) = BitVec.ofNat bits (horner bytes value) := by
  have radix : BitVec.twoPow bits 8 = BitVec.ofNat bits 256 := by
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_twoPow, BitVec.toNat_ofNat]
  induction bytes generalizing value with
  | nil => rfl
  | cons byte rest ih =>
    rw [machineRead, BitVec.shiftLeft_eq_mul_twoPow, radix, ← BitVec.ofNat_mul, ← BitVec.ofNat_add]
    exact ih _

theorem machine_exact (wordBytes : Nat) (bytes : List (Fin 256)) (length : bytes.length = wordBytes) :
    (machineRead (8*wordBytes) bytes 0).toNat = valueBE bytes := by
  have bound : valueBE bytes < 2^(8*wordBytes) := by
    have below := packed_bytes_below_capacity bytes.reverse
    simpa only [valueBE, List.length_reverse, length, Nat.pow_mul] using below
  have result := machine_of_nat (8*wordBytes) bytes 0
  simp only [horner_spec, Nat.zero_mul, Nat.zero_add] at result
  change (machineRead (8*wordBytes) bytes (BitVec.ofNat (8*wordBytes) 0)).toNat = _
  rw [result, BitVec.toNat_ofNat, Nat.mod_eq_of_lt bound]

theorem recombine_chunks (wordBytes : Nat) (parts : List (List (Fin 256)))
    (lengths : ∀ part ∈ parts, part.length = wordBytes) :
    recombine (256^wordBytes) (parts.map packBytes) = packBytes parts.flatten := by
  induction parts with
  | nil => rfl
  | cons first rest ih =>
    have headLength := lengths first (by simp)
    have tailLengths : ∀ part ∈ rest, part.length = wordBytes := fun part member => lengths part (by simp [member])
    simp only [List.map_cons, recombine, List.flatten_cons, pack_append, headLength, ih tailLengths]

theorem chunk_lengths (wordBytes : Nat) (bytes : Nat → Fin 256) :
    ∀ chunk ∈ chunks wordBytes bytes, chunk.length = wordBytes := by
  intro chunk member
  obtain ⟨indices, included, rfl⟩ := List.mem_map.mp member
  obtain ⟨word, _, rfl⟩ := List.mem_map.mp included
  simp

theorem word_count (wordBytes : Nat) (bytes : Nat → Fin 256) :
    (words wordBytes bytes).length = 32/wordBytes := by
  simp [words, chunks, wordIndices]

theorem source_index_safe (wordBytes word byte : Nat) (width : wordBytes = 4 ∨ wordBytes = 8)
    (wordBound : word < 32/wordBytes) (byteBound : byte < wordBytes) :
    (word+1)*wordBytes ≤ 32 ∧ 32-(word+1)*wordBytes+byte < 32 := by
  rcases width with rfl | rfl <;> omega

theorem indices_32 : (wordIndices 4 |>.map List.reverse).flatten = (List.range 32).reverse := by decide
theorem indices_64 : (wordIndices 8 |>.map List.reverse).flatten = (List.range 32).reverse := by decide

theorem flattened_chunks (wordBytes : Nat) (bytes : Nat → Fin 256)
    (layout : (wordIndices wordBytes |>.map List.reverse).flatten = (List.range 32).reverse) :
    (chunks wordBytes bytes |>.map List.reverse).flatten = ((List.range 32).map bytes).reverse := by
  have mapped := congrArg (List.map bytes) layout
  simpa only [List.map_flatten, List.map_map, Function.comp_def, List.map_reverse, chunks] using mapped

theorem words_exact (wordBytes : Nat) (bytes : Nat → Fin 256) :
    (words wordBytes bytes).map BitVec.toNat = (chunks wordBytes bytes).map valueBE := by
  simp only [words, List.map_map, Function.comp_def]
  apply List.map_congr_left
  intro chunk member
  exact machine_exact wordBytes chunk (chunk_lengths wordBytes bytes chunk member)

theorem packing_exact (wordBytes : Nat) (bytes : Nat → Fin 256)
    (layout : (wordIndices wordBytes |>.map List.reverse).flatten = (List.range 32).reverse) :
    recombine (256^wordBytes) ((words wordBytes bytes).map BitVec.toNat) =
      valueBE ((List.range 32).map bytes) := by
  rw [words_exact]
  have lengths : ∀ part ∈ ((chunks wordBytes bytes).map List.reverse), part.length = wordBytes := by
    intro part member
    obtain ⟨chunk, included, rfl⟩ := List.mem_map.mp member
    simpa only [List.length_reverse] using chunk_lengths wordBytes bytes chunk included
  have joined := recombine_chunks wordBytes ((chunks wordBytes bytes).map List.reverse) lengths
  rw [flattened_chunks wordBytes bytes layout] at joined
  change recombine (256^wordBytes) ((chunks wordBytes bytes).map (fun part => packBytes part.reverse)) =
    packBytes (((List.range 32).map bytes).reverse)
  simpa only [List.map_map, Function.comp_def] using joined

theorem packing_32 (bytes : Nat → Fin 256) :
    recombine (2^32) ((words 4 bytes).map BitVec.toNat) = valueBE ((List.range 32).map bytes) := by
  exact packing_exact 4 bytes indices_32

theorem packing_64 (bytes : Nat → Fin 256) :
    recombine (2^64) ((words 8 bytes).map BitVec.toNat) = valueBE ((List.range 32).map bytes) := by
  exact packing_exact 8 bytes indices_64

theorem canonical_32_fits (bytes : Nat → Fin 256)
    (accepted : canonical ((List.range 32).map bytes) = true) :
    recombine (2^32) ((words 4 bytes).map BitVec.toNat) < 2^255 := by
  rw [packing_32]
  exact canonical_fits _ accepted

theorem canonical_64_fits (bytes : Nat → Fin 256)
    (accepted : canonical ((List.range 32).map bytes) = true) :
    recombine (2^64) ((words 8 bytes).map BitVec.toNat) < 2^255 := by
  rw [packing_64]
  exact canonical_fits _ accepted

#print axioms machine_exact
#print axioms packing_32
#print axioms packing_64

end ZkBuild.ScalarWords
