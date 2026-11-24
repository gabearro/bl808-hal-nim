import StaticLookupFast
import OpcodeCatalog
set_option autoImplicit false
namespace ZkBuild.StaticLookupEmbedded
open CircuitShape GadgetShape
structure Record where
  firstGate : Nat
  firstWire : Nat
  lastWire : Nat
  lastGate : Nat
  root : Nat
  opcodeRange : RangeUse.Record
  typeRange : RangeUse.Record
  inputs : List Linear
  lowBits : List Linear
  outputs : List Linear
  nodes : List StaticLookupMatrix.Node
  deriving Inhabited

def bits (r : Record) := RangeUse.bits r.typeRange ++ r.lowBits ++ RangeUse.bits r.opcodeRange
def program (r : Record) := StaticLookupMatrix.program 6 r.root (bits r) r.nodes r.firstWire

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.inputs.length = 3 ∧ r.lowBits.length = 2 ∧ r.outputs.length = 7 ∧
    r.firstWire ≥ 3 ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧ r.root < r.nodes.length ∧
    r.firstGate = r.opcodeRange.call.firstGate ∧ r.typeRange.call.firstGate = r.opcodeRange.call.lastGate ∧
    r.lowBits = [wire (r.firstWire-2),wire (r.firstWire-1)] ∧
    r.lastWire = (program r).next ∧ r.outputs.take 6 = (program r).value ∧
    r.outputs.getD 6 [] = r.lowBits.getD 0 [] ++ scale (r.lowBits.getD 1 []) 2 ∧
    (∀ node ∈ r.nodes, node.kind ≤ 2 ∧ node.payload.length = 6 ∧ (node.kind = 1 → node.bit < 21))) &&
  RangeUse.check matrix r.opcodeRange (r.inputs.getD 0 []) 16 &&
  RangeUse.check matrix r.typeRange (r.inputs.getD 2 []) 3 &&
  MemoryEvidence.checkSpan matrix r.typeRange.call.lastGate (r.typeRange.call.lastGate+2) (r.lowBits.map boolGate) &&
  MemoryEvidence.checkSpan matrix (r.typeRange.call.lastGate+2) r.lastGate (program r).gates

def expected (opcode index actual field : Nat) : Int :=
  match StaticTyping.signature opcode with
  | none => 0
  | some rule => Int.ofNat (([1,rule.inputs.length,if rule.output.isSome then 1 else 0,
      rule.output.getD 0,rule.clears.toNat,(StaticTyping.popAllowed rule index actual).toNat] : List Nat).getD field 0)

-- Admission is checked independently for every event. Only admitted opcodes
-- can therefore reach a static rule in a satisfying validation transcript.
def admittedCodes := (List.range 65536).filter OpcodeCatalog.admitted

def checkTable (r : Record) : Bool :=
  admittedCodes.all (fun opcode => (List.range 32).all (fun operand =>
    let value := StaticLookupFast.evaluate 6 r.root r.nodes (opcode*32+operand)
    (List.range 6).all (fun field =>
      decide (LookupReferenceFast.read value.sums field = expected opcode (operand/8) (operand%8) field))))

theorem table_value (r : Record) (checked : checkTable r = true)
    (opcode operand field : Nat) (codeBound : opcode < 65536) (admitted : OpcodeCatalog.admitted opcode = true)
    (operandBound : operand < 32) (fieldBound : field < 6) :
    StaticLookupMatrix.simulate 6 r.root r.nodes (opcode*32+operand) field = expected opcode (operand/8) (operand%8) field := by
  have codeMember : opcode ∈ admittedCodes := by simp [admittedCodes,List.mem_filter,codeBound,admitted]
  have a := List.all_eq_true.mp checked opcode codeMember
  have b := List.all_eq_true.mp a operand (List.mem_range.mpr operandBound)
  have c := _root_.of_decide_eq_true (List.all_eq_true.mp b field (List.mem_range.mpr fieldBound))
  simpa only [StaticLookupFast.evaluate_eq] using c
#print axioms table_value
end ZkBuild.StaticLookupEmbedded
