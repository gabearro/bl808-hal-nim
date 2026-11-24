import ShaHashPadding

namespace ZkBuild.ShaHashBlock

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram ShaHash ShaHashPadding
attribute [local instance] Ring.intCast Semiring.natCast

def zeroByte : ByteWires := fun _ => constant 0

theorem zeroByte_rep {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) :
    ByteRep values zeroByte 0 := by
  refine ⟨fun _ => false,?_,by decide⟩
  intro i
  simp [zeroByte,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]

theorem word_from_bytes {F : Type} [CommRing F] (values : Nat → F)
    (wires : Fin 4 → ByteWires) (bytes : Fin 4 → Sha256.Byte)
    (represented : ∀ i, ByteRep values (wires i) (bytes i)) :
    RepresentsBits values ⟨ShaBoundary.wordBits wires,[]⟩
      (BitVec.ofNat 32 ((bytes 0).toNat*2^24+(bytes 1).toNat*2^16+(bytes 2).toNat*2^8+(bytes 3).toNat)) := by
  let bits : Fin 4 → ShaBoundary.Bools 8 := fun i => Classical.choose (represented i)
  have bitImages (b : Fin 4) (i : Fin 8) : E values (wires b i) = ((bits b i).toNat : F) :=
    (Classical.choose_spec (represented b)).1 i
  have same (b : Fin 4) : ShaBoundary.vector (bits b) = bytes b :=
    (Classical.choose_spec (represented b)).2
  refine ⟨ShaBoundary.wordBits bits,ShaBoundary.word_rep values wires bits bitImages,?_⟩
  have result := ShaBoundary.word_fips bits
  simpa only [same] using result

private theorem related_maps (r : α → β → Prop) (xs : List γ) (f : γ → α) (g : γ → β)
    (h : ∀ i ∈ xs, r (f i) (g i)) : Related r (xs.map f) (xs.map g) := by
  induction xs with
  | nil => exact .nil
  | cons x xs ih => exact .cons (h x (by simp)) (ih (by intro i hi; exact h i (by simp [hi])))

