import MemoryPermutation

namespace ZkBuild.MemoryEvidence

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

-- The matrix is kept intact: evidence names spans in that same matrix.
def fragment (matrix : Shape) (first last : Nat) : Artifact :=
  ⟨{ wires := matrix.wires,gates := matrix.gates.extract first last },[]⟩

def checkSpan (matrix : Shape) (first last : Nat) (expected : List Gate) : Bool :=
  decide (first ≤ last ∧ last ≤ matrix.gates.size) &&
    conforms (fragment matrix first last) ⟨{ wires := matrix.wires,gates := expected.toArray },[]⟩

theorem span_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (first last : Nat) (expected : List Gate)
    (checked : checkSpan matrix first last expected = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values expected := by
  have actual : Satisfied (fragment matrix first last).shape values := by
    intro gate member
    have inside : gate ∈ matrix.gates.toList := by
      simp only [fragment,Array.toList_extract,List.extract_eq_take_drop] at member
      exact List.mem_of_mem_drop (List.mem_of_mem_take member)
    exact satisfied gate inside
  have relation := conformance_relation _ _ (Bool.and_eq_true_iff.mp checked).2 values
  simpa [Satisfied,AllHold,Holds] using relation.1.mp actual

structure RangeRef where
  kind : Nat
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  deriving Inhabited

def checkRange (matrix : Shape) (r : RangeRef) (value : Linear) (width : Nat) : Bool :=
  decide (width ≤ 248 ∧ 0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
    r.firstGate ≤ r.lastGate ∧ r.lastGate ≤ matrix.gates.size) &&
  if r.kind = 8 then
    decide (r.lastWire = r.firstWire+width) &&
      checkSpan matrix r.firstGate r.lastGate (rangeGates value r.firstWire width)
  else if r.kind = 10 then
    decide (r.firstWire = r.lastWire ∧ r.firstGate = r.lastGate) &&
      match GadgetAudit.constantValue value with
      | some n => decide (n < 2^width)
      | none => false
  else false

theorem range_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : RangeRef) (value : Linear) (width : Nat)
    (checked : checkRange matrix r value width = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) := by
  have body := (Bool.and_eq_true_iff.mp checked).2
  by_cases fresh : r.kind = 8
  · have span : checkSpan matrix r.firstGate r.lastGate (rangeGates value r.firstWire width) = true := by
      have branch : (decide (r.lastWire = r.firstWire+width) &&
          checkSpan matrix r.firstGate r.lastGate (rangeGates value r.firstWire width)) = true := by
        simpa only [ite_eq_left fresh] using body
      exact (Bool.and_eq_true_iff.mp branch).2
    exact GadgetShape.range_sound values one value r.firstWire width (span_sound matrix _ _ _ span values satisfied)
  · by_cases literal : r.kind = 10
    · cases constant : GadgetAudit.constantValue value with
      | none => simp [literal,constant] at body
      | some n =>
        have bound : n < 2^width := by
          have parts : decide (r.firstWire = r.lastWire ∧ r.firstGate = r.lastGate) && decide (n < 2^width) = true := by
            simpa [fresh,literal,constant] using body
          exact of_decide_eq_true (Bool.and_eq_true_iff.mp parts).2
        exact ⟨n,bound,GadgetAudit.constant_value_sound values one value n constant⟩
    · simp [fresh,literal] at body

structure AccessRef where
  firstGate : Nat
  lastGate : Nat
  fields : MemoryPacking.Access
  address : RangeRef
  value : RangeRef
  deriving Inhabited

def bools (access : MemoryPacking.Access) : List Gate := [boolGate access.active,boolGate access.write]
def zeros (access : MemoryPacking.Access) : List Gate :=
  [mulGate (sub (constant 1) access.active) access.write (constant 0),
   mulGate (sub (constant 1) access.active) access.address (constant 0),
   mulGate (sub (constant 1) access.active) access.value (constant 0)]

def checkAccess (matrix : Shape) (r : AccessRef) (addressBits valueBits : Nat) : Bool :=
  decide (r.firstGate+5 ≤ r.lastGate ∧ r.address.lastGate ≤ r.lastGate-3 ∧ r.value.lastGate ≤ r.lastGate-3) &&
    checkSpan matrix r.firstGate (r.firstGate+2) (bools r.fields) &&
    checkSpan matrix (r.lastGate-3) r.lastGate (zeros r.fields) &&
    checkRange matrix r.address r.fields.address addressBits && checkRange matrix r.value r.fields.value valueBits

