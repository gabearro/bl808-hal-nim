import RangeUse
import TokenInteger

namespace ZkBuild.LookupMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one

@[simp] theorem pure_run (value : α) (start : Nat) :
    (pure value : Build α) start = ⟨value,start,[]⟩ := rfl

@[simp] theorem bind_run (first : Build α) (next : α → Build β) (start : Nat) :
    (first >>= next) start =
      let a := first start
      let b := next a.value a.next
      ⟨b.value,b.next,a.gates++b.gates⟩ := rfl

structure Node where
  bit : Option Nat
  zero : Nat
  one : Nat
  payload : List Int
  deriving Inhabited, DecidableEq

structure State (α : Type) where
  flow : Nat → α
  sums : Nat → α

def bitAt (bits : List Linear) (i : Nat) : Linear := bits.getD i (constant 0)

def addFlow (state : State Linear) (atIndex : Nat) (extra : Linear) : State Linear :=
  { state with flow := fun i => if i = atIndex then state.flow i ++ extra else state.flow i }

def addReference (state : State Int) (atIndex : Nat) (extra : Int) : State Int :=
  { state with flow := fun i => if i = atIndex then state.flow i + extra else state.flow i }

def multiplyM (a b : Linear) : Build Linear := fun start =>
  ⟨wire start,start+1,[mulGate a b (wire start)]⟩

def materializeM (a : Linear) : Build Linear := fun start =>
  ⟨wire start,start+1,[eqGate (wire start) a]⟩

def stepM (columns : Nat) (bits : List Linear) (nodes : List Node) (index : Nat) (state : State Linear) : Build (State Linear) := do
  let node := nodes.getD index default
  let active := state.flow index
  match node.bit with
  | some bit =>
    let selected ← multiplyM active (bitAt bits bit)
    return addFlow (addFlow state node.zero (sub active selected)) node.one selected
  | none => return { state with sums := fun field =>
      let value := node.payload.getD field 0
      if field < columns ∧ value ≠ 0 then state.sums field ++ scale active value else state.sums field }

def stepReference (columns : Nat) (bits : Nat → Bool) (nodes : List Node) (index : Nat) (state : State Int) : State Int :=
  let node := nodes.getD index default
  let active := state.flow index
  match node.bit with
  | some bit =>
    let selected := active*(if bits bit then 1 else 0)
    addReference (addReference state node.zero (active-selected)) node.one selected
  | none => { state with sums := fun field =>
      let value := node.payload.getD field 0
      if field < columns ∧ value ≠ 0 then state.sums field+active*value else state.sums field }

def walkM (columns : Nat) (bits : List Linear) (nodes : List Node) : List Nat → State Linear → Build (State Linear)
  | [],state => pure state
  | index::rest,state => do
    let next ← stepM columns bits nodes index state
    walkM columns bits nodes rest next

def walkReference (columns : Nat) (bits : Nat → Bool) (nodes : List Node) : List Nat → State Int → State Int
  | [],state => state
  | index::rest,state => walkReference columns bits nodes rest (stepReference columns bits nodes index state)

def outputsM (state : State Linear) : List Nat → Build (List Linear)
  | [] => pure []
  | field::rest => do
    let out ← materializeM (state.sums field)
    let more ← outputsM state rest
    return out::more

def initial (root : Nat) : State Linear := ⟨fun i => if i = root then constant 1 else [], fun _ => []⟩
def initialReference (root : Nat) : State Int := ⟨fun i => if i = root then 1 else 0, fun _ => 0⟩

def program (columns root : Nat) (bits : List Linear) (nodes : List Node) : Build (List Linear) := do
  let state ← walkM columns bits nodes (List.range nodes.length).reverse (initial root)
  outputsM state (List.range columns)

def simulate (columns root : Nat) (nodes : List Node) (input : Nat) : Nat → Int :=
  (walkReference columns input.testBit nodes (List.range nodes.length).reverse (initialReference root)).sums

def Represents {F : Type} [CommRing F] (values : Nat → F) (state : State Linear) (reference : State Int) : Prop :=
  (∀ i, E values (state.flow i) = (reference.flow i : F)) ∧
  (∀ i, E values (state.sums i) = (reference.sums i : F))

private theorem eval_empty {F : Type} [CommRing F] (values : Nat → F) : E values [] = 0 := by
  simp [E,FullMatrix.evalLinear,interpretLinear,R1CS.eval]

