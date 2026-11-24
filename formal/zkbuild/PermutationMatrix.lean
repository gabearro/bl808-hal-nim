import ShaScalar
import PermutationNetwork

namespace ZkBuild.PermutationMatrix

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def bitM : Build Linear := fun start => ⟨wire start,start+1,[boolGate (wire start)]⟩

theorem bit_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1) :
    Ensures values bitM (fun out => E values out*(E values out-1) = 0) := by
  constructor
  intro start holds
  have h := holds (boolGate (wire start)) (by simp [bitM])
  change E values (wire start)*E values (sub (wire start) (constant 1)) = E values (constant 0) at h
  simpa [bitM,eval_sub,eval_constant values one,Ring.intCast_one,Ring.intCast_zero] using h

def switchM (input : Array Linear) (pair : Nat × Nat) : Build (Array Linear) :=
  if left : pair.1 < input.size then
    if right : pair.2 < input.size then do
      let selector ← bitM
      let delta ← ShaScalar.multiply selector (sub input[pair.2] input[pair.1])
      return (input.set pair.1 (input[pair.1]++delta)).set pair.2 (sub input[pair.2] delta) (by simpa using right)
    else pure input
  else pure input

theorem switch_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (input : Array Linear) (pair : Nat × Nat) :
    Ensures values (switchM input pair) (fun out => Array.Perm (out.map (E values)) (input.map (E values))) := by
  unfold switchM
  split
  next left =>
    split
    next right =>
      apply bind_sound values _ _ _ _ (bit_sound values one)
      intro selector boolean
      apply bind_sound values _ _ _ _ (ShaScalar.multiply_sound values selector (sub input[pair.2] input[pair.1]))
      intro delta multiplied
      apply pure_sound
      let gate : PermutationNetwork.Gate F := ⟨pair.1,pair.2,E values selector,E values delta⟩
      have valid : PermutationNetwork.ValidGate (input.map (E values)) gate := by
        refine ⟨boolean,?_⟩
        intro l r
        simpa [gate,eval_sub] using multiplied
      have perm := PermutationNetwork.step_perm (input.map (E values)) gate valid
      simpa [PermutationNetwork.step,gate,left,right,E,FullMatrix.eval_append,eval_sub] using perm
    next => exact pure_sound values input _ (.refl _)
  next => exact pure_sound values input _ (.refl _)

def runM : Array Linear → List (Nat × Nat) → Build (Array Linear)
  | input,[] => pure input
  | input,pair::rest => do
    let next ← switchM input pair
    runM next rest

theorem run_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (input : Array Linear) (pairs : List (Nat × Nat)) :
    Ensures values (runM input pairs) (fun out => Array.Perm (out.map (E values)) (input.map (E values))) := by
  induction pairs generalizing input with
  | nil => exact pure_sound values input _ (.refl _)
  | cons pair rest ih =>
    apply bind_sound values _ _ _ _ (switch_sound values one input pair)
    intro next previous
    constructor
    intro start holds
    exact ((ih next).run start holds).trans previous

def topology : Nat → Nat → Nat → List (Nat × Nat)
  | 0,_,_ => []
  | 1,offset,stride => [(offset,offset+stride)]
  | depth+2,offset,stride =>
    let ends := (List.range (2^(depth+1))).map (fun i => (offset+2*i*stride,offset+(2*i+1)*stride))
    ends ++ topology (depth+1) offset (2*stride) ++ topology (depth+1) (offset+stride) (2*stride) ++ ends

def validPairs (size : Nat) (pairs : List (Nat × Nat)) : Bool :=
  pairs.all (fun p => decide (p.1 < size ∧ p.2 < size ∧ p.1 ≠ p.2))

def input (depth : Nat) : Array Linear := ((List.range (2^depth)).map (fun i => wire (i+1))).toArray

def program (depth : Nat) : Step (Array Linear) := runM (input depth) (topology depth 0 1) (2^depth+1)

def artifact (depth : Nat) : Artifact :=
  ⟨{ wires := (program depth).next,publicCount := 2^depth,gates := (program depth).gates.toArray },
    (program depth).value.toList⟩

theorem checked_permutation {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (depth : Nat) (checked : conforms actual (artifact depth) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    (actual.outputs.map (E values)).Perm ((input depth).map (E values)).toList := by
  have relation := conformance_relation actual (artifact depth) checked values
  have holds : AllHold values (program depth).gates := by
    simpa [artifact,Satisfied,AllHold,Holds] using relation.1.mp satisfied
  have result := (run_sound values one (input depth) (topology depth 0 1)).run (2^depth+1) holds
  rw [relation.2]
  simpa only [artifact,program,Array.toList_map] using result.toList

#print axioms switch_sound
#print axioms run_sound
#print axioms checked_permutation

end ZkBuild.PermutationMatrix