-- Time is supplied separately, since input timestamps are constants and
-- sorted timestamps have their own range constraints.
theorem access_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : AccessRef) (addressBits valueBits time : Nat)
    (checked : checkAccess matrix r addressBits valueBits = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (clock : E values r.fields.clock = (time : F)) :
    ∃ row : MemoryTrace.Entry, MemoryPacking.Represents values r.fields row ∧
      row.address < 2^addressBits ∧ row.value < 2^valueBits ∧ row.time = time ∧
      (row.active = false → row.write = false ∧ row.address = 0 ∧ row.value = 0) := by
  have parts : decide (r.firstGate+5 ≤ r.lastGate ∧ r.address.lastGate ≤ r.lastGate-3 ∧ r.value.lastGate ≤ r.lastGate-3) = true ∧
      checkSpan matrix r.firstGate (r.firstGate+2) (bools r.fields) = true ∧
      checkSpan matrix (r.lastGate-3) r.lastGate (zeros r.fields) = true ∧
      checkRange matrix r.address r.fields.address addressBits = true ∧
      checkRange matrix r.value r.fields.value valueBits = true := by
    simpa only [checkAccess,Bool.and_eq_true_iff,and_assoc] using checked
  have boolean := span_sound matrix _ _ _ parts.2.1 values satisfied
  have inactive := span_sound matrix _ _ _ parts.2.2.1 values satisfied
  have boolRep (field : Linear) (gate : Holds values (boolGate field)) : ∃ b : Bool, E values field = (b.toNat : F) := by
    rcases boolean_sound values one field gate with off | on
    · exact ⟨false,by simpa using off⟩
    · exact ⟨true,by simpa using on⟩
  obtain ⟨active,activeImage⟩ := boolRep r.fields.active (boolean _ (by simp [bools]))
  obtain ⟨write,writeImage⟩ := boolRep r.fields.write (boolean _ (by simp [bools]))
  obtain ⟨address,addressBound,addressImage⟩ := range_sound matrix r.address r.fields.address addressBits parts.2.2.2.1 values one satisfied
  obtain ⟨value,valueBound,valueImage⟩ := range_sound matrix r.value r.fields.value valueBits parts.2.2.2.2 values one satisfied
  refine ⟨⟨active,write,address,value,time⟩,⟨activeImage,writeImage,addressImage,valueImage,clock⟩,
    addressBound,valueBound,rfl,?_⟩
  intro off
  change active = false at off
  have zeroField (field : Linear) (gate : Holds values (mulGate (sub (constant 1) r.fields.active) field (constant 0))) :
      E values field = 0 := by
    change E values (sub (constant 1) r.fields.active)*E values field = E values (constant 0) at gate
    rw [eval_sub,eval_constant values one,eval_constant values one,activeImage,off] at gate
    simp only [Bool.toNat_false,Semiring.natCast_zero,Ring.intCast_one,Ring.intCast_zero] at gate
    grind
  have writeZero := zeroField r.fields.write (inactive _ (by simp [zeros]))
  have addressZero := zeroField r.fields.address (inactive _ (by simp [zeros]))
  have valueZero := zeroField r.fields.value (inactive _ (by simp [zeros]))
  have bounds : addressBits ≤ 248 ∧ valueBits ≤ 248 := by
    have a := (Bool.and_eq_true_iff.mp parts.2.2.2.1).1
    have v := (Bool.and_eq_true_iff.mp parts.2.2.2.2).1
    simp only [decide_eq_true_eq] at a v
    exact ⟨a.1,v.1⟩
  have toZero (n width : Nat) (bound : n < 2^width) (widthBound : width ≤ 248) (image : (n : F) = 0) : n = 0 := by
    apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans bound (RangeConstraints.power_below_modulus width widthBound)) (by decide : 0 < scalarModulus)).mp
    simpa only [Semiring.natCast_zero] using image
  have writeFalse : write = false := by
    cases h : write with
    | false => rfl
    | true =>
      have bad : (1 : F) = 0 := by simpa [h] using writeImage.symm.trans writeZero
      exact False.elim (Field.zero_ne_one bad.symm)
  exact ⟨writeFalse,toZero address addressBits addressBound bounds.1 (addressImage.symm.trans addressZero),
    toZero value valueBits valueBound bounds.2 (valueImage.symm.trans valueZero)⟩

#print axioms range_sound
#print axioms access_sound

end ZkBuild.MemoryEvidence
