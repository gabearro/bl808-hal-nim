import StaticLookupEmbedded
import TokenInteger
set_option autoImplicit false
namespace ZkBuild.StaticLookupSound
open Lean.Grind CircuitShape FullMatrix GadgetShape StaticLookupEmbedded
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

private theorem append_getD {α : Type} (xs ys : List α) (i : Nat) (fallback : α) :
    (xs++ys).getD i fallback = if i < xs.length then xs.getD i fallback else ys.getD (i-xs.length) fallback := by
  simp only [List.getD_eq_getElem?_getD,List.getElem?_append]
  split <;> rfl

private theorem joined {F : Type} [Field F] (values : Nat → F) (lo hi : List Linear)
    (width low high : Nat) (len : lo.length = width) (bound : low < 2^width)
    (loImage : ∀ i, E values (BinaryTokenMatrix.atBit lo i) = if low.testBit i then 1 else 0)
    (hiImage : ∀ i, E values (BinaryTokenMatrix.atBit hi i) = if high.testBit i then 1 else 0) :
    ∀ i, E values (BinaryTokenMatrix.atBit (lo++hi) i) = if (low+2^width*high).testBit i then 1 else 0 := by
  intro i
  have packed := Nat.testBit_two_pow_mul_add high bound i
  rw [Nat.add_comm] at packed
  rw [packed]
  simp only [BinaryTokenMatrix.atBit,append_getD,len]
  by_cases small : i < width
  · simpa only [BinaryTokenMatrix.atBit,small,↓reduceIte] using loImage i
  · simpa only [BinaryTokenMatrix.atBit,small,↓reduceIte] using hiImage (i-width)

theorem decoded_bits {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ opcode index actual : Nat, opcode < 65536 ∧ index < 4 ∧ actual < 8 ∧
      E values (r.inputs.getD 0 []) = (opcode : F) ∧ E values (r.outputs.getD 6 []) = (index : F) ∧
      E values (r.inputs.getD 2 []) = (actual : F) ∧
      ∀ i, E values (LookupMatrix.bitAt (bits r) i) = if (opcode*32+(index*8+actual)).testBit i then 1 else 0 := by
  have h := accepted
  simp only [check,Bool.and_eq_true_iff,decide_eq_true_eq] at h
  rcases h with ⟨⟨⟨⟨shape,opCheck⟩,typeCheck⟩,bitCheck⟩,_⟩
  rcases shape with ⟨_,_,_,_,_,_,_,_,_,lowEq,_,_,indexEq,_⟩
  have opCertificate := RangeUse.checked_certificate matrix r.opcodeRange _ 16 opCheck values one satisfied
  have typeCertificate := RangeUse.checked_certificate matrix r.typeRange _ 3 typeCheck values one satisfied
  have typeLength : (RangeUse.bits r.typeRange).length = 3 := by simpa only [List.length_map] using typeCertificate.1
  obtain ⟨opcode,opBound,opImage,opBits⟩ := TokenInteger.certificate_nat values one _ _ 16 opCertificate
  obtain ⟨actual,typeBound,typeImage,typeBits⟩ := TokenInteger.certificate_nat values one _ _ 3 typeCertificate
  have bitHolds := MemoryEvidence.span_sound matrix _ _ _ bitCheck values satisfied
  have lowCertificate : RangeReuse.Certificate 2 (E values (r.outputs.getD 6 [])) (r.lowBits.map (E values)) := by
    rw [indexEq,lowEq]
    constructor
    · rfl
    constructor
    · intro value member
      rcases List.mem_cons.mp member with ha | ha
      · subst value
        have b := bitHolds (boolGate (wire (r.firstWire-2))) (by simp [lowEq])
        rcases boolean_sound values one _ b with zero | one
        · rw [zero]; grind
        · rw [one]; grind
      · rcases List.mem_cons.mp ha with hb | hb
        · subst value
          have b := bitHolds (boolGate (wire (r.firstWire-1))) (by simp [lowEq])
          rcases boolean_sound values one _ b with zero | one
          · rw [zero]; grind
          · rw [one]; grind
        · contradiction
    · simp [BitPacking.bitWeights,R1CS.weightedValues,eval_append,eval_scale]
      grind
  obtain ⟨index,indexBound,indexImage,indexBits⟩ := TokenInteger.certificate_nat values one _ _ 2 lowCertificate
  have lowLength : r.lowBits.length = 2 := by rw [lowEq]; rfl
  have lower := joined values (RangeUse.bits r.typeRange) r.lowBits 3 actual index typeLength typeBound typeBits indexBits
  have operandBound : actual+2^3*index < 2^5 := by omega
  have all := joined values (RangeUse.bits r.typeRange++r.lowBits) (RangeUse.bits r.opcodeRange) 5
    (actual+2^3*index) opcode (by simp [List.length_append,typeLength,lowLength]) operandBound lower opBits
  refine ⟨opcode, index, actual,opBound,indexBound,typeBound,opImage,indexImage,typeImage,?_⟩
  intro i
  have keyEq : actual+2^3*index+2^5*opcode = opcode*32+(index*8+actual) := by omega
  simpa only [bits,LookupMatrix.bitAt,BinaryTokenMatrix.atBit,BinaryTokenMatrix.zero,keyEq] using all i

theorem output {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (table : checkTable r = true) (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (opcode index actual : Nat) (codeBound : opcode < 65536) (admitted : OpcodeCatalog.admitted opcode = true)
    (indexBound : index < 4) (actualBound : actual < 8)
    (images : ∀ i, E values (LookupMatrix.bitAt (bits r) i) = if (opcode*32+(index*8+actual)).testBit i then 1 else 0) :
    (r.outputs.take 6).map (E values) = (List.range 6).map (fun field => (expected opcode index actual field : F)) := by
  have h := accepted
  simp only [check,Bool.and_eq_true_iff,decide_eq_true_eq] at h
  rcases h with ⟨⟨⟨⟨shape,_⟩,_⟩,_⟩,gateCheck⟩
  have outEq := shape.2.2.2.2.2.2.2.2.2.2.2.1
  have run := (StaticLookupMatrix.program_sound values one 6 r.root (bits r) r.nodes _ images).run r.firstWire
    (MemoryEvidence.span_sound matrix _ _ _ gateCheck values satisfied)
  change (r.outputs.take 6).map (E values) = _
  rw [outEq]
  change (StaticLookupMatrix.program 6 r.root (bits r) r.nodes r.firstWire).value.map (E values) = _
  rw [run]
  apply List.map_congr_left
  intro field member
  have fBound : field < 6 := List.mem_range.mp member
  have value := table_value r table opcode (index*8+actual) field codeBound admitted (by omega) fBound
  have qi : (index*8+actual)/8 = index := by omega
  have qr : (index*8+actual)%8 = actual := by omega
  rw [value,qi,qr]
#print axioms decoded_bits
#print axioms output
end ZkBuild.StaticLookupSound
