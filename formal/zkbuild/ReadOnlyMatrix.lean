import BinaryReadMemory
import RangeUse

namespace ZkBuild.ReadOnlyMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryReadMemory
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Entry := BinarySourceMatrix.Entry

def initializer (e : Entry) : MemoryPacking.Access :=
  ⟨e.active,e.active,e.address,e.value,constant 0⟩

def expected (entries queries : List Entry) (capacity : Nat) : List MemoryPacking.Access :=
  entries.map initializer ++ queries.map readAccess ++ List.replicate (capacity-entries.length-queries.length) padding

structure Step where
  delta : Linear
  range : RangeUse.Record
  deriving Inhabited

def stepGates (prior current : Entry) (step : Step) : List Gate :=
  [⟨current.active,sub (constant 1) prior.active,constant 0⟩,
   selectGate current.active (sub (sub current.address prior.address) (constant 1)) (constant 0) step.delta] ++
  RangeUse.gates step.range

def orderGates : List Entry → List Step → List Gate
  | prior::current::rest, step::steps => stepGates prior current step ++ orderGates (current::rest) steps
  | _,_ => []

structure Record where
  firstGate : Nat
  preludeEnd : Nat
  entries : List Entry
  queries : List Entry
  steps : List Step
  memory : MemoryEmbedded.Record
  deriving Inhabited

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.steps.length = r.entries.length-1 ∧ r.entries.length+r.queries.length ≤ r.memory.inputs.length ∧
    (r.memory.inputs.map (fun x => normalizedPayload x.fields)) =
      (expected r.entries r.queries r.memory.inputs.length).map normalizedPayload) &&
  r.steps.all (fun step => RangeUse.check matrix step.range step.delta r.memory.addressBits) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.preludeEnd (orderGates r.entries r.steps) &&
  MemoryEmbedded.check matrix r.memory

theorem checked_holds {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (orderGates r.entries r.steps) := by
  exact MemoryEvidence.span_sound matrix r.firstGate r.preludeEnd (orderGates r.entries r.steps)
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2 values satisfied

#print axioms checked_holds
end ZkBuild.ReadOnlyMatrix