set_option maxRecDepth 4096 in
theorem byteHeads_rep {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (wires : List ByteWires) (bytes : List Sha256.Byte) (represented : Related (ByteRep values) wires bytes) :
    Related (RepresentsBits values) (byteHeads wires) (blockHeads bytes) := by
  apply related_maps
  intro i member
  have each (b : Fin 4) := related_getD (ByteRep values) wires bytes represented zeroByte 0
    (zeroByte_rep values one) (i*4+b.val)
  have h := word_from_bytes values (fun b => wires.getD (i*4+b.val) (fun _ => constant 0))
    (fun b => bytes.getD (i*4+b.val) 0) each
  have index3 : (3 : Fin 4).val = 3 := rfl
  have defaultZero : (default : Sha256.Byte) = 0 := by decide
  simpa [byteHeads,blockHeads,zeroByte,index3,List.getD_eq_getElem?_getD,
    List.getElem!_eq_getElem?_getD,defaultZero] using h

theorem compressBytes_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (previous : State ShaWordMatrix.Word) (reference : State Sha256.Word)
    (state : StateRep values previous reference) (wires : List ByteWires) (bytes : List Sha256.Byte)
    (represented : Related (ByteRep values) wires bytes) :
    Ensures values (compressM previous (byteHeads wires))
      (fun out => Related (Represents values) out (Sha256.compress reference.toList bytes)) := by
  have sound := compressBitsM_sound values one previous reference state (byteHeads wires) (blockHeads bytes)
    (byteHeads_rep values one wires bytes represented)
  simpa only [compressRef_fips] using sound

def referenceState (words : List Sha256.Word) : State Sha256.Word :=
  ⟨words.getD 0 0,words.getD 1 0,words.getD 2 0,words.getD 3 0,
   words.getD 4 0,words.getD 5 0,words.getD 6 0,words.getD 7 0⟩

theorem stateOfList_rep {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (words : List ShaWordMatrix.Word) (references : List Sha256.Word)
    (represented : Related (Represents values) words references) :
    StateRep values (stateOfList words) (referenceState references) := by
  have atIndex (i : Nat) := related_getD (Represents values) words references represented zeroWord 0 (zero_rep values one) i
  exact ⟨atIndex 0,atIndex 1,atIndex 2,atIndex 3,atIndex 4,atIndex 5,atIndex 6,atIndex 7⟩

theorem represents_value {F : Type} [CommRing F] (values : Nat → F)
    (word : ShaWordMatrix.Word) (reference : Sha256.Word) (represented : Represents values word reference) :
    E values word.value = (reference.toNat : F) := by
  obtain ⟨bits,meaning,same⟩ := represented
  rw [meaning.2,← ShaWordFips.word_value,same]

def selectedRefs {F : Type} [CommRing F] (selector : F)
    (previous : List F) (words : List Sha256.Word) : List F :=
  List.zipWith (fun old word => old+selector*(word.toNat : F)) previous words

theorem selectM_sound {F : Type} [Field F] (values : Nat → F)
    (selector : Linear) (s : F) (selectorImage : E values selector = s)
    (words : List ShaWordMatrix.Word) (references : List Sha256.Word)
    (represented : Related (Represents values) words references)
    (previous : List Linear) (prior : List F)
    (priorImages : Related (fun wire value => E values wire = value) previous prior) :
    Ensures values (selectM selector previous words)
      (fun out => Related (fun wire value => E values wire = value) out (selectedRefs s prior references)) := by
  induction represented generalizing previous prior with
  | nil =>
    cases priorImages <;> exact pure_sound values [] _ .nil
  | @cons word reference words references head tail ih =>
    cases priorImages with
    | nil => exact pure_sound values [] _ .nil
    | @cons previousHead priorHead previousTail priorTail first rest =>
      apply bind_sound values _ _ _ _ (ShaScalar.multiply_sound values selector word.value)
      intro product productImage
      apply bind_sound values _ _ _ _ (ih previousTail priorTail rest)
      intro output remaining
      apply pure_sound
      refine .cons ?_ remaining
      simpa only [E,FullMatrix.eval_append,selectorImage,represents_value values word reference head,first]
        using congrArg (fun x => priorHead+x) productImage

def blockBytes (message : List Sha256.Byte) (index : Nat) : List Sha256.Byte :=
  (List.ofFn (fun i : Fin 64 => i)).map (fun i => (Sha256.pad message).getD (index*64+i.val) 0)

theorem lastBlock_bound (n : Nat) (small : n < 2^32) : ShaPadding.lastBlock n < scalarModulus := by
  have prime : 2^32 < scalarModulus := by decide
  unfold ShaPadding.lastBlock
  split <;> omega

theorem blockM_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (finalBlock : Linear) (state : HashState) (reference : State Sha256.Word)
    (prior : List F) (index : Nat) (capacity : source.length < 2^32)
    (fits : message.length ≤ source.length) (indexBound : index < scalarModulus)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values lengthBits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImages : ∀ offset : Fin 64, index*64+offset.val < message.length →
      E values (inputByte source (index*64+offset.val)) =
      ((message.getD (index*64+offset.val) 0).toNat : F))
    (lastImage : E values finalBlock = (ShaPadding.lastBlock message.length : F))
    (activeImage : E values state.active = if index*64 ≤ message.length then 1 else 0)
    (stateImage : StateRep values state.words reference)
    (selectedImages : Related (fun wire value => E values wire = value) state.selected prior) :
    Ensures values (blockM source length lengthBits finalBlock state index) (fun output =>
      let compressed := Sha256.compress reference.toList (blockBytes message index)
      let selector : F := if index = ShaPadding.lastBlock message.length then 1 else 0
      StateRep values output.words (referenceState compressed) ∧
      Related (fun wire value => E values wire = value) output.selected (selectedRefs selector prior compressed) ∧
      E values output.active = (if (index+1)*64 ≤ message.length then 1 else 0) ∧
      E values output.ends = E values state.ends+selector) := by
  have lastSound := ShaScalar.zero_sound values one (sub finalBlock (constant (Int.ofNat index)))
  have constantImage : E values (constant (Int.ofNat index)) = (index : F) := by
    rw [eval_constant values one]; exact Ring.intCast_natCast index
  have zeroTest := ShaScalar.nat_zero_test (F := F) (ShaPadding.lastBlock message.length) index
    (lastBlock_bound message.length (by omega)) indexBound
  have selectorSound : Ensures values (ShaScalar.zero (sub finalBlock (constant (Int.ofNat index))))
      (fun out => E values out = if index = ShaPadding.lastBlock message.length then 1 else 0) := by
    constructor
    intro start holds
    have selected := lastSound.run start holds
    rw [eval_sub,lastImage,constantImage,zeroTest] at selected
    simpa only [eq_comm] using selected
  unfold blockM
  apply bind_sound values _ _ _ _ selectorSound
  intro selector selectorImage
  apply bind_sound values _ _ _ _ (padBlock_sound values one source length lengthBits meaning message
    selector state.active index capacity fits image bitImages bitValue sourceImages selectorImage activeImage)
  intro padded padding
  apply bind_sound values _ _ _ _ (compressBytes_sound values one state.words reference stateImage
    padded.2 (blockBytes message index) padding.2)
  intro words wordImages
  apply bind_sound values _ _ _ _ (selectM_sound values selector _ selectorImage words _ wordImages
    state.selected prior selectedImages)
  intro selected selectedImage
  apply pure_sound
  exact ⟨stateOfList_rep values one words _ wordImages,selectedImage,padding.1,
    by simp only [E,FullMatrix.eval_append,selectorImage]⟩

#print axioms word_from_bytes
#print axioms compressBytes_sound
#print axioms stateOfList_rep
#print axioms selectM_sound
#print axioms blockM_sound

end ZkBuild.ShaHashBlock
