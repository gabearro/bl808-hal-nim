import LookupMatrix

namespace ZkBuild.LookupEmbedded
open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

structure Record where
  range : RangeUse.Record
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  root : Nat
  columns : Nat
  input : Linear
  outputs : List Linear
  nodes : List LookupMatrix.Node
  deriving Inhabited

def program (r : Record) := LookupMatrix.program r.columns r.root (RangeUse.bits r.range) r.nodes r.firstWire

def check (matrix : Shape) (r : Record) : Bool :=
  decide (0 < r.columns ∧ r.columns ≤ 64 ∧ 0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
    r.root < r.nodes.length ∧ r.lastWire = (program r).next ∧ r.outputs = (program r).value ∧
    ∀ node ∈ r.nodes, node.payload.length = r.columns ∧ (∀ bit, node.bit = some bit → bit < 16)) &&
  RangeUse.check matrix r.range r.input 16 && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (program r).gates

-- A table is checked for every input in the indicated finite domain. The
-- expected mapping is part of the verifier, not supplied by the audit file.
def checkTable (r : Record) (domainBits : Nat) (expected : Nat → Nat → Int) : Bool :=
  decide (domainBits ≤ 16) && (List.range (2^domainBits)).all (fun input =>
    (List.range r.columns).all (fun field => decide (LookupMatrix.simulate r.columns r.root r.nodes input field = expected input field)))

theorem checked_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true) (domainBits : Nat)
    (expected : Nat → Nat → Int) (table : checkTable r domainBits expected = true)
    (input : Nat) (inputBound : input < 2^domainBits)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (image : E values r.input = (input : F)) :
    r.outputs.map (E values) = (List.range r.columns).map (fun field => (expected input field : F)) := by
  have parts :
      (0 < r.columns ∧ r.columns ≤ 64 ∧ 0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
        r.root < r.nodes.length ∧ r.lastWire = (program r).next ∧ r.outputs = (program r).value ∧
        ∀ node ∈ r.nodes, node.payload.length = r.columns ∧ (∀ bit, node.bit = some bit → bit < 16)) ∧
      RangeUse.check matrix r.range r.input 16 = true ∧
      MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (program r).gates = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  have ranges := RangeUse.checked_certificate matrix r.range r.input 16 parts.2.1 values oneValue satisfied
  obtain ⟨n,nBound,nImage,bits⟩ := TokenInteger.certificate_nat values oneValue r.input (RangeUse.bits r.range) 16 ranges
  have db : domainBits ≤ 16 := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp table).1
  have inputSmall : input < scalarModulus := by
    have power := Nat.pow_le_pow_right (n := 2) (by decide) db
    have big : 2^16 < scalarModulus := by decide
    omega
  have nSmall : n < scalarModulus := Nat.lt_trans nBound (by decide)
  have same : n = input := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus nSmall inputSmall).mp (nImage.symm.trans image)
  have bitImages : ∀ bit, E values (LookupMatrix.bitAt (RangeUse.bits r.range) bit) = (if input.testBit bit then 1 else 0) := by
    simpa only [LookupMatrix.bitAt,BinaryTokenMatrix.atBit,BinaryTokenMatrix.zero,same] using bits
  have model := (LookupMatrix.program_sound values oneValue r.columns r.root (RangeUse.bits r.range) r.nodes input bitImages).run r.firstWire
    (MemoryEvidence.span_sound matrix r.firstGate r.lastGate (program r).gates parts.2.2 values satisfied)
  have out : r.outputs = (program r).value := parts.1.2.2.2.2.2.2.2.1
  rw [out]
  change ((LookupMatrix.program r.columns r.root (RangeUse.bits r.range) r.nodes) r.firstWire).value.map (E values) = _
  rw [model]
  apply List.map_congr_left
  intro field member
  have inputMember := List.all_eq_true.mp (Bool.and_eq_true_iff.mp table).2 input (List.mem_range.mpr inputBound)
  have same := _root_.of_decide_eq_true (List.all_eq_true.mp inputMember field member)
  rw [same]

#print axioms checked_values
end ZkBuild.LookupEmbedded
