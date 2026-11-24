import LookupMatrix
set_option autoImplicit false
namespace ZkBuild.LookupReferenceFast
structure Store where
  data : Array Int
  fallback : Nat → Int

def read (s : Store) (i : Nat) : Int := if h : i < s.data.size then s.data[i] else s.fallback i

def write (s : Store) (i : Nat) (v : Int) : Store :=
  if h : i < s.data.size then {s with data := s.data.set i v} else
    {s with fallback := fun j => if j = i then v else s.fallback j}

def ofFunction (size : Nat) (f : Nat → Int) : Store :=
  ⟨Array.ofFn (fun i : Fin size => f i),f⟩

@[simp] theorem read_ofFunction (size : Nat) (f : Nat → Int) (i : Nat) : read (ofFunction size f) i = f i := by
  by_cases h : i < size <;> simp [read,ofFunction,h]

@[simp] theorem read_write (s : Store) (i j : Nat) (v : Int) : read (write s i v) j = if j = i then v else read s j := by
  unfold write
  split
  · rename_i inside
    unfold read
    simp only [Array.size_set]
    by_cases hj : j < s.data.size
    · simp only [hj,↓reduceDIte,Array.getElem_set]
      by_cases eq : j = i <;> simp_all [Ne.symm]
    · have different : j ≠ i := by omega
      simp [hj,different]
  · rename_i outside
    unfold read
    by_cases hj : j < s.data.size
    · have different : j ≠ i := by omega
      simp [hj,different]
    · simp [hj]

structure State where
  flow : Store
  sums : Store

def view (s : State) : LookupMatrix.State Int := ⟨read s.flow,read s.sums⟩
def initial (columns root size : Nat) : State :=
  ⟨ofFunction size (fun i => if i = root then 1 else 0),ofFunction columns (fun _ => 0)⟩
def add (s : State) (index : Nat) (extra : Int) : State :=
  {s with flow := write s.flow index (read s.flow index+extra)}

def step (columns : Nat) (bits : Nat → Bool) (node : LookupMatrix.Node) (index : Nat) (s : State) : State :=
  let active := read s.flow index
  match node.bit with
  | some bit =>
    let selected := active*(if bits bit then 1 else 0)
    add (add s node.zero (active-selected)) node.one selected
  | none => {s with sums := ofFunction columns (fun field =>
      let value := node.payload.getD field 0
      if field < columns ∧ value ≠ 0 then read s.sums field+active*value else read s.sums field)}

def walk (columns : Nat) (bits : Nat → Bool) (nodes : Array LookupMatrix.Node) : List Nat → State → State
  | [],s => s
  | index::rest,s => walk columns bits nodes rest (step columns bits (nodes[index]?.getD default) index s)

def evaluate (columns root : Nat) (nodes : List LookupMatrix.Node) (input : Nat) : State :=
  walk columns input.testBit nodes.toArray (List.range nodes.length).reverse (initial columns root nodes.length)
def simulate (columns root : Nat) (nodes : List LookupMatrix.Node) (input : Nat) : Nat → Int :=
  read (evaluate columns root nodes input).sums

private theorem state_ext {a b : LookupMatrix.State Int} (flow : a.flow = b.flow) (sums : a.sums = b.sums) : a = b := by
  cases a
  cases b
  cases flow
  cases sums
  rfl

theorem view_initial (columns root size : Nat) : view (initial columns root size) = LookupMatrix.initialReference root := by
  apply state_ext <;> funext i <;> simp [view,initial,LookupMatrix.initialReference]

theorem view_add (s : State) (index : Nat) (extra : Int) :
    view (add s index extra) = LookupMatrix.addReference (view s) index extra := by
  apply state_ext
  · funext i
    by_cases h : i = index <;> simp [view,add,LookupMatrix.addReference,h]
  · rfl

theorem view_step (columns : Nat) (bits : Nat → Bool) (nodes : List LookupMatrix.Node) (index : Nat) (s : State) :
    view (step columns bits (nodes[index]?.getD default) index s) = LookupMatrix.stepReference columns bits nodes index (view s) := by
  cases kind : (nodes.getD index default).bit with
  | none =>
    simp only [List.getD] at kind
    simp only [step,LookupMatrix.stepReference,List.getD,kind]
    apply state_ext
    · rfl
    · funext i
      exact read_ofFunction _ _ _
  | some bit =>
    simp only [List.getD] at kind
    simp only [step,LookupMatrix.stepReference,List.getD,kind]
    rw [view_add,view_add]
    rfl

theorem view_walk (columns : Nat) (bits : Nat → Bool) (nodes : Array LookupMatrix.Node) (indices : List Nat) (s : State) :
    view (walk columns bits nodes indices s) = LookupMatrix.walkReference columns bits nodes.toList indices (view s) := by
  induction indices generalizing s with
  | nil => rfl
  | cons i rest ih =>
    simp only [walk,LookupMatrix.walkReference,ih]
    rw [← view_step]
    simp only [Array.getElem?_toList]

theorem simulate_eq (columns root : Nat) (nodes : List LookupMatrix.Node) (input field : Nat) :
    simulate columns root nodes input field = LookupMatrix.simulate columns root nodes input field := by
  have h := congrArg (fun s : LookupMatrix.State Int => s.sums field) (view_walk columns input.testBit nodes.toArray (List.range nodes.length).reverse (initial columns root nodes.length))
  rw [view_initial] at h
  simpa only [List.toList_toArray,view,simulate,evaluate,LookupMatrix.simulate] using h

theorem evaluate_eq (columns root : Nat) (nodes : List LookupMatrix.Node) (input field : Nat) :
    read (evaluate columns root nodes input).sums field = LookupMatrix.simulate columns root nodes input field :=
  simulate_eq columns root nodes input field

#print axioms read_ofFunction
#print axioms read_write
#print axioms simulate_eq
end ZkBuild.LookupReferenceFast
