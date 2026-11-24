import ShaProgram
import ScalarWords

namespace ZkBuild.ShaBoundary

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Bools (width : Nat) := Fin width → Bool
def bitsValue (bits : Bools width) : Nat := BitPacking.packBits (List.ofFn bits)
def vector (bits : Bools width) : BitVec width := BitVec.ofNat width (bitsValue bits)

theorem bits_bound (bits : Bools width) : bitsValue bits < 2^width := by
  simpa [bitsValue] using BitPacking.packed_bits_bounded (List.ofFn bits)

private theorem testBit_pack (bits : List Bool) (i : Nat) :
    (BitPacking.packBits bits).testBit i = bits.getD i false := by
  induction bits generalizing i with
  | nil => simp [BitPacking.packBits]
  | cons bit rest ih =>
    cases i with
    | zero => cases bit <;> simp [BitPacking.packBits,Nat.testBit_zero,Nat.add_mod]
    | succ i =>
      rw [Nat.testBit_succ]
      have divided : BitPacking.packBits (bit::rest) / 2 = BitPacking.packBits rest := by
        cases bit <;> simp [BitPacking.packBits,Nat.add_div]
      rw [divided,ih]
      rfl

theorem vector_bit (bits : Bools width) (i : Nat) (inside : i < width) :
    (vector bits).getLsbD i = bits ⟨i,inside⟩ := by
  rw [BitVec.getLsbD,vector,BitVec.toNat_ofNat,Nat.mod_eq_of_lt (bits_bound bits)]
  rw [bitsValue,testBit_pack]
  simp only [List.getD_eq_getElem?_getD,List.getElem?_ofFn,dite_eq_left inside,Option.getD_some]

theorem vector_value (bits : Bools width) : (vector bits).toNat = bitsValue bits := by
  simp [vector,Nat.mod_eq_of_lt (bits_bound bits)]

def wordBits (bytes : Fin 4 → Fin 8 → α) (i : Fin 32) : α :=
  bytes ⟨3-i.val/8,by omega⟩ ⟨i.val%8,Nat.mod_lt _ (by decide)⟩

theorem word_bit_list (bytes : Fin 4 → Bools 8) :
    List.ofFn (wordBits bytes) =
      List.ofFn (bytes 3) ++ List.ofFn (bytes 2) ++ List.ofFn (bytes 1) ++ List.ofFn (bytes 0) := by rfl

theorem pack_append (a b : List Bool) :
    BitPacking.packBits (a++b) = BitPacking.packBits a + 2^a.length * BitPacking.packBits b := by
  induction a with
  | nil => simp [BitPacking.packBits]
  | cons x xs ih =>
    simp only [List.cons_append,BitPacking.packBits,List.length_cons,Nat.pow_succ,ih,Nat.mul_add]
    ac_rfl

theorem word_value (bytes : Fin 4 → Bools 8) :
    bitsValue (wordBits bytes) = bitsValue (bytes 0)*2^24 + bitsValue (bytes 1)*2^16 +
      bitsValue (bytes 2)*2^8 + bitsValue (bytes 3) := by
  unfold bitsValue
  rw [word_bit_list]
  simp only [pack_append,List.length_append,List.length_ofFn]
  omega

theorem word_fips (bytes : Fin 4 → Bools 8) :
    ShaWordFips.word (wordBits bytes) = BitVec.ofNat 32
      ((vector (bytes 0)).toNat*2^24+(vector (bytes 1)).toNat*2^16+
       (vector (bytes 2)).toNat*2^8+(vector (bytes 3)).toNat) := by
  simp only [vector_value]
  rw [← word_value]
  rfl

theorem word_rep {F : Type} [CommRing F] (values : Nat → F)
    (bytes : Fin 4 → Fin 8 → Linear) (meanings : Fin 4 → Bools 8)
    (represented : ∀ b i, E values (bytes b i) = ((meanings b i).toNat : F)) :
    ∀ i, E values (wordBits bytes i) = ((wordBits meanings i).toNat : F) := by
  intro i
  exact represented _ _

def limb (words : Fin 4 → Linear) : Linear :=
  constant 0 ++ scale (words 3) ((1 : Nat) : Int) ++ scale (words 2) ((2^32 : Nat) : Int) ++
    scale (words 1) ((2^64 : Nat) : Int) ++ scale (words 0) ((2^96 : Nat) : Int)

def limbValue (words : Fin 4 → Nat) : Nat :=
  words 0*2^96+words 1*2^64+words 2*2^32+words 3

theorem limb_bound (words : Fin 4 → Nat) (bounds : ∀ i, words i < 2^32) : limbValue words < 2^128 := by
  have a := bounds 0; have b := bounds 1; have c := bounds 2; have d := bounds 3
  unfold limbValue
  omega

