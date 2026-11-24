import PermutationMatrix
import GadgetAudit

namespace ZkBuild.PermutationEmbedded

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram

structure Record where
  depth : Nat
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  inputs : List Linear
  outputs : List Linear
  deriving Inhabited

def program (r : Record) : Step (Array Linear) :=
  PermutationMatrix.runM r.inputs.toArray (PermutationMatrix.topology r.depth 0 1) r.firstWire

def span (r : Record) : GadgetAudit.Record :=
  { kind := 0,width := 0,firstWire := r.firstWire,lastWire := r.lastWire,
    firstGate := r.firstGate,lastGate := r.lastGate,reference := 0,inputs := [],outputs := r.outputs }

def expected (r : Record) : Artifact :=
  ⟨{ wires := (program r).next,gates := (program r).gates.toArray },(program r).value.toList⟩

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.inputs.length = 2^r.depth ∧ 0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧
    r.lastWire ≤ matrix.wires ∧ r.firstGate ≤ r.lastGate ∧ r.lastGate ≤ matrix.gates.size) &&
  r.inputs.all (fun row => row.all (fun term => decide (term.1 < r.firstWire))) &&
  r.outputs.all (fun row => row.all (fun term => decide (term.1 < r.lastWire))) &&
  PermutationMatrix.validPairs r.inputs.length (PermutationMatrix.topology r.depth 0 1) &&
  conforms (GadgetAudit.fragment matrix (span r)) (expected r)

theorem checked_permutation {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (r.outputs.map (E values)).Perm (r.inputs.map (E values)) := by
  have acceptedParts := Bool.and_eq_true_iff.mp accepted
  have relation := conformance_relation (GadgetAudit.fragment matrix (span r)) (expected r) acceptedParts.2 values
  have holds : AllHold values (program r).gates := by
    have model := relation.1.mp (GadgetAudit.fragment_satisfied matrix (span r) values satisfied)
    simpa [expected,Satisfied,AllHold,Holds] using model
  have result := (PermutationMatrix.run_sound values one r.inputs.toArray
    (PermutationMatrix.topology r.depth 0 1)).run r.firstWire holds
  have image := relation.2
  simp only [GadgetAudit.fragment,span] at image
  rw [image]
  simpa only [expected,program,Array.toList_map,List.toList_toArray] using result.toList

#print axioms checked_permutation

end ZkBuild.PermutationEmbedded
