import ShaHashLength

namespace ZkBuild.ShaHashPadding

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram ShaHash
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem boundary_meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear) (n position : Nat)
    (capacity : source.length < 2^32) (fits : n ≤ source.length) (image : E values length = (n : F)) :
    Soundness.boundaryValue values source length position = if position = n then 1 else 0 := by
  have small : 2^32 < scalarModulus := by decide
  by_cases inside : position ≤ source.length
  · have nBound : n < scalarModulus := by omega
    have pBound : position < scalarModulus := by omega
    have constantImage : E values (constant (Int.ofNat position)) = (position : F) := by
      rw [eval_constant values one]
      exact Ring.intCast_natCast position
    simp only [Soundness.boundaryValue,ite_eq_left inside,eval_sub,image,constantImage]
    rw [ShaScalar.nat_zero_test n position nBound pBound]
    simp only [eq_comm]
  · have different : position ≠ n := by omega
    simp [Soundness.boundaryValue,inside,different]

theorem padByte_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last active : Linear) (block : Nat) (offset : Fin 64)
    (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values lengthBits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImage : E values (inputByte source (block*64+offset.val)) = ((message.getD (block*64+offset.val) 0).toNat : F))
    (lastImage : E values last = if block = ShaPadding.lastBlock message.length then 1 else 0)
    (activeImage : E values active = if block*64+offset.val ≤ message.length then 1 else 0) :
    Ensures values (padByteM source length lengthBits last active block offset) (fun output =>
      E values output.active = (if block*64+offset.val < message.length then 1 else 0) ∧
      E values output.value = (((Sha256.pad message).getD (block*64+offset.val) 0).toNat : F) ∧
      RangeReuse.Certificate 8 (E values output.value) ((List.ofFn output.bits).map (E values))) := by
  constructor
  intro start holds
  have algebra := (Soundness.padByte_algebra values one source length lengthBits last active block offset).run start holds
  let position := block*64+offset.val
  have boundary := boundary_meaning values one source length message.length position capacity fits image
  have byteImage : E values (ShaBoundary.lengthWiring lengthBits offset) =
      ((ShaBoundary.lengthByte (BitVec.ofNat 32 message.length) offset).toNat : F) := by
    have h := ShaBoundary.lengthWiring_sound values one lengthBits meaning offset bitImages
    simpa [ShaBoundary.vector,bitValue] using h
  have valueImage := algebra.2.2.1
  rw [boundary,sourceImage,lastImage,byteImage] at valueImage
  have markerCast : (128 : F)*(if position = message.length then 1 else 0) =
      ((if position = message.length then 128 else 0 : Nat) : F) := by
    split <;> grind
  have finalCast : (if block = ShaPadding.lastBlock message.length then (1 : F) else 0)*
      ((ShaBoundary.lengthByte (BitVec.ofNat 32 message.length) offset).toNat : F) =
      ((if block = ShaPadding.lastBlock message.length then
        (ShaBoundary.lengthByte (BitVec.ofNat 32 message.length) offset).toNat else 0 : Nat) : F) := by
    split <;> grind
  have raw : E values (padByteM source length lengthBits last active block offset start).value.value =
      ((ShaPadding.rawValue message position : Nat) : F) := by
    rw [ShaPadding.block_value message block offset (by omega)]
    rw [markerCast,finalCast] at valueImage
    simpa only [position,Semiring.natCast_add] using valueImage
  refine ⟨?_,?_,algebra.2.2.2⟩
  · rw [algebra.1,boundary,activeImage]
    by_cases before : position < message.length
    · simp [position,show position ≤ message.length by omega,show position ≠ message.length by omega,before]
      grind
    · by_cases atEnd : position = message.length
      · simp [position,atEnd]
        grind
      · simp [position,show ¬position ≤ message.length by omega,atEnd,before]
        grind
  · rw [← ShaPadding.circuit_value, ShaPadding.circuit_padding] at raw
    exact raw

def ByteRep {F : Type} [CommRing F] (values : Nat → F) (wires : ByteWires) (byte : Sha256.Byte) : Prop :=
  ∃ bits : ShaBoundary.Bools 8, ShaScalar.RepresentsBits values wires bits ∧ ShaBoundary.vector bits = byte

