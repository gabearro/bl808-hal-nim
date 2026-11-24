import ShaHash

namespace ZkBuild.ShaHashLength

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram ShaHash
attribute [local instance] Ring.intCast Semiring.natCast

def low (bits : ShaBoundary.Bools 32) : ShaBoundary.Bools 6 := fun i => bits ⟨i.val,by omega⟩
def high (bits : ShaBoundary.Bools 32) : ShaBoundary.Bools 26 := fun i => bits ⟨i.val+6,by omega⟩

theorem split_bits (bits : ShaBoundary.Bools 32) :
    List.ofFn bits = List.ofFn (low bits) ++ List.ofFn (high bits) := by rfl

theorem split_value (bits : ShaBoundary.Bools 32) :
    ShaBoundary.bitsValue bits = ShaBoundary.bitsValue (low bits)+64*ShaBoundary.bitsValue (high bits) := by
  unfold ShaBoundary.bitsValue
  rw [split_bits,ShaBoundary.pack_append]
  simp

theorem high_value (bits : ShaBoundary.Bools 32) :
    ShaBoundary.bitsValue (high bits) = ShaBoundary.bitsValue bits/64 := by
  have equation := split_value bits
  have small := ShaBoundary.bits_bound (low bits)
  omega

theorem low_value (bits : ShaBoundary.Bools 32) :
    ShaBoundary.bitsValue (low bits) = ShaBoundary.bitsValue bits%64 := by
  have equation := split_value bits
  have small := ShaBoundary.bits_bound (low bits)
  omega

theorem bit_digit (bits : ShaBoundary.Bools width) (i : Fin width) :
    (bits i).toNat = (ShaBoundary.bitsValue bits/2^i.val)%2 := by
  have meaning := congrArg Bool.toNat (ShaBoundary.vector_bit bits i.val i.isLt)
  rw [BitVec.getLsbD,ShaBoundary.vector_value,Nat.testBit_eq_decide_div_mod_eq] at meaning
  have bound := Nat.mod_lt (ShaBoundary.bitsValue bits/2^i.val) (by decide : 0 < 2)
  have choice : (ShaBoundary.bitsValue bits/2^i.val)%2 = 0 ∨ (ShaBoundary.bitsValue bits/2^i.val)%2 = 1 := by omega
  rcases choice with value | value <;> simpa [value] using meaning.symm

theorem extra_value (bits : ShaBoundary.Bools 32) :
    (bits 3).toNat*(bits 4).toNat*(bits 5).toNat =
      if ShaBoundary.bitsValue bits%64 < 56 then 0 else 1 := by
  let small := low bits
  let n := ShaBoundary.bitsValue small
  have bound : n < 64 := ShaBoundary.bits_bound small
  have a := bit_digit small ⟨3,by decide⟩
  have b := bit_digit small ⟨4,by decide⟩
  have c := bit_digit small ⟨5,by decide⟩
  have formula := Sha256.carry_bit_formula ⟨n,bound⟩
  change (small 3).toNat = n/8%2 at a
  change (small 4).toNat = n/16%2 at b
  change (small 5).toNat = n/32%2 at c
  change n/8%2*(n/16%2)*(n/32) = (if n < 56 then 0 else 1) at formula
  have last : n/32%2 = n/32 := Nat.mod_eq_of_lt (by omega)
  rw [last] at c
  rw [← low_value]
  change (small 3).toNat*(small 4).toNat*(small 5).toNat = _
  rw [a,b,c]
  exact formula

