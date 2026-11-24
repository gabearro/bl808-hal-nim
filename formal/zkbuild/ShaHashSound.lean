import ShaHashBlock

namespace ZkBuild.ShaHashSound

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram ShaHash ShaHashBlock
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

private theorem getD_image (words : List Sha256.Word) (length : words.length = 8) :
    List.ofFn (fun i : Fin 8 => words.getD i.val 0) = words := by
  apply List.ext_getElem
  · simp [length]
  · intro i left right
    rw [List.getElem_ofFn]
    exact (List.getElem_eq_getD 0).symm

set_option maxRecDepth 4096 in
theorem referenceState_list (words : List Sha256.Word) (length : words.length = 8) :
    (referenceState words).toList = words := by
  have h := getD_image words length
  change [words.getD 0 0,words.getD 1 0,words.getD 2 0,words.getD 3 0,
    words.getD 4 0,words.getD 5 0,words.getD 6 0,words.getD 7 0] = words
  exact h

def chain (message : List Sha256.Byte) : Nat → List Sha256.Word
  | 0 => Sha256.initial
  | n+1 => Sha256.compress (chain message n) (blockBytes message n)

theorem chain_length (message : List Sha256.Byte) (n : Nat) : (chain message n).length = 8 := by
  cases n <;> simp [chain,Sha256.initial,Sha256.compress]

def selected {F : Type} [CommRing F] (message : List Sha256.Byte) (count : Nat) : List F :=
  if ShaPadding.lastBlock message.length < count then
    (chain message (ShaPadding.lastBlock message.length+1)).map (fun word => (word.toNat : F))
  else List.replicate 8 0

theorem selected_length {F : Type} [CommRing F] (message : List Sha256.Byte) (n : Nat) :
    (selected (F := F) message n).length = 8 := by
  unfold selected
  split <;> simp [chain_length]

private theorem select_zero {F : Type} [CommRing F] (previous : List F) (words : List Sha256.Word)
    (length : previous.length = words.length) : selectedRefs 0 previous words = previous := by
  induction previous generalizing words with
  | nil => simp [selectedRefs]
  | cons old tail ih =>
    cases words with
    | nil => simp at length
    | cons word rest =>
      have sizes : tail.length = rest.length := by simpa using length
      simpa [selectedRefs,List.zipWith,Semiring.zero_mul,AddCommMonoid.add_zero] using
        congrArg (List.cons old) (ih rest sizes)

private theorem select_one {F : Type} [CommRing F] (words : List Sha256.Word) :
    selectedRefs 1 (List.replicate words.length (0 : F)) words = words.map (fun word => (word.toNat : F)) := by
  induction words with
  | nil => rfl
  | cons word rest ih =>
    simpa [selectedRefs,List.zipWith,List.replicate_succ,Semiring.one_mul,AddCommMonoid.zero_add] using
      congrArg (List.cons (word.toNat : F)) ih

theorem selected_step {F : Type} [CommRing F] (message : List Sha256.Byte) (count : Nat) :
    selectedRefs (if count = ShaPadding.lastBlock message.length then (1 : F) else 0)
      (selected message count) (chain message (count+1)) = selected message (count+1) := by
  by_cases atLast : count = ShaPadding.lastBlock message.length
  · subst count
    simp only [selected,Nat.lt_irrefl,ite_false,Nat.lt_add_one,ite_true]
    rw [← chain_length message (ShaPadding.lastBlock message.length+1)]
    exact select_one _
  · rw [ite_eq_right atLast,select_zero _ _ (by simp [selected_length,chain_length])]
    have same : (ShaPadding.lastBlock message.length < count) =
        (ShaPadding.lastBlock message.length < count+1) := by apply propext; omega
    simp only [selected,same]

def HashRep {F : Type} [CommRing F] (values : Nat → F) (state : HashState)
    (message : List Sha256.Byte) (count : Nat) : Prop :=
  StateRep values state.words (referenceState (chain message count)) ∧
  Related (fun wire value => E values wire = value) state.selected (selected message count) ∧
  E values state.active = (if count*64 ≤ message.length then 1 else 0) ∧
  E values state.ends = (if ShaPadding.lastBlock message.length < count then 1 else 0)

