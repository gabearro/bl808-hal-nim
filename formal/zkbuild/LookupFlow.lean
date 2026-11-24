import R1CS

/- Soundness of pooling a decision DAG's incoming selector weights.
   Every payload coordinate is handled independently. The hypotheses are the
   node-score recurrence and the incoming-flow equations of the static DAG. -/
namespace ZkBuild.LookupFlow

open Lean.Grind

def total {F : Type} [CommRing F] (nodes : List Nat) (f : Nat → F) : F := match nodes with
  | [] => 0
  | node :: rest => f node+total rest f

theorem total_congr {F : Type} [CommRing F] (nodes : List Nat) (f g : Nat → F)
    (same : ∀ node ∈ nodes, f node = g node) : total nodes f = total nodes g := by
  induction nodes with
  | nil => rfl
  | cons node rest ih =>
    simp only [total, same node (by simp)]
    rw [ih (by intro n hn; exact same n (by simp [hn]))]

theorem total_add {F : Type} [CommRing F] (nodes : List Nat) (f g : Nat → F) :
    total nodes (fun n => f n+g n) = total nodes f+total nodes g := by
  induction nodes with
  | nil => simp only [total]; grind
  | cons node rest ih => simp only [total, ih]; grind

theorem total_left {F : Type} [CommRing F] (nodes : List Nat) (a : F) (f : Nat → F) :
    total nodes (fun n => a*f n) = a*total nodes f := by
  induction nodes with
  | nil => simp only [total]; grind
  | cons node rest ih => simp only [total, ih]; grind

theorem total_right {F : Type} [CommRing F] (nodes : List Nat) (f : Nat → F) (a : F) :
    total nodes (fun n => f n*a) = total nodes f*a := by
  induction nodes with
  | nil => simp only [total]; grind
  | cons node rest ih => simp only [total, ih]; grind

theorem total_zero {F : Type} [CommRing F] (nodes : List Nat) : total nodes (fun _ => (0 : F)) = 0 := by
  induction nodes with
  | nil => rfl
  | cons node rest ih => simp only [total, ih]; grind

theorem total_swap {F : Type} [CommRing F] (a b : List Nat) (f : Nat → Nat → F) :
    total a (fun i => total b (fun j => f i j)) = total b (fun j => total a (fun i => f i j)) := by
  induction a with
  | nil => simp only [total]; exact (total_zero b).symm
  | cons node rest ih => simp only [total, ih]; exact (total_add b _ _).symm

theorem total_root {F : Type} [CommRing F] (nodes : List Nat) (root : Nat) (score : Nat → F)
    (unique : nodes.Nodup) (present : root ∈ nodes) :
    total nodes (fun node => (if node = root then 1 else 0)*score node) = score root := by
  induction nodes with
  | nil => simp at present
  | cons node rest ih =>
    by_cases same : node = root
    · subst node
      have absent : root ∉ rest := (List.nodup_cons.mp unique).1
      have zero : total rest (fun node => (if node = root then (1 : F) else 0)*score node) = 0 := by
        calc
          total rest (fun node => (if node = root then (1 : F) else 0)*score node) = total rest (fun _ => 0) := by
            apply total_congr
            intro node hn
            have different : node ≠ root := by intro h; apply absent; simpa [h] using hn
            simp [different, Semiring.zero_mul]
          _ = 0 := total_zero rest
      simp only [total, ↓reduceIte, zero]
      grind
    · have member : root ∈ rest := by
        rcases List.mem_cons.mp present with equal | member
        · exact False.elim (same equal.symm)
        · exact member
      have tail := ih (List.nodup_cons.mp unique).2 member
      simp only [total, same, ↓reduceIte, tail]
      grind

theorem conservation {F : Type} [CommRing F] (nodes : List Nat) (root : Nat)
    (flow score payload : Nat → F) (weight : Nat → Nat → F)
    (unique : nodes.Nodup) (present : root ∈ nodes)
    (scores : ∀ i ∈ nodes, score i = payload i+total nodes (fun j => weight i j*score j))
    (flows : ∀ i ∈ nodes, flow i = (if i = root then 1 else 0)+total nodes (fun j => flow j*weight j i)) :
    score root = total nodes (fun i => flow i*payload i) := by
  have forward : total nodes (fun i => flow i*score i) =
      total nodes (fun i => flow i*payload i) +
      total nodes (fun i => total nodes (fun j => flow i*weight i j*score j)) := by
    rw [← total_add]
    apply total_congr
    intro i hi
    rw [scores i hi]
    have weighted := total_left nodes (flow i) (fun j => weight i j*score j)
    have associative : total nodes (fun j => flow i*(weight i j*score j)) =
        total nodes (fun j => flow i*weight i j*score j) := by
      apply total_congr
      intro j hj
      grind
    grind
  have backward : total nodes (fun i => flow i*score i) = score root+
      total nodes (fun i => total nodes (fun j => flow j*weight j i*score i)) := by
    rw [← total_root nodes root score unique present, ← total_add]
    apply total_congr
    intro i hi
    rw [flows i hi]
    have weighted := total_right nodes (fun j => flow j*weight j i) (score i)
    grind
  have swap := total_swap nodes nodes (fun i j => flow j*weight j i*score i)
  rw [swap] at backward
  grind

theorem branch_score {F : Type} [CommRing F] (bit : Bool) (zero one : F) :
    (if bit then one else zero) = (1-(if bit then 1 else 0))*zero+(if bit then 1 else 0)*one := by
  cases bit <;> simp <;> grind

#print axioms conservation
#print axioms branch_score

end ZkBuild.LookupFlow
