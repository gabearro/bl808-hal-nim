import ShaWordMatrix

namespace ZkBuild.ShaWordFips

open ShaWordMatrix

def word (bits : Bits) : Sha256.Word := BitVec.ofNat 32 (packed bits)

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

theorem word_bit (bits : Bits) (i : Nat) (inside : i < 32) :
    (word bits).getLsbD i = bits ⟨i,inside⟩ := by
  rw [BitVec.getLsbD,word,BitVec.toNat_ofNat,Nat.mod_eq_of_lt (packed_bound bits)]
  rw [packed,testBit_pack]
  simp only [List.getD_eq_getElem?_getD,List.getElem?_ofFn,dite_eq_left inside,Option.getD_some]

theorem word_value (bits : Bits) : (word bits).toNat = packed bits := by
  simp [word,Nat.mod_eq_of_lt (packed_bound bits)]

theorem word_xor3 (x y z : Bits) :
    word (fun i => Bool.xor (Bool.xor (x i) (y i)) (z i)) = word x ^^^ word y ^^^ word z := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  simp only [BitVec.getLsbD_xor,word_bit _ _ inside]

theorem word_choose (x y z : Bits) :
    word (fun i => if x i then y i else z i) = Sha256.choose (word x) (word y) (word z) := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  simp only [Sha256.choose,BitVec.getLsbD_xor,BitVec.getLsbD_and,BitVec.getLsbD_not,
    word_bit _ _ inside,decide_eq_true inside,Bool.true_and]
  cases x ⟨i,inside⟩ <;> cases y ⟨i,inside⟩ <;> cases z ⟨i,inside⟩ <;> decide

theorem word_majority (x y z : Bits) :
    word (fun i => (x i && y i) || (x i && z i) || (y i && z i)) =
      Sha256.majority (word x) (word y) (word z) := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  simp only [Sha256.majority,BitVec.getLsbD_xor,BitVec.getLsbD_and,word_bit _ _ inside]
  cases x ⟨i,inside⟩ <;> cases y ⟨i,inside⟩ <;> cases z ⟨i,inside⟩ <;> decide

theorem word_add (x y result : Bits) (value : packed result = (packed x+packed y)%2^32) :
    word result = word x + word y := by
  apply BitVec.eq_of_toNat_eq
  simpa only [BitVec.toNat_add,word_value] using value

theorem word_sum (inputs : List Bits) (result : Bits)
    (value : packed result = (inputs.map packed).sum % 2^32) :
    word result = (inputs.map word).sum := by
  have sum : (inputs.map word).sum = BitVec.ofNat 32 (inputs.map packed).sum := by
    clear value
    induction inputs with
    | nil => rfl
    | cons x xs ih =>
      simp only [List.map_cons,List.sum_cons,ih,word,BitVec.ofNat_add_ofNat]
  rw [sum]
  apply BitVec.eq_of_toNat_eq
  simpa only [word_value,BitVec.toNat_ofNat] using value

theorem word_shift (bits : Bits) (amount : Nat) :
    word (fun i => if h : i.val+amount < 32 then bits ⟨i.val+amount,h⟩ else false) =
      word bits >>> amount := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  rw [word_bit _ _ inside,BitVec.getLsbD_ushiftRight]
  rw [Nat.add_comm amount i]
  change (if h : i+amount < 32 then bits ⟨i+amount,h⟩ else false) = (word bits).getLsbD (i+amount)
  split
  · exact (word_bit bits _ _).symm
  · exact (BitVec.getLsbD_of_ge (word bits) (i+amount) (by omega)).symm

theorem word_rotate (bits : Bits) (amount : Nat) (small : amount < 32) :
    word (fun i => bits ⟨(i.val+amount)%32,Nat.mod_lt _ (by decide)⟩) =
      Sha256.rotate (word bits) amount := by
  apply BitVec.eq_of_getLsbD_eq
  intro i inside
  rw [word_bit _ _ inside,Sha256.rotate,BitVec.getLsbD_or,BitVec.getLsbD_ushiftRight,
    BitVec.getLsbD_shiftLeft]
  rw [Nat.add_comm amount i]
  by_cases wrap : i+amount < 32
  · have left : i < 32-amount := by omega
    rw [word_bit bits _ wrap]
    simp [inside,left,Nat.mod_eq_of_lt wrap]
  · have beyond : 32 ≤ i+amount := by omega
    have left : ¬ i < 32-amount := by omega
    have shifted : i-(32-amount) < 32 := by omega
    have index : (i+amount)%32 = i-(32-amount) := by omega
    rw [BitVec.getLsbD_of_ge (word bits) (i+amount) beyond,word_bit bits _ shifted]
    simp [inside,left,index]

#print axioms word_bit
#print axioms word_xor3
#print axioms word_choose
#print axioms word_majority
#print axioms word_add
#print axioms word_sum
#print axioms word_shift
#print axioms word_rotate

end ZkBuild.ShaWordFips