theorem block_step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (bits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last : Linear) (state : HashState) (count : Nat) (capacity : source.length < 2^32)
    (fits : message.length ≤ source.length) (countBound : count < scalarModulus)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values bits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImages : ∀ position, position < message.length → E values (inputByte source position) = ((message.getD position 0).toNat : F))
    (lastImage : E values last = (ShaPadding.lastBlock message.length : F))
    (stateImage : HashRep values state message count) :
    Ensures values (blockM source length bits last state count)
      (fun output => HashRep values output message (count+1)) := by
  constructor
  intro start holds
  have sound := (blockM_sound values one source length bits meaning message last state
    (referenceState (chain message count)) (selected message count) count capacity fits countBound image
    bitImages bitValue (fun _ => sourceImages _) lastImage stateImage.2.2.1 stateImage.1 stateImage.2.1).run start holds
  rw [referenceState_list _ (chain_length message count)] at sound
  change StateRep _ _ (referenceState (chain message (count+1))) ∧
    Related _ _ (selectedRefs _ _ (chain message (count+1))) ∧ _ at sound
  refine ⟨sound.1,?_,sound.2.2.1,?_⟩
  · simpa only [selected_step] using sound.2.1
  · rw [sound.2.2.2,stateImage.2.2.2]
    by_cases before : ShaPadding.lastBlock message.length < count
    · simp [before,show count ≠ ShaPadding.lastBlock message.length by omega,
        show ShaPadding.lastBlock message.length < count+1 by omega,AddCommMonoid.add_zero]
    · by_cases atLast : count = ShaPadding.lastBlock message.length
      · simp [atLast,AddCommMonoid.zero_add]
      · simp [before,atLast,show ¬ ShaPadding.lastBlock message.length < count+1 by omega,AddCommMonoid.zero_add]


