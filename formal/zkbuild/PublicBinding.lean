import BodySoundness

namespace ZkBuild.PublicBinding

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def chunkLength (chunk : Fin 6) : Nat := if chunk.val = 5 then 1 else 31

def chunkPosition (chunk : Fin 6) (offset : Fin (chunkLength chunk)) : Fin 156 :=
  ⟨chunk.val*31 + offset.val, by
    have c := chunk.isLt
    have o := offset.isLt
    unfold chunkLength at o
    split at o <;> omega⟩

def positions (chunk : Fin 6) : List (Fin 156) := List.ofFn (chunkPosition chunk)

def chunkBytes (bytes : Fin 156 → Fin 256) (chunk : Fin 6) : List (Fin 256) :=
  (positions chunk).map bytes

def byteLinear (position : Nat) : Linear :=
  (List.range 8).map fun bit => (8 + position*8 + bit, Int.ofNat (2^bit))

def packLinear : List Nat → Linear
  | [] => []
  | position :: rest => byteLinear position ++ scale (packLinear rest) 256

def packingGate (chunk : Fin 6) : Gate :=
  ⟨sub (packLinear ((positions chunk).map Fin.val)) [(2+chunk.val, 1)], constant 1, constant 0⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem packing_gates_match : ∀ chunk : Fin 6,
    (match byteShape.gates[1248+chunk.val]? with
    | none => false
    | some actual => sameGate (packingGate chunk) actual) = true := by native_decide

theorem byte_linear_value {F : Type} [CommRing F] (ctx : Lean.RArray F) (position : Fin 156) :
    evalLinear ctx.get (byteLinear position.val) =
      R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get position) := by
  simp [byteLinear, evalLinear, interpretLinear, R1CS.eval, List.range_succ,
    BitPacking.byte_weights_exact, R1CS.weightedValues, globalBits]
  grind

theorem packing_linear_value {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (bytes : Fin 156 → Fin 256)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (ps : List (Fin 156)) :
    evalLinear ctx.get (packLinear (ps.map Fin.val)) = R1CS.packedField (ps.map bytes) := by
  induction ps with
  | nil => rfl
  | cons position rest ih =>
    simp only [List.map_cons, packLinear, eval_append, eval_scale]
    rw [byte_linear_value, bindings, ih]
    simp only [R1CS.packedField]
    grind

theorem packing_constraint {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (chunk : Fin 6) (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get) :
    evalLinear ctx.get (packLinear ((positions chunk).map Fin.val)) = ctx.get (2+chunk.val) := by
  have matchGate := packing_gates_match chunk
  cases found : byteShape.gates[1248+chunk.val]? with
  | none => simp [found] at matchGate
  | some actual =>
    have actualHolds := holds actual (by simpa using Array.mem_of_getElem? found)
    have transferred := same_gate_sound ctx (packingGate chunk) actual (by simpa [found] using matchGate) actualHolds
    change evalLinear ctx.get (sub (packLinear ((positions chunk).map Fin.val)) [(2+chunk.val, 1)]) *
      evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0) at transferred
    rw [BodySoundness.eval_sub, BodySoundness.eval_constant ctx.get one 1,
      BodySoundness.eval_constant ctx.get one 0] at transferred
    have wireValue : evalLinear ctx.get [(2+chunk.val, 1)] = ctx.get (2+chunk.val) := by
      simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
    rw [wireValue] at transferred
    grind

theorem exists_decoded_bytes {F : Type} [Field F] (ctx : Lean.RArray F)
    (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get) :
    ∃ bytes : Fin 156 → Fin 256, ∀ pos,
      R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val := by
  have each (pos : Fin 156) := BitPacking.byte_bits_are_a_byte (globalBits ctx.get pos)
    (by simp [globalBits]) (global_bits_boolean ctx pos one holds)
  let decoded := fun pos => Classical.choose (each pos)
  exact ⟨decoded, fun pos => Classical.choose_spec (each pos)⟩

theorem chunks_cover (position : Fin 156) :
    ∃ (chunk : Fin 6) (offset : Fin (chunkLength chunk)), chunkPosition chunk offset = position := by
  have bound := position.isLt
  let chunk : Fin 6 := ⟨position.val / 31, by omega⟩
  have offsetBound : position.val % 31 < chunkLength chunk := by
    change position.val % 31 < (if position.val / 31 = 5 then 1 else 31)
    by_cases last : position.val / 31 = 5
    · rw [ite_eq_left last]; omega
    · rw [ite_eq_right last]; omega
  refine ⟨chunk, ⟨position.val % 31, offsetBound⟩, ?_⟩
  apply Fin.ext
  simp only [chunkPosition, chunk]
  omega

theorem packed_chunks_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Fin 156 → Fin 256)
    (same : ∀ chunk, R1CS.packedField (F := F) (chunkBytes a chunk) = R1CS.packedField (chunkBytes b chunk)) :
    a = b := by
  funext position
  obtain ⟨chunk, offset, atPosition⟩ := chunks_cover position
  have lengthBound : (chunkBytes a chunk).length ≤ 31 := by
    have len : (positions chunk).length = chunkLength chunk := List.length_ofFn
    rw [chunkBytes, List.length_map, len]
    unfold chunkLength
    split <;> omega
  have equal := R1CS.packed_field_injective (chunkBytes a chunk) (chunkBytes b chunk)
    (by simp [chunkBytes, positions]) lengthBound (same chunk)
  have atOffset := congrArg (fun xs : List (Fin 256) => (xs[offset.val]?).getD ⟨0, by decide⟩) equal
  simpa only [chunkBytes, positions, List.map_ofFn, List.getElem?_ofFn, dite_eq_left offset.isLt,
    Option.getD_some, Function.comp_def, atPosition] using atOffset

def PublicBytesMatch {F : Type} [CommRing F] (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) : Prop :=
  ∀ chunk : Fin 6, ctx.get (2+chunk.val) = R1CS.packedField (chunkBytes bytes chunk)

theorem public_bytes_bind_all_bits {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256)
    (one : ctx.get 0 = 1) (publicInputs : PublicBytesMatch ctx bytes) (holds : Satisfied byteShape ctx.get) :
    ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val := by
  obtain ⟨decoded, bindings⟩ := exists_decoded_bytes ctx one holds
  have same : decoded = bytes := by
    apply packed_chunks_injective (F := F)
    intro chunk
    change R1CS.packedField ((positions chunk).map decoded) = R1CS.packedField ((positions chunk).map bytes)
    rw [← packing_linear_value ctx decoded bindings (positions chunk)]
    exact (packing_constraint ctx chunk one holds).trans (publicInputs chunk)
  simpa [same] using bindings

theorem public_bytes_imply_body {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256)
    (one : ctx.get 0 = 1) (publicInputs : PublicBytesMatch ctx bytes) (holds : Satisfied byteShape ctx.get) :
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow)
      (⟨0, by decide⟩, ⟨0, by decide⟩) (BodySoundness.bodySuffix bytes 0 121) =
        some (⟨7, by decide⟩, ⟨1, by decide⟩) :=
  BodySoundness.full_body_ends_with_one_result ctx bytes one (public_bytes_bind_all_bits ctx bytes one publicInputs holds) holds

#print axioms public_bytes_bind_all_bits
#print axioms public_bytes_imply_body

end ZkBuild.PublicBinding
