import CiosSoundness

/- Cache concrete word arrays for execution of the oracle. The mathematical
   model uses functions; retaining recursive functions here causes repeated
   evaluation of an entire preceding outer pass on every word access. -/
namespace ZkBuild.CiosReference

open WordArithmetic FipsMontgomery CiosMontgomery

def freeze (words : Words) : Vector Word 8 := Vector.ofFn words
def view (words : Vector Word 8) : Words := words.get

theorem view_freeze (words : Words) : view (freeze words) = words := by
  funext i
  simp [view, freeze, Vector.get]
  congr 1

def cachedPrefix (input : Vector Word 8) : Nat → Vector Word 8
  | 0 => input
  | n+1 => freeze (CiosMontgomery.step (view (cachedPrefix input n)))

theorem prefix_correct (input : Words) (count : Nat) :
    view (cachedPrefix (freeze input) count) = outerPrefix input count := by
  induction count with
  | zero => exact view_freeze input
  | succ n ih => rw [cachedPrefix, view_freeze, outerPrefix, ih]

def cachedRows (input : Words) : List CiosMontgomery.Row :=
  (List.range 8).flatMap fun outer =>
    stepRows (view (cachedPrefix (freeze input) outer)) outer

theorem rows_correct (input : Words) : cachedRows input = CiosMontgomery.rows input := by
  simp only [cachedRows, CiosMontgomery.rows, prefix_correct]

def cachedResult (input : Words) : Vector Word 8 :=
  let last := cachedPrefix (freeze input) 8
  freeze (finish ⟨⟨0, 0, 0⟩, view last⟩)

theorem result_correct (input : Words) : view (cachedResult input) = CiosMontgomery.result input := by
  simp only [cachedResult, view_freeze, prefix_correct, CiosMontgomery.result]

#print axioms prefix_correct
#print axioms rows_correct
#print axioms result_correct

end ZkBuild.CiosReference
