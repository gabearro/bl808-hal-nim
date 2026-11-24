import TokenInteger

namespace ZkBuild.PackedFields
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Record where
  lowWidth : Nat
  highWidth : Nat
  firstGate : Nat
  lastGate : Nat
  value : Linear
  low : Linear
  high : Linear
  range : RangeUse.Record
  deriving Inhabited

def lowTerm (r : Record) : Linear := pack (BitPacking.bitWeights r.lowWidth) ((RangeUse.bits r.range).take r.lowWidth)
def highTerm (r : Record) : Linear := pack (BitPacking.bitWeights r.highWidth) ((RangeUse.bits r.range).drop r.lowWidth)
def gates (r : Record) : List Gate := [eqGate r.low (lowTerm r),eqGate r.high (highTerm r)]
def check (matrix : Shape) (r : Record) : Bool :=
  decide (0 < r.lowWidth ∧ 0 < r.highWidth ∧ r.lowWidth+r.highWidth ≤ 64) &&
  RangeUse.check matrix r.range r.value (r.lowWidth+r.highWidth) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (gates r)

theorem packed_append (a b : List Bool) : BitPacking.packBits (a++b) =
    BitPacking.packBits a+2^a.length*BitPacking.packBits b := by
  induction a with
  | nil => simp [BitPacking.packBits]
  | cons x xs ih =>
    simp only [List.cons_append,BitPacking.packBits,ih,List.length_cons,Nat.pow_succ,Nat.mul_assoc,Nat.mul_left_comm]
    omega

private theorem packed_image {F : Type} [Field F] (values : Nat → F)
    (bits : List Linear) (decoded : List Bool) (same : bits.map (E values) = decoded.map (R1CS.boolValue (F := F))) :
    E values (pack (BitPacking.bitWeights decoded.length) bits) = (BitPacking.packBits decoded : F) := by
  rw [eval_pack,same,R1CS.weighted_booleans,BitPacking.binary_weights_encode_bits]

theorem checked_split {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ value low high : Nat, value < 2^(r.lowWidth+r.highWidth) ∧ low < 2^r.lowWidth ∧ high < 2^r.highWidth ∧
      E values r.value = (value : F) ∧ E values r.low = (low : F) ∧ E values r.high = (high : F) ∧
      value = low+2^r.lowWidth*high ∧ low = value % 2^r.lowWidth ∧ high = value / 2^r.lowWidth := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have first := Bool.and_eq_true_iff.mp parts.1
  have certificate := RangeUse.checked_certificate matrix r.range r.value _ first.2 values oneValue satisfied
  obtain ⟨decoded,same⟩ := R1CS.constrained_bits_are_booleans _ certificate.2.1
  have length : decoded.length = r.lowWidth+r.highWidth := by
    have n := congrArg List.length same
    simpa only [List.length_map,certificate.1] using n.symm
  have size : (RangeUse.bits r.range).length = r.lowWidth+r.highWidth := by simpa using certificate.1
  have lowSize : (decoded.take r.lowWidth).length = r.lowWidth := by simp [length]
  have highSize : (decoded.drop r.lowWidth).length = r.highWidth := by simp [length]
  have whole : E values r.value = (BitPacking.packBits decoded : F) := by
    rw [← certificate.2.2,same,R1CS.weighted_booleans,← length,BitPacking.binary_weights_encode_bits]
  have lowBits : ((RangeUse.bits r.range).take r.lowWidth).map (E values) = (decoded.take r.lowWidth).map (R1CS.boolValue (F := F)) := by
    simpa only [List.map_take] using congrArg (List.take r.lowWidth) same
  have highBits : ((RangeUse.bits r.range).drop r.lowWidth).map (E values) = (decoded.drop r.lowWidth).map (R1CS.boolValue (F := F)) := by
    simpa only [List.map_drop] using congrArg (List.drop r.lowWidth) same
  have holds := MemoryEvidence.span_sound matrix r.firstGate r.lastGate (gates r) parts.2 values satisfied
  have lowEq := equality_sound values oneValue r.low (lowTerm r) (holds _ (by simp [gates]))
  have highEq := equality_sound values oneValue r.high (highTerm r) (holds _ (by simp [gates]))
  have lowImage : E values r.low = (BitPacking.packBits (decoded.take r.lowWidth) : F) := by
    rw [lowEq,lowTerm]
    simpa only [lowSize] using packed_image values _ _ lowBits
  have highImage : E values r.high = (BitPacking.packBits (decoded.drop r.lowWidth) : F) := by
    rw [highEq,highTerm]
    simpa only [highSize] using packed_image values _ _ highBits
  let n := BitPacking.packBits decoded
  let lo := BitPacking.packBits (decoded.take r.lowWidth)
  let hi := BitPacking.packBits (decoded.drop r.lowWidth)
  have nb : n < 2^(r.lowWidth+r.highWidth) := by simpa [n,length] using BitPacking.packed_bits_bounded decoded
  have lb : lo < 2^r.lowWidth := by simpa [lo,lowSize] using BitPacking.packed_bits_bounded (decoded.take r.lowWidth)
  have hb : hi < 2^r.highWidth := by simpa [hi,highSize] using BitPacking.packed_bits_bounded (decoded.drop r.lowWidth)
  have together : n = lo+2^r.lowWidth*hi := by
    have joined := packed_append (decoded.take r.lowWidth) (decoded.drop r.lowWidth)
    simpa [List.take_append_drop,lowSize] using joined
  refine ⟨n,lo,hi,nb,lb,hb,whole,lowImage,highImage,together,?_,?_⟩
  · simp [together,Nat.add_mod,Nat.mod_eq_of_lt lb]
  · rw [together,Nat.add_mul_div_left lo hi (Nat.two_pow_pos _),Nat.div_eq_of_lt lb,Nat.zero_add]

#print axioms packed_append
#print axioms checked_split
end ZkBuild.PackedFields
