import StaticLookupMatrix
import LookupReferenceFast
set_option autoImplicit false
namespace ZkBuild.StaticLookupFast
open LookupReferenceFast (State view read initial add)

def step (columns : Nat) (bits : Nat → Bool) (node : StaticLookupMatrix.Node) (index : Nat) (state : State) : State :=
  let next := LookupReferenceFast.step columns bits (StaticLookupMatrix.erase node) index state
  if node.kind = 2 then add next node.zero (read state.flow index) else next

def walk (columns : Nat) (bits : Nat → Bool) (nodes : Array StaticLookupMatrix.Node) : List Nat → State → State
  | [],state => state
  | index::rest,state => walk columns bits nodes rest (step columns bits (nodes[index]?.getD default) index state)
def evaluate (columns root : Nat) (nodes : List StaticLookupMatrix.Node) (input : Nat) : State :=
  walk columns input.testBit nodes.toArray (List.range nodes.length).reverse (initial columns root nodes.length)

theorem erase_getD (nodes : List StaticLookupMatrix.Node) (index : Nat) :
    ((StaticLookupMatrix.basic nodes)[index]?.getD default) = StaticLookupMatrix.erase (nodes[index]?.getD default) := by
  cases h : nodes[index]? <;> simp [StaticLookupMatrix.basic,List.getElem?_map,h,StaticLookupMatrix.erase]
  rfl

theorem view_step (columns : Nat) (bits : Nat → Bool) (nodes : List StaticLookupMatrix.Node) (index : Nat) (state : State) :
    view (step columns bits (nodes.getD index default) index state) = StaticLookupMatrix.stepReference columns bits nodes index (view state) := by
  have base := LookupReferenceFast.view_step columns bits (StaticLookupMatrix.basic nodes) index state
  rw [erase_getD] at base
  unfold step StaticLookupMatrix.stepReference
  simp only [List.getD] at *
  by_cases emitter : (nodes[index]?.getD default).kind = 2
  · simp only [emitter,↓reduceIte]
    rw [LookupReferenceFast.view_add,base]
    rfl
  · simpa only [emitter,↓reduceIte] using base

theorem view_walk (columns : Nat) (bits : Nat → Bool) (nodes : Array StaticLookupMatrix.Node) (indices : List Nat) (state : State) :
    view (walk columns bits nodes indices state) = StaticLookupMatrix.walkReference columns bits nodes.toList indices (view state) := by
  induction indices generalizing state with
  | nil => rfl
  | cons index rest ih =>
    simp only [walk,StaticLookupMatrix.walkReference,ih]
    rw [← view_step]
    simp only [List.getD,Array.getElem?_toList]

theorem evaluate_eq (columns root : Nat) (nodes : List StaticLookupMatrix.Node) (input field : Nat) :
    read (evaluate columns root nodes input).sums field = StaticLookupMatrix.simulate columns root nodes input field := by
  have h := congrArg (fun s : LookupMatrix.State Int => s.sums field)
    (view_walk columns input.testBit nodes.toArray (List.range nodes.length).reverse (initial columns root nodes.length))
  rw [LookupReferenceFast.view_initial] at h
  simpa only [List.toList_toArray,view,evaluate,StaticLookupMatrix.simulate] using h
#print axioms evaluate_eq
end ZkBuild.StaticLookupFast