theorem initial_rep {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (message : List Sha256.Byte) :
    HashRep values ⟨initialState,List.replicate 8 (constant 0),constant 1,constant 0⟩ message 0 := by
  have words : Related (Represents values) (Sha256.initial.map roundKey) Sha256.initial := by
    apply related_map
    intro word member
    have included : word.toNat ∈ ShaWordMatrix.literalValues := by
      apply List.mem_append_right
      exact List.mem_map.mpr ⟨word,List.mem_append_left _ member,rfl⟩
    simpa [roundKey] using literal_rep values one word.toNat included
  have zeros (n : Nat) : Related (fun wire value => E values wire = value)
      (List.replicate n (constant 0)) (List.replicate n (0 : F)) := by
    induction n with
    | zero => exact .nil
    | succ n ih => exact .cons (by simp [eval_constant values one]) ih
  refine ⟨stateOfList_rep values one _ _ words,?_,?_,?_⟩
  · simpa only [selected,Nat.not_lt_zero,ite_false] using zeros 8
  · simp [eval_constant values one]
  · simp [eval_constant values one]

theorem blocks_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (bits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last : Linear) (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values bits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImages : ∀ position, position < message.length → E values (inputByte source position) = ((message.getD position 0).toNat : F))
    (lastImage : E values last = (ShaPadding.lastBlock message.length : F))
    (indices : List Nat) (count : Nat) (state : HashState)
    (ordered : indices = List.range' count indices.length)
    (bounded : count+indices.length ≤ scalarModulus)
    (stateImage : HashRep values state message count) :
    Ensures values (blocksM source length bits last indices state)
      (fun output => HashRep values output message (count+indices.length)) := by
  induction indices generalizing count state with
  | nil => exact pure_sound values state _ stateImage
  | cons index rest ih =>
    have order : index = count ∧ rest = List.range' (count+1) rest.length := by
      simpa only [List.length_cons,List.range'_succ,List.cons.injEq] using ordered
    have sameIndex := order.1
    subst index
    apply bind_sound values _ _ _ _ (block_step values one source length bits meaning message last state count
      capacity fits (by simp only [List.length_cons] at bounded; omega) image bitImages bitValue sourceImages lastImage stateImage)
    intro next nextImage
    have tail := ih (count+1) next order.2 (by simp only [List.length_cons] at bounded; omega) nextImage
    simpa only [List.length_cons,Nat.add_assoc,Nat.add_comm 1] using tail

theorem blockBytes_fips (message : List Sha256.Byte) (index : Nat) (inside : index < Sha256.blockCount message.length) :
    blockBytes message index = ((Sha256.pad message).drop (index*64)).take 64 := by
  have size := Sha256.padded_length message
  apply List.ext_getElem
  · simp only [blockBytes,List.length_map,List.length_ofFn,List.length_take,List.length_drop,size]
    omega
  · intro i left right
    have offset : i < 64 := by simpa only [blockBytes,List.length_map,List.length_ofFn] using left
    simp only [blockBytes,List.map_ofFn,List.getElem_ofFn,List.getElem_take,List.getElem_drop]
    exact (List.getElem_eq_getD 0).symm

theorem chain_fips (message : List Sha256.Byte) (count : Nat) (inside : count ≤ Sha256.blockCount message.length) :
    chain message count = (List.range count).foldl
      (fun state i => Sha256.compress state (((Sha256.pad message).drop (i*64)).take 64)) Sha256.initial := by
  induction count with
  | zero => rfl
  | succ count ih =>
    simp only [chain,List.range_succ,List.foldl_append,List.foldl_cons,List.foldl_nil]
    rw [ih (by omega),blockBytes_fips message count (by omega)]

theorem chain_hash (message : List Sha256.Byte) :
    chain message (ShaPadding.lastBlock message.length+1) = Sha256.hash message := by
  have size : ShaPadding.lastBlock message.length+1 = Sha256.blockCount message.length := by
    unfold ShaPadding.lastBlock Sha256.blockCount
    split <;> omega
  rw [size,chain_fips message _ (Nat.le_refl _)]
  rfl


def digestLimb (message : List Sha256.Byte) (half : Fin 2) : Nat :=
  ShaBoundary.limbValue (fun i => ((Sha256.hash message).getD (half.val*4+i.val) 0).toNat)

theorem digestLimb_bound (message : List Sha256.Byte) (half : Fin 2) :
    digestLimb message half < 2^128 :=
  ShaBoundary.limb_bound _ (fun _ => BitVec.isLt _)

theorem selected_images {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (state : HashState) (message : List Sha256.Byte) (capacity : Nat) (fits : message.length ≤ capacity)
    (meaning : HashRep values state message (Sha256.blockCount capacity)) (index : Nat) :
    E values (state.selected.getD index (constant 0)) = (((Sha256.hash message).getD index 0).toNat : F) := by
  have selectedImage : Related (fun wire value => E values wire = value) state.selected
      ((Sha256.hash message).map (fun word => (word.toNat : F))) := by
    simpa only [selected,ite_eq_left (ShaPadding.last_block_fits _ _ fits),chain_hash] using meaning.2.1
  have h := related_getD _ _ _ selectedImage (constant 0) 0 (by simp [eval_constant values one]) index
  have mapValue : ((Sha256.hash message).map (fun word => (word.toNat : F))).getD index 0 =
      (((Sha256.hash message).getD index 0).toNat : F) := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map]
    have zeroCast : ((0 : Sha256.Word).toNat : F) = 0 := by simp
    rw [← zeroCast,Option.getD_map]
  exact h.trans mapValue

theorem blockCount_bound (capacity : Nat) (bounded : capacity < 2^32) :
    Sha256.blockCount capacity ≤ scalarModulus := by
  have prime : 2^32+2 < scalarModulus := by decide
  unfold Sha256.blockCount
  split <;> omega

theorem finish_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (digest : Fin 2 → Linear) (context : LengthContext) (message : List Sha256.Byte)
    (bits : ShaBoundary.Bools 32)
    (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (sourceImages : ∀ position, position < message.length → E values (inputByte source position) = ((message.getD position 0).toNat : F))
    (bitImages : ShaScalar.RepresentsBits values context.bits bits)
    (bitValue : ShaBoundary.bitsValue bits = message.length)
    (lastImage : E values context.last = (ShaPadding.lastBlock message.length : F)) :
    Ensures values (finishM source length digest context)
      (fun _ => E values (digest 0) = (digestLimb message 0 : F) ∧
        E values (digest 1) = (digestLimb message 1 : F)) := by
  unfold finishM
  have blocks := blocks_sound values one source length context.bits bits message context.last capacity fits image
    bitImages bitValue sourceImages lastImage (List.range (Sha256.blockCount source.length)) 0
    ⟨initialState,List.replicate 8 (constant 0),constant 1,constant 0⟩
    (by simp [List.range_eq_range']) (by simpa using blockCount_bound source.length capacity)
    (initial_rep values one message)
  apply bind_sound values _ _ _ _ blocks
  intro state stateImage
  apply bind_sound values _ _ _ _ (ShaScalar.equal_sound values one state.active (constant 0))
  intro unused0 ignored0
  apply bind_sound values _ _ _ _ (ShaScalar.equal_sound values one state.ends (constant 1))
  intro unused1 ignored1
  apply bind_sound values _ _ _ _ (ShaScalar.equal_sound values one (digest 0) _)
  intro unused2 firstDigest
  apply bind_sound values _ _ _ _ (ShaScalar.equal_sound values one (digest 1) _)
  intro unused3 secondDigest
  apply pure_sound
  have complete : HashRep values state message (Sha256.blockCount source.length) := by simpa using stateImage
  have first := ShaBoundary.limb_eval values one (fun i => state.selected.getD i.val (constant 0))
    (fun i => ((Sha256.hash message).getD i.val 0).toNat)
    (fun i => selected_images values one state message source.length fits complete i.val)
  have second := ShaBoundary.limb_eval values one (fun i => state.selected.getD (i.val+4) (constant 0))
    (fun i => ((Sha256.hash message).getD (i.val+4) 0).toNat)
    (fun i => selected_images values one state message source.length fits complete (i.val+4))
  exact ⟨firstDigest.trans first,by simpa [digestLimb,Nat.add_comm] using secondDigest.trans second⟩


theorem hash_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (digest : Fin 2 → Linear) (message : List Sha256.Byte)
    (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (sourceImages : ∀ position, position < message.length → E values (inputByte source position) = ((message.getD position 0).toNat : F)) :
    Ensures values (hashM source length digest)
      (fun _ => E values (digest 0) = (digestLimb message 0 : F) ∧
        E values (digest 1) = (digestLimb message 1 : F)) := by
  unfold hashM
  apply bind_sound values _ _ _ _ (ShaHashLength.prepare_sound values one source.length message.length length
    capacity (by omega) image)
  intro context prepared
  obtain ⟨bits,bitImages,bitValue,_,lastImage⟩ := prepared
  exact finish_sound values one source length digest context message bits capacity fits image sourceImages bitImages bitValue lastImage


theorem input_images {F : Type} [CommRing F] (values : Nat → F)
    (capacity : Nat) (message : List Sha256.Byte) (fits : message.length ≤ capacity)
    (inputs : ∀ i, i < message.length → values (i+4) = ((message.getD i 0).toNat : F)) :
    ∀ position, position < message.length →
      E values (inputByte ((List.range capacity).map (fun i => wire (i+4))) position) =
        ((message.getD position 0).toNat : F) := by
  intro position before
  have inside : position < capacity := by omega
  simp only [inputByte,List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range inside,
    Option.map_some,Option.getD_some]
  simpa only [eval_wire,List.getD_eq_getElem?_getD] using inputs position before

theorem checked_digest {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (actual : Artifact) (capacity : Nat) (checked : conforms actual (artifact capacity) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : CircuitShape.Satisfied actual.shape values)
    (message : List Sha256.Byte) (capacityBound : capacity < 2^32) (fits : message.length ≤ capacity)
    (lengthImage : values 3 = (message.length : F))
    (inputImage : ∀ i, i < message.length → values (i+4) = ((message.getD i 0).toNat : F)) :
    values 1 = (digestLimb message 0 : F) ∧ values 2 = (digestLimb message 1 : F) := by
  have relation := checked_relation actual capacity checked values satisfied
  have bound : ((List.range capacity).map (fun i => wire (i+4))).length = capacity := by simp
  have proof := hash_sound values one ((List.range capacity).map (fun i => wire (i+4))) (wire 3)
    (fun i => wire (i.val+1)) message (by simpa only [bound] using capacityBound)
    (by simpa only [bound] using fits) (by simpa only [eval_wire] using lengthImage)
    (input_images values capacity message fits inputImage)
  have result := proof.run (capacity+4) relation.1
  simpa only [eval_wire,Fin.val_zero,Fin.val_one] using result

#print axioms referenceState_list
#print axioms selected_step
#print axioms block_step
#print axioms initial_rep
#print axioms blocks_sound
#print axioms blockBytes_fips
#print axioms chain_hash
#print axioms hash_sound
#print axioms checked_digest
#print axioms digestLimb_bound

end ZkBuild.ShaHashSound
