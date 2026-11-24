import LookupMatrix
set_option autoImplicit false
namespace ZkBuild.StaticLookupMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
open LookupMatrix (bitAt addFlow addReference Represents initial initialReference outputsM)
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one
structure Node where
  kind : Nat
  bit : Nat
  zero : Nat
  one : Nat
  payload : List Int
  deriving Inhabited, DecidableEq

def erase (node : Node) : LookupMatrix.Node :=
  ⟨if node.kind = 1 then some node.bit else none,node.zero,node.one,node.payload⟩
def basic (nodes : List Node) := nodes.map erase

def stepM (columns : Nat) (bits : List Linear) (nodes : List Node) (index : Nat) (state : LookupMatrix.State Linear) : Build (LookupMatrix.State Linear) := do
  let next ← LookupMatrix.stepM columns bits (basic nodes) index state
  if (nodes.getD index default).kind = 2 then
    pure (addFlow next (nodes.getD index default).zero (state.flow index))
  else pure next

def stepReference (columns : Nat) (bits : Nat → Bool) (nodes : List Node) (index : Nat) (state : LookupMatrix.State Int) : LookupMatrix.State Int :=
  let next := LookupMatrix.stepReference columns bits (basic nodes) index state
  if (nodes.getD index default).kind = 2 then
    addReference next (nodes.getD index default).zero (state.flow index)
  else next

def walkM (columns : Nat) (bits : List Linear) (nodes : List Node) : List Nat → LookupMatrix.State Linear → Build (LookupMatrix.State Linear)
  | [],state => pure state
  | index::rest,state => do
    let next ← stepM columns bits nodes index state
    walkM columns bits nodes rest next

def walkReference (columns : Nat) (bits : Nat → Bool) (nodes : List Node) : List Nat → LookupMatrix.State Int → LookupMatrix.State Int
  | [],state => state
  | index::rest,state => walkReference columns bits nodes rest (stepReference columns bits nodes index state)

def program (columns root : Nat) (bits : List Linear) (nodes : List Node) : Build (List Linear) := do
  let state ← walkM columns bits nodes (List.range nodes.length).reverse (initial root)
  outputsM state (List.range columns)
def simulate (columns root : Nat) (nodes : List Node) (input : Nat) : Nat → Int :=
  (walkReference columns input.testBit nodes (List.range nodes.length).reverse (initialReference root)).sums

private theorem propagate {F : Type} [CommRing F] (values : Nat → F)
    (state : LookupMatrix.State Linear) (reference : LookupMatrix.State Int)
    (represented : Represents values state reference) (index : Nat) (extra : Linear) (n : Int)
    (image : E values extra = (n : F)) : Represents values (addFlow state index extra) (addReference reference index n) := by
  constructor
  · intro i
    by_cases same : i = index
    · simp only [LookupMatrix.addFlow,LookupMatrix.addReference,same,↓reduceIte]
      have add : E values (state.flow index ++ extra) = E values (state.flow index)+E values extra := FullMatrix.eval_append ..
      rw [add,represented.1,image,Ring.intCast_add]
    · simp only [LookupMatrix.addFlow,LookupMatrix.addReference,same,↓reduceIte,represented.1]
  · exact represented.2

theorem step_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns : Nat) (bits : List Linear) (referenceBits : Nat → Bool) (nodes : List Node) (index : Nat)
    (state : LookupMatrix.State Linear) (reference : LookupMatrix.State Int) (represented : Represents values state reference)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if referenceBits bit then 1 else 0)) :
    Ensures values (stepM columns bits nodes index state)
      (fun out => Represents values out (stepReference columns referenceBits nodes index reference)) := by
  unfold stepM stepReference
  apply bind_sound values _ _ _ _ (LookupMatrix.step_sound values oneValue columns bits referenceBits (basic nodes) index state reference represented bitImages)
  intro next nextImage
  by_cases emitter : (nodes.getD index default).kind = 2
  · simp only [emitter,↓reduceIte]
    apply pure_sound
    exact propagate values next _ nextImage _ _ _ (represented.1 index)
  · simpa only [emitter,↓reduceIte] using pure_sound values next _ nextImage

theorem walk_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns : Nat) (bits : List Linear) (referenceBits : Nat → Bool) (nodes : List Node) (indices : List Nat)
    (state : LookupMatrix.State Linear) (reference : LookupMatrix.State Int) (represented : Represents values state reference)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if referenceBits bit then 1 else 0)) :
    Ensures values (walkM columns bits nodes indices state)
      (fun out => Represents values out (walkReference columns referenceBits nodes indices reference)) := by
  induction indices generalizing state reference with
  | nil => exact pure_sound values _ _ represented
  | cons index rest ih =>
    apply bind_sound values _ _ _ _ (step_sound values oneValue columns bits referenceBits nodes index state reference represented bitImages)
    intro next image
    exact ih next _ image

private theorem empty_eval {F : Type} [CommRing F] (values : Nat → F) : E values [] = 0 := by
  simp [E,FullMatrix.evalLinear,interpretLinear,R1CS.eval]

theorem program_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns root : Nat) (bits : List Linear) (nodes : List Node) (input : Nat)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if input.testBit bit then 1 else 0)) :
    Ensures values (program columns root bits nodes)
      (fun out => out.map (E values) = (List.range columns).map (fun i => (simulate columns root nodes input i : F))) := by
  have start : Represents values (initial root) (initialReference root) := by
    constructor
    · intro i
      by_cases isRoot : i = root <;> simp [LookupMatrix.initial,LookupMatrix.initialReference,isRoot,GadgetShape.eval_constant values oneValue,empty_eval]
    · intro i
      simp [LookupMatrix.initial,LookupMatrix.initialReference,empty_eval]
  apply bind_sound values _ _ _ _ (walk_sound values oneValue columns bits input.testBit nodes _ _ _ start bitImages)
  intro state represented
  exact LookupMatrix.outputs_sound values oneValue state _ represented _
#print axioms program_sound
end ZkBuild.StaticLookupMatrix
