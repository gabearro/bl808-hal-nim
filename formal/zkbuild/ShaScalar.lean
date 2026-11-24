import ShaPadding

namespace ZkBuild.ShaScalar

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def materialize (value : Linear) : Build Linear := fun start =>
  ⟨wire start,start+1,[eqGate (wire start) value]⟩

def multiply (a b : Linear) : Build Linear := fun start =>
  ⟨wire start,start+1,[mulGate a b (wire start)]⟩

def zero (value : Linear) : Build Linear := fun start =>
  ⟨wire start,start+2,zeroGates value (wire start) (wire (start+1))⟩

def range (width : Nat) (value : Linear) : Build (Fin width → Linear) := fun start =>
  ⟨fun i => wire (start+i.val),start+width,rangeGates value start width⟩

def constrain (a b c : Linear) : Build Unit := fun start => ⟨(),start,[⟨a,b,c⟩]⟩
def equal (a b : Linear) : Build Unit := fun start => ⟨(),start,[eqGate a b]⟩

theorem materialize_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (value : Linear) :
    Ensures values (materialize value) (fun output => E values output = E values value) := by
  constructor
  intro start holds
  exact equality_sound values one _ _ (holds _ (by simp [materialize]))

theorem multiply_sound {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    Ensures values (multiply a b) (fun output => E values output = E values a * E values b) := by
  constructor
  intro start holds
  exact GadgetShape.multiply_sound values _ _ _ (holds _ (by simp [multiply]))

theorem zero_sound {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (one : values 0 = 1) (value : Linear) :
    Ensures values (zero value) (fun output => E values output = if E values value = 0 then 1 else 0) := by
  constructor
  intro start holds
  exact GadgetShape.zero_sound values one _ _ _ holds

theorem equal_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (a b : Linear) :
    Ensures values (equal a b) (fun _ => E values a = E values b) := by
  constructor
  intro start holds
  exact equality_sound values one _ _ (holds _ (by simp [equal]))

theorem constrain_sound {F : Type} [CommRing F] (values : Nat → F) (a b c : Linear) :
    Ensures values (constrain a b c) (fun _ => E values a * E values b = E values c) := by
  constructor
  intro start holds
  exact holds ⟨a,b,c⟩ (by simp [constrain])

private theorem list_of_getD (xs : List α) (n : Nat) (length : xs.length = n) (fallback : α) :
    List.ofFn (fun i : Fin n => xs.getD i.val fallback) = xs := by
  apply List.ext_getElem
  · simp [length]
  · intro i h₁ h₂
    rw [List.getElem_ofFn]
    exact (List.getElem_eq_getD fallback).symm

def RepresentsBits {F : Type} [CommRing F] (values : Nat → F) (wires : Fin width → Linear)
    (bits : ShaBoundary.Bools width) : Prop := ∀ i, E values (wires i) = ((bits i).toNat : F)

theorem certificate_rep {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (width n : Nat) (wires : Fin width → Linear)
    (small : width ≤ 248) (bounded : n < 2^width)
    (certificate : RangeReuse.Certificate width (n : F) ((List.ofFn wires).map (E values))) :
    ∃ bits : ShaBoundary.Bools width, RepresentsBits values wires bits ∧ ShaBoundary.bitsValue bits = n := by
  obtain ⟨decoded,decode⟩ := R1CS.constrained_bits_are_booleans _ certificate.2.1
  have length : decoded.length = width := by simpa [decode] using certificate.1
  let bits : ShaBoundary.Bools width := fun i => decoded.getD i.val false
  have list : List.ofFn bits = decoded := list_of_getD decoded width length false
  have represented : RepresentsBits values wires bits := by
    intro i
    have read := congrArg (fun xs : List F => xs.getD i.val 0) decode
    have get : (decoded.map (R1CS.boolValue (F := F))).getD i.val 0 = ((bits i).toNat : F) := by
      cases h : decoded[i.val]? with
      | none => simp [List.getD_eq_getElem?_getD,h,bits]
      | some b => cases b <;> simp [List.getD_eq_getElem?_getD,h,bits,R1CS.boolValue]
    rw [get] at read
    simpa [List.map_ofFn,List.getD_eq_getElem?_getD,List.getElem?_ofFn,i.isLt] using read
  have field : (ShaBoundary.bitsValue bits : F) = (n : F) := by
    have binding := certificate.2.2
    rw [decode,R1CS.weighted_booleans,← length,BitPacking.binary_weights_encode_bits] at binding
    simpa [ShaBoundary.bitsValue,list] using binding
  have upper := RangeConstraints.power_below_modulus width small
  exact ⟨bits,represented,(IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans (ShaBoundary.bits_bound bits) upper) (Nat.lt_trans bounded upper)).mp field⟩

theorem range_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (value : Linear) (width n : Nat)
    (small : width ≤ 248) (bounded : n < 2^width) (image : E values value = (n : F)) :
    Ensures values (range width value) (fun output => ∃ bits : ShaBoundary.Bools width,
      RepresentsBits values output bits ∧ ShaBoundary.bitsValue bits = n) := by
  constructor
  intro start holds
  have cert := range_certificate values one value start width holds
  obtain ⟨decoded,decode⟩ := R1CS.constrained_bits_are_booleans _ cert.2.1
  have length : decoded.length = width := by simpa [decode] using cert.1
  let bits : ShaBoundary.Bools width := fun i => decoded.getD i.val false
  have list : List.ofFn bits = decoded := list_of_getD decoded width length false
  have represented : RepresentsBits values (range width value start).value bits := by
    intro i
    have read := congrArg (fun xs : List F => xs.getD i.val 0) decode
    have get : (decoded.map (R1CS.boolValue (F := F))).getD i.val 0 = ((bits i).toNat : F) := by
      cases h : decoded[i.val]? with
      | none => simp [List.getD_eq_getElem?_getD,h,bits]
      | some b => cases b <;> simp [List.getD_eq_getElem?_getD,h,bits,R1CS.boolValue]
    rw [get] at read
    simpa [range,rangeBits,i.isLt] using read
  have field : (ShaBoundary.bitsValue bits : F) = (n : F) := by
    have binding := cert.2.2
    rw [decode,R1CS.weighted_booleans,← length,BitPacking.binary_weights_encode_bits,image] at binding
    simpa [ShaBoundary.bitsValue,list] using binding
  have upper := RangeConstraints.power_below_modulus width small
  have exactValue := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans (ShaBoundary.bits_bound bits) upper) (Nat.lt_trans bounded upper)).mp field
  exact ⟨bits,represented,exactValue⟩

theorem range_certificate_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (value : Linear) (width : Nat) :
    Ensures values (range width value) (fun output =>
      RangeReuse.Certificate width (E values value) ((List.ofFn output).map (E values))) := by
  constructor
  intro start holds
  have same : List.ofFn (range width value start).value = rangeBits start width := by
    apply List.ext_getElem
    · simp [range,rangeBits]
    · intro i h₁ h₂
      simp only [range,rangeBits,List.getElem_ofFn,List.getElem_map,List.getElem_range]
  rw [same]
  exact range_certificate values one value start width holds

theorem nat_zero_test {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (a b : Nat) (ha : a < scalarModulus) (hb : b < scalarModulus) :
    (if (a : F)-(b : F) = 0 then (1 : F) else 0) = if a = b then 1 else 0 := by
  have equal : (a : F)-(b : F) = 0 ↔ a = b := by
    constructor
    · intro h
      apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus ha hb).mp
      grind
    · intro h
      subst b
      grind
  simp only [equal]

#print axioms materialize_sound
#print axioms zero_sound
#print axioms range_sound
#print axioms certificate_rep
#print axioms range_certificate_sound
#print axioms nat_zero_test

end ZkBuild.ShaScalar
