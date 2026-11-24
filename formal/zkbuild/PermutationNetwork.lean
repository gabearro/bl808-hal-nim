import R1CS
import Init.Data.Array.Perm

/- Soundness of the exact switch network. Topology and routing affect
   completeness/cost only: every satisfying assignment preserves the multiset,
   for every schedule length and every input, including duplicate records. -/
namespace ZkBuild.PermutationNetwork

open Lean.Grind

theorem switch_sound {F : Type} [Field F] (left right selector delta : F)
    (bit : selector * (selector - 1) = 0)
    (product : delta = selector * (right - left)) :
    (left + delta = left ∧ right - delta = right) ∨
    (left + delta = right ∧ right - delta = left) := by
  rcases r1cs_boolean_sound selector bit with zero | one
  · left; constructor <;> grind
  · right; constructor <;> grind

structure Gate (F : Type) where
  left : Nat
  right : Nat
  selector : F
  delta : F

def step {F : Type} [Field F] (xs : Array F) (g : Gate F) : Array F :=
  if hi : g.left < xs.size then
    if hj : g.right < xs.size then
      (xs.set g.left (xs[g.left] + g.delta)).set g.right
        (xs[g.right] - g.delta) (by simpa using hj)
    else xs
  else xs

def ValidGate {F : Type} [Field F] (xs : Array F) (g : Gate F) : Prop :=
  g.selector * (g.selector - 1) = 0 ∧
    ∀ (hi : g.left < xs.size) (hj : g.right < xs.size),
      g.delta = g.selector * (xs[g.right] - xs[g.left])

theorem step_perm {F : Type} [Field F] (xs : Array F) (g : Gate F)
    (valid : ValidGate xs g) : Array.Perm (step xs g) xs := by
  unfold step
  split
  next hi =>
    split
    next hj =>
      rcases switch_sound xs[g.left] xs[g.right] g.selector g.delta
        valid.1 (valid.2 hi hj) with unchanged | exchanged
      · simp only [unchanged.1, unchanged.2, Array.set_getElem_self]
        exact .refl xs
      · simpa only [exchanged.1, exchanged.2, Array.swap] using
          (Array.swap_perm hi hj)
    next => exact .refl xs
  next => exact .refl xs

def execute {F : Type} [Field F] (xs : Array F) : List (Gate F) → Array F
  | [] => xs
  | g :: rest => execute (step xs g) rest

def Valid {F : Type} [Field F] (xs : Array F) : List (Gate F) → Prop
  | [] => True
  | g :: rest => ValidGate xs g ∧ Valid (step xs g) rest

theorem network_perm {F : Type} [Field F] (xs : Array F) (gates : List (Gate F))
    (valid : Valid xs gates) : Array.Perm (execute xs gates) xs := by
  induction gates generalizing xs with
  | nil => exact .refl xs
  | cons g rest ih =>
    exact (ih (step xs g) valid.2).trans (step_perm xs g valid.1)

theorem network_records {F : Type} [Field F] (xs : Array F) (gates : List (Gate F))
    (valid : Valid xs gates) : (execute xs gates).toList.Perm xs.toList :=
  (network_perm xs gates valid).toList

#print axioms switch_sound
#print axioms network_records

end ZkBuild.PermutationNetwork
