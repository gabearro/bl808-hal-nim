import ExactLength

namespace ZkBuild.BinarySoundness

open Lean.Grind CircuitShape FullMatrix PublicBinding HeaderSoundness ExactLength
attribute [local instance] Ring.intCast Semiring.natCast

def paddedBytes (wasm : List (Fin 256)) (position : Fin 156) : Fin 256 :=
  wasm[position.val]?.getD ⟨0, by decide⟩

def PublicInputsFor {F : Type} [CommRing F] (ctx : Lean.RArray F) (wasm : List (Fin 256)) : Prop :=
  ctx.get 1 = (wasm.length : F) ∧ PublicBytesMatch ctx (paddedBytes wasm)

def SupportedWasmBinary (wasm : List (Fin 256)) : Prop :=
  36 ≤ wasm.length ∧ wasm.length ≤ 156 ∧
  HeaderValid (paddedBytes wasm) wasm.length ∧
  runExact (⟨0, by decide⟩, ⟨0, by decide⟩) (wasm.drop 35) =
    some (⟨7, by decide⟩, ⟨1, by decide⟩)

theorem body_suffix_get (bytes : Fin 156 → Fin 256) (count : Nat) :
    ∀ start i (bound : i < count),
      (BodySoundness.bodySuffix bytes start count)[i]'(by rw [body_suffix_length]; exact bound) =
        BodySoundness.bodyByte bytes (start+i) := by
  induction count with
  | zero => intro start i bound; omega
  | succ count ih =>
    intro start i bound
    cases i with
    | zero => simp [BodySoundness.bodySuffix]
    | succ i =>
      have tail := ih (start+1) i (by omega)
      simpa [BodySoundness.bodySuffix, Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using tail

theorem exact_body_is_submitted_bytes (wasm : List (Fin 256))
    (bound : wasm.length ≤ 156) :
    BodySoundness.bodySuffix (paddedBytes wasm) 0 (wasm.length-35) = wasm.drop 35 := by
  apply List.ext_getElem
  · simp [body_suffix_length]
  · intro i left right
    have inBody : i < wasm.length-35 := by simpa [body_suffix_length] using left
    have inCapacity : i < 121 := by omega
    have inWasm : 35+i < wasm.length := by omega
    rw [body_suffix_get (paddedBytes wasm) (wasm.length-35) 0 i inBody]
    simp only [Nat.zero_add, BodySoundness.bodyByte, dite_eq_left inCapacity, moduleByteIndex,
      paddedBytes, List.getElem?_eq_getElem inWasm, Option.getD_some, List.getElem_drop]

theorem binary_soundness {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (wasm : List (Fin 256))
    (lengthBound : 36 ≤ wasm.length ∧ wasm.length ≤ 156)
    (one : ctx.get 0 = 1) (publicInputs : PublicInputsFor ctx wasm)
    (satisfied : Satisfied byteShape ctx.get) : SupportedWasmBinary wasm := by
  obtain ⟨header, body⟩ := certified_binary_profile ctx (paddedBytes wasm) wasm.length lengthBound one
    publicInputs.2 publicInputs.1 satisfied
  rw [exact_body_is_submitted_bytes wasm lengthBound.2] at body
  exact ⟨lengthBound.1, lengthBound.2, header, body⟩

#print axioms binary_soundness

end ZkBuild.BinarySoundness