theorem capacity_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (capacity n : Nat) (length : Linear)
    (capacityBound : capacity < 2^32) (bounded : n < 2^32) (image : E values length = (n : F))
    (bits : List F) (certificate : RangeReuse.Certificate 32
      (E values (sub (constant (Int.ofNat capacity)) length)) bits) : n ≤ capacity := by
  obtain ⟨delta,deltaBound,equation⟩ := RangeReuse.certificate_sound _ _ _ certificate
  have constantImage : E values (constant (Int.ofNat capacity)) = (capacity : F) := by
    rw [eval_constant values one]
    exact Ring.intCast_natCast capacity
  rw [eval_sub,constantImage,image] at equation
  have field : (capacity : F) = ((n+delta : Nat) : F) := by
    simp only [Semiring.natCast_add]
    grind
  have modulus : 2^33 < scalarModulus := by decide
  have aBound : capacity < scalarModulus := by omega
  have bBound : n+delta < scalarModulus := by omega
  have same := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp field
  omega

theorem prepare_bits_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (capacity n : Nat) (length : Linear)
    (wires : Fin 32 → Linear) (bits : ShaBoundary.Bools 32)
    (capacityBound : capacity < 2^32) (bounded : n < 2^32) (image : E values length = (n : F))
    (represented : ShaScalar.RepresentsBits values wires bits) (nValue : ShaBoundary.bitsValue bits = n) :
    Ensures values (prepareBitsM capacity length wires) (fun context =>
      ShaScalar.RepresentsBits values context.bits bits ∧ ShaBoundary.bitsValue bits = n ∧ n ≤ capacity ∧
      E values context.last = (ShaPadding.lastBlock n : F)) := by
  unfold prepareBitsM
  apply bind_sound values _ _ _ _ (ShaScalar.range_certificate_sound values one _ 32)
  intro unused ignored
  apply bind_sound values _ _ _ _ (ShaScalar.multiply_sound values (wires 3) (wires 4))
  intro a ha
  apply bind_sound values _ _ _ _ (ShaScalar.multiply_sound values a (wires 5))
  intro b hb
  apply bind_sound values _ _ _ _ (ShaScalar.materialize_sound values one _)
  intro last hlast
  apply pure_sound
  refine ⟨represented,nValue,capacity_sound values one capacity n length capacityBound bounded image _ ignored,?_⟩
  have highRep : E values (ShaBoundary.packLinear (fun i : Fin 26 => wires ⟨i.val+6,by omega⟩)) =
      (ShaBoundary.bitsValue (high bits) : F) := by
    apply ShaBoundary.packLinear_eval values one
    intro i
    exact represented _
  have extra : E values b = (((bits 3).toNat*(bits 4).toNat*(bits 5).toNat : Nat) : F) := by
    rw [hb,ha,represented 3,represented 4,represented 5]
    simp only [Semiring.natCast_mul]
  rw [show E values (ShaBoundary.packLinear (fun i : Fin 26 => wires ⟨i.val+6,by omega⟩) ++ b) =
      E values (ShaBoundary.packLinear (fun i : Fin 26 => wires ⟨i.val+6,by omega⟩))+E values b from FullMatrix.eval_append ..,
    highRep,extra,high_value,extra_value,nValue] at hlast
  rw [← Semiring.natCast_add] at hlast
  simpa [ShaPadding.lastBlock] using hlast


theorem prepare_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (capacity n : Nat) (length : Linear)
    (capacityBound : capacity < 2^32) (bounded : n < 2^32) (image : E values length = (n : F)) :
    Ensures values (prepareM capacity length) (fun context => ∃ bits : ShaBoundary.Bools 32,
      ShaScalar.RepresentsBits values context.bits bits ∧ ShaBoundary.bitsValue bits = n ∧ n ≤ capacity ∧
      E values context.last = (ShaPadding.lastBlock n : F)) := by
  unfold prepareM
  apply bind_sound values _ _ _ _ (ShaScalar.range_sound values one length 32 n (by decide) bounded image)
  intro wires meaning
  obtain ⟨bits,represented,nValue⟩ := meaning
  constructor
  intro start holds
  exact ⟨bits,(prepare_bits_sound values one capacity n length wires bits capacityBound bounded image represented nValue).run start holds⟩

#print axioms high_value
#print axioms extra_value
#print axioms capacity_sound
#print axioms prepare_sound

end ZkBuild.ShaHashLength