private theorem eval_cat {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    E values (a++b) = E values a+E values b := FullMatrix.eval_append ..

private theorem addFlow_sound {F : Type} [CommRing F] (values : Nat → F) (state : State Linear) (reference : State Int)
    (represented : Represents values state reference) (index : Nat) (extra : Linear) (n : Int)
    (image : E values extra = (n : F)) : Represents values (addFlow state index extra) (addReference reference index n) := by
  constructor
  · intro i
    by_cases same : i = index
    · simp only [addFlow,addReference,same,↓reduceIte,eval_cat,represented.1,image,Ring.intCast_add]
    · simp only [addFlow,addReference,same,↓reduceIte,represented.1]
  · exact represented.2

theorem step_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns : Nat) (bits : List Linear) (referenceBits : Nat → Bool) (nodes : List Node) (index : Nat)
    (state : State Linear) (reference : State Int) (represented : Represents values state reference)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if referenceBits bit then 1 else 0)) :
    Ensures values (stepM columns bits nodes index state)
      (fun out => Represents values out (stepReference columns referenceBits nodes index reference)) := by
  let node := nodes.getD index default
  cases kind : node.bit with
  | none =>
    change (nodes.getD index default).bit = none at kind
    constructor
    intro start holds
    change Represents values _ _
    constructor
    · intro i; simpa only [stepM,stepReference,kind,pure_run] using represented.1 i
    · intro field
      by_cases used : field < columns ∧ (nodes.getD index default).payload.getD field 0 ≠ 0
      · simp only [stepM,stepReference,kind,pure_run]
        rw [ite_eq_left used,ite_eq_left used,eval_cat]
        have scaled : E values (scale (state.flow index) (node.payload.getD field 0)) =
            (reference.flow index : F)*(node.payload.getD field 0 : F) := by
          change evalLinear values (scale (state.flow index) (node.payload.getD field 0)) = _
          rw [FullMatrix.eval_scale]
          change (node.payload.getD field 0 : F)*E values (state.flow index) = _
          rw [represented.1]
          grind
        dsimp only [node] at scaled
        simp only [represented.2,scaled,Ring.intCast_add,Ring.intCast_mul]
      · simpa only [stepM,stepReference,kind,pure_run,used,↓reduceIte] using represented.2 field
  | some bit =>
    change (nodes.getD index default).bit = some bit at kind
    constructor
    intro start holds
    have product : E values (wire start) = E values (state.flow index)*E values (bitAt bits bit) := by
      apply multiply_sound
      exact holds _ (by simp only [stepM,kind,bind_run,multiplyM,pure_run,List.mem_append,List.mem_singleton,List.not_mem_nil,or_false])
    have selected : E values (wire start) = ((reference.flow index*(if referenceBits bit then 1 else 0) : Int) : F) := by
      rw [product,represented.1,bitImages]
      cases referenceBits bit <;> simp <;> grind
    have remaining : E values (sub (state.flow index) (wire start)) =
        ((reference.flow index-reference.flow index*(if referenceBits bit then 1 else 0) : Int) : F) := by
      rw [eval_sub,represented.1,selected,Ring.intCast_sub]
    have first := addFlow_sound values state reference represented node.zero _ _ remaining
    have second := addFlow_sound values _ _ first node.one _ _ selected
    simpa only [stepM,stepReference,kind,multiplyM,bind_run,pure_run] using second

theorem walk_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns : Nat) (bits : List Linear) (referenceBits : Nat → Bool) (nodes : List Node) (indices : List Nat)
    (state : State Linear) (reference : State Int) (represented : Represents values state reference)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if referenceBits bit then 1 else 0)) :
    Ensures values (walkM columns bits nodes indices state)
      (fun out => Represents values out (walkReference columns referenceBits nodes indices reference)) := by
  induction indices generalizing state reference with
  | nil => exact pure_sound values _ _ represented
  | cons index rest ih =>
    apply bind_sound values _ _ _ _ (step_sound values oneValue columns bits referenceBits nodes index state reference represented bitImages)
    intro next image
    exact ih next _ image

theorem outputs_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (state : State Linear) (reference : State Int) (represented : Represents values state reference) (fields : List Nat) :
    Ensures values (outputsM state fields) (fun out => out.map (E values) = fields.map (fun i => (reference.sums i : F))) := by
  induction fields with
  | nil => exact pure_sound values _ _ rfl
  | cons field rest ih =>
    constructor
    intro start holds
    have image : E values (wire start) = (reference.sums field : F) := by
      have gate := holds (eqGate (wire start) (state.sums field)) (by simp [outputsM,materializeM,bind_run,pure_run])
      exact (equality_sound values oneValue _ _ gate).trans (represented.2 field)
    have tail : AllHold values (outputsM state rest (start+1)).gates := by
      intro g gm; exact holds g (by simp only [outputsM,materializeM,bind_run,pure_run,List.append_nil,List.mem_append,List.mem_singleton]; exact Or.inr gm)
    have restImage := ih.run (start+1) tail
    simpa [outputsM,materializeM,bind_run,pure_run,image] using congrArg (List.cons (E values (wire start))) restImage

theorem program_sound {F : Type} [CommRing F] (values : Nat → F) (oneValue : values 0 = 1)
    (columns root : Nat) (bits : List Linear) (nodes : List Node) (input : Nat)
    (bitImages : ∀ bit, E values (bitAt bits bit) = (if input.testBit bit then 1 else 0)) :
    Ensures values (program columns root bits nodes)
      (fun out => out.map (E values) = (List.range columns).map (fun i => (simulate columns root nodes input i : F))) := by
  have start : Represents values (initial root) (initialReference root) := by
    constructor
    · intro i
      by_cases isRoot : i = root <;> simp [initial,initialReference,isRoot,eval_empty,eval_constant values oneValue]
    · intro i; simp [initial,initialReference,eval_empty]
  apply bind_sound values _ _ _ _ (walk_sound values oneValue columns bits input.testBit nodes _ _ _ start bitImages)
  intro state represented
  exact outputs_sound values oneValue state _ represented _

#print axioms program_sound
end ZkBuild.LookupMatrix