theorem padByte_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last active : Linear) (block : Nat) (offset : Fin 64)
    (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values lengthBits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImage : block*64+offset.val < message.length →
      E values (inputByte source (block*64+offset.val)) = ((message.getD (block*64+offset.val) 0).toNat : F))
    (lastImage : E values last = if block = ShaPadding.lastBlock message.length then 1 else 0)
    (activeImage : E values active = if block*64+offset.val ≤ message.length then 1 else 0) :
    Ensures values (padByteM source length lengthBits last active block offset) (fun output =>
      E values output.active = (if block*64+offset.val < message.length then 1 else 0) ∧
      ByteRep values output.bits ((Sha256.pad message).getD (block*64+offset.val) 0)) := by
  constructor
  intro start holds
  have algebra := (Soundness.padByte_algebra values one source length lengthBits last active block offset).run start holds
  have boundary := boundary_meaning values one source length message.length (block*64+offset.val) capacity fits image
  have activeResult : E values (padByteM source length lengthBits last active block offset start).value.active =
      if block*64+offset.val < message.length then 1 else 0 := by
    rw [algebra.1,boundary,activeImage]
    by_cases before : block*64+offset.val < message.length
    · simp [show block*64+offset.val ≤ message.length by omega,show block*64+offset.val ≠ message.length by omega,before]
      grind
    · by_cases atEnd : block*64+offset.val = message.length
      · simp [atEnd]; grind
      · simp [show ¬block*64+offset.val ≤ message.length by omega,atEnd,before]; grind
  have sourceValue : E values (inputByte source (block*64+offset.val)) =
      ((message.getD (block*64+offset.val) 0).toNat : F) := by
    by_cases before : block*64+offset.val < message.length
    · exact sourceImage before
    · have inactive := algebra.2.1
      rw [activeResult,ite_eq_right before] at inactive
      have absent : message[block*64+offset.val]? = none := List.getElem?_eq_none_iff.mpr (by omega)
      simp only [List.getD_eq_getElem?_getD,absent,Option.getD_none]
      have vanish : E values (inputByte source (block*64+offset.val)) = 0 := by grind
      simpa using vanish
  have correct := (padByte_value values one source length lengthBits meaning message last active block offset
    capacity fits image bitImages bitValue sourceValue lastImage activeImage).run start holds
  have cert : RangeReuse.Certificate 8
      ((((Sha256.pad message).getD (block*64+offset.val) 0).toNat : Nat) : F)
      ((List.ofFn (padByteM source length lengthBits last active block offset start).value.bits).map (E values)) := by
    have certificate := correct.2.2
    rwa [correct.2.1] at certificate
  obtain ⟨bits,rep,n⟩ := ShaScalar.certificate_rep values 8 _ _ (by decide)
    ((Sha256.pad message).getD (block*64+offset.val) 0).isLt cert
  refine ⟨correct.1,bits,rep,?_⟩
  apply BitVec.eq_of_toNat_eq
  rw [ShaBoundary.vector_value,n]

theorem padOffsets_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last : Linear) (block : Nat) (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values lengthBits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImages : ∀ offset : Fin 64, block*64+offset.val < message.length →
      E values (inputByte source (block*64+offset.val)) =
      ((message.getD (block*64+offset.val) 0).toNat : F))
    (lastImage : E values last = if block = ShaPadding.lastBlock message.length then 1 else 0)
    (offsets : List (Fin 64)) (start : Nat) (active : Linear)
    (ordered : offsets.map Fin.val = List.range' start offsets.length)
    (activeImage : E values active = if block*64+start ≤ message.length then 1 else 0) :
    Ensures values (padBlockM source length lengthBits last active block offsets) (fun output =>
      E values output.1 = (if block*64+start+offsets.length ≤ message.length then 1 else 0) ∧
      Related (ByteRep values) output.2
        (offsets.map (fun i => (Sha256.pad message).getD (block*64+i.val) 0))) := by
  induction offsets generalizing start active with
  | nil =>
    apply pure_sound
    exact ⟨by simpa using activeImage,.nil⟩
  | cons offset rest ih =>
    have equations : offset.val = start ∧ rest.map Fin.val = List.range' (start+1) rest.length := by
      simpa only [List.map_cons,List.length_cons,List.range'_succ,List.cons.injEq] using ordered
    have firstImage : E values active = if block*64+offset.val ≤ message.length then 1 else 0 := by
      simpa [equations.1] using activeImage
    apply bind_sound values _ _ _ _ (padByte_sound values one source length lengthBits meaning message
      last active block offset capacity fits image bitImages bitValue (sourceImages offset) lastImage firstImage)
    intro padded head
    have nextImage : E values padded.active = if block*64+(start+1) ≤ message.length then 1 else 0 := by
      have same : (block*64+offset.val < message.length) = (block*64+(start+1) ≤ message.length) := by
        apply propext; omega
      simpa only [same] using head.1
    apply bind_sound values _ _ _ _ (ih (start+1) padded.active equations.2 nextImage)
    intro remaining tail
    apply pure_sound
    exact ⟨by simpa [Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using tail.1,.cons head.2 tail.2⟩

theorem padBlock_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (meaning : ShaBoundary.Bools 32) (message : List Sha256.Byte)
    (last active : Linear) (block : Nat) (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (bitImages : ShaScalar.RepresentsBits values lengthBits meaning)
    (bitValue : ShaBoundary.bitsValue meaning = message.length)
    (sourceImages : ∀ offset : Fin 64, block*64+offset.val < message.length →
      E values (inputByte source (block*64+offset.val)) =
      ((message.getD (block*64+offset.val) 0).toNat : F))
    (lastImage : E values last = if block = ShaPadding.lastBlock message.length then 1 else 0)
    (activeImage : E values active = if block*64 ≤ message.length then 1 else 0) :
    Ensures values (padBlockM source length lengthBits last active block (List.ofFn (fun i : Fin 64 => i)))
      (fun output => E values output.1 = (if (block+1)*64 ≤ message.length then 1 else 0) ∧
        Related (ByteRep values) output.2
          ((List.ofFn (fun i : Fin 64 => i)).map (fun i => (Sha256.pad message).getD (block*64+i.val) 0))) := by
  have result := padOffsets_sound values one source length lengthBits meaning message last block capacity fits image
    bitImages bitValue sourceImages lastImage (List.ofFn (fun i : Fin 64 => i)) 0 active (by decide)
    (by simpa using activeImage)
  simpa [Nat.add_mul,Nat.add_assoc] using result

#print axioms boundary_meaning
#print axioms padByte_value
#print axioms padByte_sound
#print axioms padBlock_sound

end ZkBuild.ShaHashPadding