theorem limb_eval {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (words : Fin 4 → Linear) (numbers : Fin 4 → Nat)
    (represented : ∀ i, E values (words i) = (numbers i : F)) :
    E values (limb words) = (limbValue numbers : F) := by
  simp only [limb,E,FullMatrix.eval_append,FullMatrix.eval_scale,Ring.intCast_natCast]
  change E values (constant 0)+((1 : Nat) : F)*E values (words 3)+((2^32 : Nat) : F)*E values (words 2)+
    ((2^64 : Nat) : F)*E values (words 1)+((2^96 : Nat) : F)*E values (words 0) = _
  rw [eval_constant values one]
  simp only [represented,limbValue,Semiring.natCast_add,Semiring.natCast_mul]
  grind

theorem padded_scalar_value (bytes : List (Fin 256)) :
    ScalarEncoding.valueBE (List.replicate 16 0 ++ bytes) = ScalarEncoding.valueBE bytes := by
  have zeros (n : Nat) : packBytes (List.replicate n (0 : Fin 256)) = 0 := by
    induction n with
    | zero => rfl
    | succ n ih => simpa only [List.replicate_succ,packBytes,Fin.val_zero,Nat.zero_add,Nat.mul_zero] using congrArg (fun k => 256*k) ih
  simp only [ScalarEncoding.valueBE,List.reverse_append,List.reverse_replicate,ScalarWords.pack_append,zeros,
    Nat.mul_zero,Nat.add_zero]

theorem padded_scalar_canonical (bytes : List (Fin 256)) (length : bytes.length = 16) :
    ScalarEncoding.canonical (List.replicate 16 0 ++ bytes) = true := by
  apply (ScalarEncoding.canonical_iff _).mpr
  constructor
  · simp [length]
  · rw [padded_scalar_value]
    have bound := packed_bytes_below_capacity bytes.reverse
    have small : 256^16 < scalarModulus := by decide
    exact Nat.lt_trans (by simpa [ScalarEncoding.valueBE,length] using bound) small

theorem padded_scalar_decode {F : Type} [CommRing F] (bytes : List (Fin 256))
    (length : bytes.length = 16) (old : F) :
    ScalarEncoding.decodeInto (List.replicate 16 0 ++ bytes) old = (true,(ScalarEncoding.valueBE bytes : F)) := by
  unfold ScalarEncoding.decodeInto
  rw [padded_scalar_canonical bytes length]
  simp only [↓reduceIte,padded_scalar_value]

def lengthBits (bits : Bools 32) (offset : Fin 64) (i : Fin 8) : Bool :=
  if offset.val < 56 then false else
    let position := (63-offset.val)*8+i.val
    if h : 3 ≤ position ∧ position < 35 then bits ⟨position-3,by omega⟩ else false

def lengthByte (length : BitVec 32) (offset : Fin 64) : BitVec 8 :=
  if offset.val < 56 then 0 else
    (((length.setWidth 64) <<< 3) >>> ((63-offset.val)*8)).setWidth 8

theorem length_byte (bits : Bools 32) (offset : Fin 64) :
    vector (lengthBits bits offset) = lengthByte (vector bits) offset := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  rw [vector_bit _ _ inside]
  unfold lengthBits lengthByte
  by_cases tail : offset.val < 56
  · simp [tail]
  · simp only [tail,↓reduceIte,BitVec.getLsbD_setWidth,BitVec.getLsbD_ushiftRight,BitVec.getLsbD_shiftLeft]
    have off := offset.isLt
    let position := (63-offset.val)*8+i
    have posBound : position < 64 := by dsimp [position]; omega
    have same : (63-offset.val)*8+i = position := rfl
    change (if h : 3 ≤ position ∧ position < 35 then bits ⟨position-3,by omega⟩ else false) =
      (decide (i < 8) && (decide (position < 64) && !decide (position < 3) &&
        (decide (position-3 < 64) && (vector bits).getLsbD (position-3))))
    by_cases range : 3 ≤ position ∧ position < 35
    · have low : ¬ position < 3 := by omega
      have index : position-3 < 32 := by omega
      have wide : position-3 < 64 := by omega
      simp only [dite_eq_left range,decide_eq_true inside,decide_eq_true posBound,decide_eq_false low,
        decide_eq_true wide,Bool.not_false,Bool.true_and,vector_bit _ _ index]
    · by_cases low : position < 3
      · simp only [dite_eq_right range,decide_eq_true inside,decide_eq_true posBound,decide_eq_true low,
          Bool.not_true,Bool.true_and,Bool.false_and]
      · have high : 32 ≤ position-3 := by omega
        simp only [dite_eq_right range,BitVec.getLsbD_of_ge _ _ high,Bool.and_false]

theorem length_byte_value (length : BitVec 32) (offset : Fin 64) (tail : 56 ≤ offset.val) :
    (lengthByte length offset).toNat = (length.toNat*8 / 256^(63-offset.val))%256 := by
  have bounded : length.toNat < 2^32 := length.isLt
  have capacity : length.toNat < 2^64 := by omega
  have shifted := Sha256.length_field_fits length.toNat bounded
  have power : 2^((63-offset.val)*8) = 256^(63-offset.val) := by
    rw [Nat.mul_comm,Nat.pow_mul]
  simp only [lengthByte,show ¬ offset.val < 56 by omega,↓reduceIte,BitVec.toNat_setWidth,
    BitVec.toNat_ushiftRight,BitVec.toNat_shiftLeft,Nat.shiftRight_eq_div_pow,Nat.shiftLeft_eq]
  rw [Nat.mod_eq_of_lt capacity]
  change ((length.toNat*8)%2^64 / 2^((63-offset.val)*8))%256 = _
  rw [Nat.mod_eq_of_lt shifted,power]

def packLinear (bits : Fin width → Linear) : Linear :=
  constant 0 ++ GadgetShape.pack (BitPacking.bitWeights width) (List.ofFn bits)

theorem packLinear_eval {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (bits : Fin width → Linear) (meaning : Bools width)
    (represented : ∀ i, E values (bits i) = ((meaning i).toNat : F)) :
    E values (packLinear bits) = (bitsValue meaning : F) := by
  have mapped : (List.ofFn bits).map (E values) = (List.ofFn meaning).map (R1CS.boolValue (F := F)) := by
    simp only [List.map_ofFn]
    apply congrArg List.ofFn
    funext i
    cases h : meaning i <;>
      simpa [R1CS.boolValue,h,Semiring.natCast_zero,Semiring.natCast_one] using represented i
  rw [packLinear,show E values (constant 0 ++ GadgetShape.pack (BitPacking.bitWeights width) (List.ofFn bits)) =
    E values (constant 0) + E values (GadgetShape.pack (BitPacking.bitWeights width) (List.ofFn bits)) from FullMatrix.eval_append ..,
    eval_constant values one,Ring.intCast_zero,AddCommMonoid.zero_add,eval_pack,mapped,R1CS.weighted_booleans]
  have length : (List.ofFn meaning).length = width := by simp
  simpa only [bitsValue,← length] using congrArg (fun n : Nat => (n : F))
    (BitPacking.binary_weights_encode_bits (List.ofFn meaning))

def lengthWiring (bits : Fin 32 → Linear) (offset : Fin 64) : Linear :=
  if offset.val < 56 then constant 0 else packLinear (fun i : Fin 8 =>
    let p := (63-offset.val)*8+i.val
    if h : 3 ≤ p ∧ p < 35 then bits ⟨p-3,by omega⟩ else constant 0)

theorem lengthWiring_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (bits : Fin 32 → Linear) (meaning : Bools 32) (offset : Fin 64)
    (represented : ∀ i, E values (bits i) = ((meaning i).toNat : F)) :
    E values (lengthWiring bits offset) = ((lengthByte (vector meaning) offset).toNat : F) := by
  by_cases beforeField : offset.val < 56
  · simp [lengthWiring,lengthByte,beforeField,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  · have bytes : E values (lengthWiring bits offset) = (bitsValue (lengthBits meaning offset) : F) := by
      unfold lengthWiring
      rw [ite_eq_right beforeField]
      apply packLinear_eval values one
      intro i
      dsimp [lengthBits]
      rw [ite_eq_right beforeField]
      split
      · exact represented _
      · simp [eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
    rw [bytes,← vector_value (lengthBits meaning offset),length_byte]

def byteInput (byte : Fin 4) (bit : Fin 8) : Linear := wire (5+8*byte.val+bit.val)
def wordInput (i : Fin 4) : Linear := wire (i.val+1)

def wordArtifact : Artifact :=
  let bits := wordBits byteInput
  let output := wire 37
  let ranges := (List.range 4).flatMap (fun i => rangeGates (wire (i+1)) (5+8*i) 8)
  ⟨{ wires := 38,publicCount := 4,gates := (ranges++[eqGate output (packLinear bits)]).toArray },
    output :: List.ofFn bits⟩

def limbArtifact : Artifact :=
  let ranges := (List.range 4).flatMap (fun i => rangeGates (wire (i+1)) (5+32*i) 32)
  ⟨{ wires := 133,publicCount := 4,gates := ranges.toArray },[limb wordInput]⟩

def lengthArtifact (offset : Fin 64) : Artifact :=
  ⟨{ wires := 34,publicCount := 1,gates := (rangeGates (wire 1) 2 32).toArray },
    [lengthWiring (fun i => wire (2+i.val)) offset]⟩

def artifact (kind parameter : Nat) : Artifact :=
  if kind = 0 then wordArtifact else if kind = 1 then limbArtifact else lengthArtifact ⟨parameter%64,Nat.mod_lt _ (by decide)⟩

def cases : List (Nat × Nat) := [(0,0),(1,0)] ++ (List.range 64).map (fun i => (2,i))

theorem checked_relation {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (actual : Artifact) (kind parameter : Nat) (checked : conforms actual (artifact kind parameter) = true)
    (values : Nat → F) (satisfied : Satisfied actual.shape values) :
    Satisfied (artifact kind parameter).shape values ∧
      actual.outputs.map (E values) = (artifact kind parameter).outputs.map (E values) := by
  have relation := conformance_relation actual (artifact kind parameter) checked values
  exact ⟨relation.1.mp satisfied,relation.2⟩

#print axioms word_fips
#print axioms word_rep
#print axioms limb_eval
#print axioms padded_scalar_decode
#print axioms length_byte
#print axioms length_byte_value
#print axioms lengthWiring_sound
#print axioms checked_relation

end ZkBuild.ShaBoundary
