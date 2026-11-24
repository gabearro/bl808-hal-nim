import ScalarRoots

/- Sequential heap updates for the Nim butterfly loops. Reads are saved before
   either write, and distinct butterfly pairs never share an array index. -/
namespace ZkBuild.FftInPlace

open Lean.Grind FftStages FftLayout FftRadix
attribute [local instance] Semiring.natCast

def write {I F : Type} [DecidableEq I] (a : I → F) (index : I) (value : F) : I → F :=
  fun j => if j = index then value else a j

def butterflyAt {I F : Type} [DecidableEq I] [Field F]
    (inverse : Bool) (weight : F) (left right : I) (a : I → F) : I → F :=
  let u := a left
  let v := a right
  if inverse then write (write a left (u+v)) right ((u-v)*weight)
  else
    let t := v*weight
    write (write a left (u+t)) right (u-t)

def pairResult {A F : Type} [Field F] (inverse : Bool) (weight : A → F)
    (a : A × Bool → F) (p : A) (side : Bool) : F :=
  let u := a (p, true)
  let v := a (p, false)
  if inverse then (if side then u+v else (u-v)*weight p)
  else (if side then u+v*weight p else u-v*weight p)

def pairStep {A F : Type} [DecidableEq A] [Field F] (inverse : Bool)
    (weight : A → F) (p : A) (a : A × Bool → F) : A × Bool → F :=
  butterflyAt inverse (weight p) (p, true) (p, false) a

theorem pair_step_at {A F : Type} [DecidableEq A] [Field F]
    (inverse : Bool) (weight : A → F) (p : A) (a : A × Bool → F) (q : A) (side : Bool) :
    pairStep inverse weight p a (q, side) =
      if q = p then pairResult inverse weight a q side else a (q, side) := by
  by_cases eq : q = p
  · subst q
    cases inverse <;> cases side <;> simp [pairStep, butterflyAt, write, pairResult]
  · cases inverse <;> cases side <;> simp [pairStep, butterflyAt, write, eq]

theorem pair_result_congr {A F : Type} [Field F]
    (inverse : Bool) (weight : A → F) (a b : A × Bool → F) (q : A) (side : Bool)
    (same : ∀ s, a (q, s) = b (q, s)) :
    pairResult inverse weight a q side = pairResult inverse weight b q side := by
  simp only [pairResult, same]

def runPairs {A F : Type} [DecidableEq A] [Field F] (inverse : Bool) (weight : A → F) :
    List A → (A × Bool → F) → (A × Bool → F)
  | [], a => a
  | p :: rest, a => runPairs inverse weight rest (pairStep inverse weight p a)

theorem run_pairs_at {A F : Type} [DecidableEq A] [Field F]
    (inverse : Bool) (weight : A → F) (pairs : List A) (distinct : pairs.Nodup)
    (a : A × Bool → F) (q : A) (side : Bool) :
    runPairs inverse weight pairs a (q, side) =
      if q ∈ pairs then pairResult inverse weight a q side else a (q, side) := by
  induction pairs generalizing a with
  | nil => simp [runPairs]
  | cons p rest ih =>
    obtain ⟨absent, distinctRest⟩ := List.nodup_cons.mp distinct
    rw [runPairs, ih distinctRest]
    by_cases eq : q = p
    · subst q
      simp only [absent, ite_false, List.mem_cons, true_or, ite_true, pair_step_at]
    · have same (s : Bool) : pairStep inverse weight p a (q, s) = a (q, s) := by
        simp only [pair_step_at, eq, ite_false]
      have resultSame := pair_result_congr inverse weight (pairStep inverse weight p a) a q side same
      simp only [List.mem_cons, eq, false_or, resultSame, same]

def pairs (blocks half : Nat) : List (Fin blocks × Fin half) :=
  (List.finRange blocks).flatMap fun block => (List.finRange half).map fun offset => (block, offset)

theorem pairs_complete (blocks half : Nat) (p : Fin blocks × Fin half) : p ∈ pairs blocks half := by
  simp [pairs, List.mem_flatMap, List.mem_map, List.mem_finRange]
  exact ⟨p.1, p.2, rfl⟩

theorem pairs_distinct (blocks half : Nat) : (pairs blocks half).Nodup := by
  apply List.pairwise_flatMap.mpr
  constructor
  · intro block _
    apply List.pairwise_map.mpr
    exact (List.nodup_finRange half).imp (by intro x y h eq; exact h (congrArg Prod.snd eq))
  · apply (List.nodup_finRange blocks).imp
    intro x y h p hp q hq eq
    obtain ⟨offset, _, rfl⟩ := List.mem_map.mp hp
    obtain ⟨other, _, rfl⟩ := List.mem_map.mp hq
    exact h (congrArg Prod.fst eq)

theorem pack_eq_iff {blocks half : Nat} (positive : 0 < half) (c d : Coordinates blocks half) :
    pack c = pack d ↔ c = d := by
  constructor
  · intro eq
    have decoded := congrArg (unpack positive) eq
    simpa only [unpack_pack] using decoded
  · exact congrArg pack

def arrayStep {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (weight : Fin blocks × Fin half → F) (p : Fin blocks × Fin half)
    (a : Fin (blocks*(2*half)) → F) : Fin (blocks*(2*half)) → F :=
  butterflyAt inverse (weight p) (pack (p, true)) (pack (p, false)) a

theorem array_step_transport {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (inverse : Bool) (weight : Fin blocks × Fin half → F) (p : Fin blocks × Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    (fun c => arrayStep inverse weight p a (pack c)) =
      pairStep inverse weight p (fun c => a (pack c)) := by
  funext c
  cases inverse <;> simp [arrayStep, pairStep, butterflyAt, write, pack_eq_iff positive]

def arrayLoop {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (weight : Fin blocks × Fin half → F) :
    List (Fin blocks × Fin half) → (Fin (blocks*(2*half)) → F) → (Fin (blocks*(2*half)) → F)
  | [], a => a
  | p :: rest, a => arrayLoop inverse weight rest (arrayStep inverse weight p a)

theorem array_loop_transport {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (inverse : Bool) (weight : Fin blocks × Fin half → F) (ps : List (Fin blocks × Fin half))
    (a : Fin (blocks*(2*half)) → F) :
    (fun c => arrayLoop inverse weight ps a (pack c)) =
      runPairs inverse weight ps (fun c => a (pack c)) := by
  induction ps generalizing a with
  | nil => rfl
  | cons p rest ih =>
    simp only [arrayLoop, runPairs, ih, array_step_transport positive]

theorem array_loop_at {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (inverse : Bool) (weight : Fin blocks × Fin half → F)
    (a : Fin (blocks*(2*half)) → F) (p : Fin blocks × Fin half) (side : Bool) :
    arrayLoop inverse weight (pairs blocks half) a (pack (p, side)) =
      pairResult inverse weight (fun c => a (pack c)) p side := by
  have transported := congrArg (fun f => f (p, side))
    (array_loop_transport positive inverse weight (pairs blocks half) a)
  rw [run_pairs_at inverse weight _ (pairs_distinct blocks half), ite_eq_left (pairs_complete blocks half p)]
    at transported
  exact transported

theorem forward_stage_correct {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (a : Fin (blocks*(2*half)) → F) :
    arrayLoop false (fun p => root^p.2.val) (pairs blocks half) a =
      forward (arrayStage blocks half positive root nonzero) a := by
  funext i
  rw [← pack_unpack positive i]
  generalize unpack positive i = c
  obtain ⟨⟨block, offset⟩, side⟩ := c
  rw [array_loop_at positive]
  cases side <;> simp only [pairResult, Bool.false_eq_true, ite_false, ite_true]
  · rw [right_forward positive]
    grind
  · rw [left_forward positive]
    grind

theorem backward_stage_correct {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (a : Fin (blocks*(2*half)) → F) :
    arrayLoop true (fun p => root⁻¹^p.2.val) (pairs blocks half) a =
      backward (arrayStage blocks half positive root nonzero) a := by
  funext i
  rw [← pack_unpack positive i]
  generalize unpack positive i = c
  obtain ⟨⟨block, offset⟩, side⟩ := c
  rw [array_loop_at positive]
  cases side <;> simp only [pairResult, ite_true, Bool.false_eq_true, ite_false]
  · rw [right_inverse_twiddle positive]
  · rw [left_backward positive]

def consecutive {n : Nat} : List (Fin n) → Nat → Prop
  | [], _ => True
  | i :: rest, start => i.val = start ∧ consecutive rest (start+1)

theorem consecutive_map {n m : Nat} (f : Fin n → Fin m) (delta : Nat)
    (index : ∀ i, (f i).val = i.val+delta) (xs : List (Fin n)) (start : Nat)
    (ordered : consecutive xs start) : consecutive (xs.map f) (start+delta) := by
  induction xs generalizing start with
  | nil => trivial
  | cons i rest ih =>
    obtain ⟨head, tail⟩ := ordered
    constructor
    · simp only [index, head]
    · have next := ih (start+1) tail
      simpa only [show start+1+delta = start+delta+1 by omega] using next

theorem fin_range_consecutive (n : Nat) : consecutive (List.finRange n) 0 := by
  induction n with
  | zero => trivial
  | succ n ih =>
    rw [List.finRange_succ]
    constructor
    · rfl
    · exact consecutive_map Fin.succ 1 (fun _ => rfl) (List.finRange n) 0 ih

def blockLoop {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (root : F) (block : Fin blocks) :
    List (Fin half) → F → (Fin (blocks*(2*half)) → F) → (Fin (blocks*(2*half)) → F)
  | [], _, a => a
  | offset :: rest, w, a =>
    blockLoop inverse root block rest (w*root)
      (arrayStep inverse (fun _ => w) (block, offset) a)

theorem block_loop_correct {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (root : F) (block : Fin blocks) (offsets : List (Fin half)) (start : Nat)
    (ordered : consecutive offsets start) (a : Fin (blocks*(2*half)) → F) :
    blockLoop inverse root block offsets (root^start) a =
      arrayLoop inverse (fun p => root^p.2.val) (offsets.map fun offset => (block, offset)) a := by
  induction offsets generalizing start a with
  | nil => rfl
  | cons offset rest ih =>
    obtain ⟨head, tail⟩ := ordered
    simp only [blockLoop, List.map_cons, arrayLoop]
    rw [← Semiring.pow_succ, ih (start+1) tail]
    congr 1
    simp only [arrayStep, head]

def nestedLoop {F : Type} [Field F] {blocks half : Nat} (inverse : Bool) (root : F) :
    List (Fin blocks) → (Fin (blocks*(2*half)) → F) → (Fin (blocks*(2*half)) → F)
  | [], a => a
  | block :: rest, a =>
    nestedLoop inverse root rest (blockLoop inverse root block (List.finRange half) 1 a)

theorem array_loop_append {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (weight : Fin blocks × Fin half → F) (xs ys : List (Fin blocks × Fin half))
    (a : Fin (blocks*(2*half)) → F) :
    arrayLoop inverse weight (xs ++ ys) a = arrayLoop inverse weight ys (arrayLoop inverse weight xs a) := by
  induction xs generalizing a with
  | nil => rfl
  | cons x rest ih => simp only [List.cons_append, arrayLoop, ih]

theorem nested_loop_correct {F : Type} [Field F] {blocks half : Nat} (inverse : Bool)
    (root : F) (bs : List (Fin blocks)) (a : Fin (blocks*(2*half)) → F) :
    nestedLoop inverse root bs a = arrayLoop inverse (fun p => root^p.2.val)
      (bs.flatMap fun block => (List.finRange half).map fun offset => (block, offset)) a := by
  induction bs generalizing a with
  | nil => rfl
  | cons block rest ih =>
    simp only [nestedLoop, List.flatMap_cons, array_loop_append, ih]
    congr 1
    have result := block_loop_correct inverse root block (List.finRange half) 0
      (fin_range_consecutive half) a
    simpa only [Semiring.pow_zero] using result

theorem nested_forward_correct {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (a : Fin (blocks*(2*half)) → F) :
    nestedLoop false root (List.finRange blocks) a =
      forward (arrayStage blocks half positive root nonzero) a := by
  rw [nested_loop_correct]
  exact forward_stage_correct positive root nonzero a

theorem nested_backward_correct {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (a : Fin (blocks*(2*half)) → F) :
    nestedLoop true root⁻¹ (List.finRange blocks) a =
      backward (arrayStage blocks half positive root nonzero) a := by
  rw [nested_loop_correct]
  exact backward_stage_correct positive root nonzero a

def transport {F : Type} {n m : Nat} (same : n = m)
    (op : (Fin n → F) → (Fin n → F)) (a : Fin m → F) : Fin m → F :=
  fun i => op (fun j => a (Fin.cast same j)) (Fin.cast same.symm i)

theorem transport_forward {F : Type} [Field F] {n m : Nat} (same : n = m)
    (stage : Stage (Fin n) F) (a : Fin m → F) :
    transport same (forward stage) a = forward (same ▸ stage) a := by
  cases same
  rfl

theorem transport_backward {F : Type} [Field F] {n m : Nat} (same : n = m)
    (stage : Stage (Fin n) F) (a : Fin m → F) :
    transport same (backward stage) a = backward (same ▸ stage) a := by
  cases same
  rfl

def radixLoop {F : Type} [Field F] (bits : Nat) (index : Fin bits) (inverse : Bool)
    (root : F) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  transport (stage_size bits index.val index.isLt)
    (nestedLoop inverse (if inverse then root⁻¹ else root) (List.finRange (2^(bits-index.val-1)))) a

theorem radix_forward_correct {F : Type} [Field F] (bits : Nat) (index : Fin bits)
    (root : F) (nonzero : root ≠ 0) (a : Fin (2^bits) → F) :
    radixLoop bits index false root a = forward (radixStage bits index root nonzero) a := by
  have stage : nestedLoop false root (List.finRange (2^(bits-index.val-1))) =
      forward (arrayStage (2^(bits-index.val-1)) (2^index.val) (Nat.two_pow_pos _) root nonzero) :=
    funext (nested_forward_correct (Nat.two_pow_pos _) root nonzero)
  unfold radixLoop
  rw [show (if false then root⁻¹ else root) = root from rfl, stage, transport_forward]
  rfl

theorem radix_backward_correct {F : Type} [Field F] (bits : Nat) (index : Fin bits)
    (root : F) (nonzero : root ≠ 0) (a : Fin (2^bits) → F) :
    radixLoop bits index true root a = backward (radixStage bits index root nonzero) a := by
  have stage : nestedLoop true root⁻¹ (List.finRange (2^(bits-index.val-1))) =
      backward (arrayStage (2^(bits-index.val-1)) (2^index.val) (Nat.two_pow_pos _) root nonzero) :=
    funext (nested_backward_correct (Nat.two_pow_pos _) root nonzero)
  unfold radixLoop
  rw [show (if true then root⁻¹ else root) = root⁻¹ from rfl, stage, transport_backward]
  rfl

def runIndices {F : Type} [Field F] {bits : Nat} (inverse : Bool) (roots : Fin bits → F) :
    List (Fin bits) → (Fin (2^bits) → F) → (Fin (2^bits) → F)
  | [], a => a
  | index :: rest, a => runIndices inverse roots rest (radixLoop bits index inverse (roots index) a)

theorem run_indices_append {F : Type} [Field F] {bits : Nat} (inverse : Bool)
    (roots : Fin bits → F) (xs ys : List (Fin bits)) (a : Fin (2^bits) → F) :
    runIndices inverse roots (xs ++ ys) a = runIndices inverse roots ys (runIndices inverse roots xs a) := by
  induction xs generalizing a with
  | nil => rfl
  | cons x rest ih => simp only [List.cons_append, runIndices, ih]

theorem run_forward_correct {F : Type} [Field F] {bits : Nat}
    (roots : Fin bits → F) (nonzero : ∀ i, roots i ≠ 0) (indices : List (Fin bits))
    (a : Fin (2^bits) → F) :
    runIndices false roots indices a = runForward (indices.map fun i => radixStage bits i (roots i) (nonzero i)) a := by
  induction indices generalizing a with
  | nil => rfl
  | cons i rest ih =>
    simp only [runIndices, List.map_cons, runForward, ih]
    rw [radix_forward_correct bits i (roots i) (nonzero i)]

theorem run_backward_correct {F : Type} [Field F] {bits : Nat}
    (roots : Fin bits → F) (nonzero : ∀ i, roots i ≠ 0) (indices : List (Fin bits))
    (a : Fin (2^bits) → F) :
    runIndices true roots indices.reverse a = runBackward (indices.map fun i => radixStage bits i (roots i) (nonzero i)) a := by
  induction indices generalizing a with
  | nil => rfl
  | cons i rest ih =>
    simp only [List.reverse_cons, run_indices_append, List.map_cons, runBackward, runIndices, ih]
    exact radix_backward_correct bits i (roots i) (nonzero i) _

def swapAt {I F : Type} [DecidableEq I] (a : I → F) (left right : I) : I → F :=
  write (write a left (a right)) right (a left)

def permutationPrefix {F : Type} {n : Nat} (permutation : Fin n → Fin n) (a : Fin n → F) :
    Nat → (Fin n → F)
  | 0 => a
  | count+1 =>
    let previous := permutationPrefix permutation a count
    if bound : count < n then
      let i : Fin n := ⟨count, bound⟩
      if count < (permutation i).val then swapAt previous i (permutation i) else previous
    else previous

theorem permutation_prefix_correct {F : Type} {n : Nat} (permutation : Fin n → Fin n)
    (involutive : ∀ i, permutation (permutation i) = i) (a : Fin n → F) (count : Nat) :
    ∀ q, permutationPrefix permutation a count q =
      if q.val < count ∨ (permutation q).val < count then a (permutation q) else a q := by
  induction count with
  | zero => intro q; simp [permutationPrefix]
  | succ count ih =>
    intro q
    by_cases bound : count < n
    · let i : Fin n := ⟨count, bound⟩
      simp only [permutationPrefix, dite_eq_left bound]
      change (if count < (permutation i).val then
        swapAt (permutationPrefix permutation a count) i (permutation i)
        else permutationPrefix permutation a count) q = _
      by_cases ascending : count < (permutation i).val
      · rw [ite_eq_left ascending]
        by_cases atRight : q = permutation i
        · subst q
          simp only [swapAt, write, ite_true, ih, involutive]
          have leftOld : ¬(i.val < count ∨ (permutation i).val < count) := by
            change ¬(count < count ∨ (permutation i).val < count)
            omega
          have rightNew : (permutation i).val < count+1 ∨ i.val < count+1 := by
            right; exact Nat.lt_succ_self count
          rw [ite_eq_right leftOld, ite_eq_left rightNew]
        · by_cases atLeft : q = i
          · subst q
            simp only [swapAt, write, atRight, ite_false, ite_true, ih, involutive]
            have rightOld : ¬((permutation i).val < count ∨ i.val < count) := by
              change ¬((permutation i).val < count ∨ count < count)
              omega
            have leftNew : i.val < count+1 ∨ (permutation i).val < count+1 := by
              left; exact Nat.lt_succ_self count
            rw [ite_eq_right rightOld, ite_eq_left leftNew]
          · simp only [swapAt, write, atRight, atLeft, ite_false, ih]
            have leftNe : q.val ≠ count := by
              intro eq; exact atLeft (Fin.ext eq)
            have rightNe : (permutation q).val ≠ count := by
              intro eq
              have atIndex : permutation q = i := Fin.ext eq
              have same : q = permutation i := by rw [← involutive q, atIndex]
              exact atRight same
            have same : (q.val < count ∨ (permutation q).val < count) =
                (q.val < count+1 ∨ (permutation q).val < count+1) := by
              apply propext; omega
            simp only [same]
      · rw [ite_eq_right ascending, ih]
        by_cases fixed : q = permutation q
        · simp only [← fixed, ite_self]
        · have same : (q.val < count ∨ (permutation q).val < count) =
              (q.val < count+1 ∨ (permutation q).val < count+1) := by
            apply propext
            constructor
            · omega
            · intro newer
              by_cases older : q.val < count ∨ (permutation q).val < count
              · exact older
              · exfalso
                have boundary : q.val = count ∨ (permutation q).val = count := by omega
                rcases boundary with atLeft | atRight
                · have atIndex : q = i := Fin.ext atLeft
                  have distinct : (permutation i).val ≠ count := by
                    intro eq
                    apply fixed
                    rw [atIndex]
                    exact (Fin.ext eq).symm
                  have previous : (permutation q).val < count := by rw [atIndex]; omega
                  exact older (Or.inr previous)
                · have atIndex : permutation q = i := Fin.ext atRight
                  have qAt : q = permutation i := by rw [← involutive q, atIndex]
                  have distinct : (permutation i).val ≠ count := by
                    intro eq
                    apply fixed
                    rw [atIndex, qAt]
                    exact Fin.ext eq
                  have previous : q.val < count := by rw [qAt]; omega
                  exact older (Or.inl previous)
          simp only [same]
    · simp only [permutationPrefix, dite_eq_right bound, ih]
      have before : q.val < count := by have := q.isLt; omega
      have after : q.val < count+1 := by omega
      simp only [before, after, true_or, ite_true]

theorem permutation_pass_correct {F : Type} {n : Nat} (permutation : Fin n → Fin n)
    (involutive : ∀ i, permutation (permutation i) = i) (a : Fin n → F) :
    permutationPrefix permutation a n = permute permutation a := by
  funext q
  rw [permutation_prefix_correct permutation involutive]
  simp only [q.isLt, true_or, ite_true, permute]

theorem reverse_zero (bits : Nat) :
    reverseIndex bits ⟨0, Nat.two_pow_pos bits⟩ = ⟨0, Nat.two_pow_pos bits⟩ := by
  have zero : (0#bits).reverse = 0#bits := BitVec.reverse_eq_zero_iff.mpr rfl
  apply Fin.ext
  simp [reverseIndex, zero]

-- Nim starts this loop at one. The extra zero iteration in the prefix model
-- is a no-op, including the one-element transform.
theorem first_permutation_iteration {F : Type} (bits : Nat) (a : Fin (2^bits) → F) :
    permutationPrefix (reverseIndex bits) a 1 = a := by
  simp [permutationPrefix, Nat.two_pow_pos, reverse_zero]

-- FftCounter refines these indices to the AND/XOR/shift loop and composes that
-- result with the sequential stage model defined here.
def forwardAlgorithm {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  runIndices false roots (List.finRange bits) (permutationPrefix (reverseIndex bits) a (2^bits))

def backwardAlgorithm {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  scale (((2^bits : Nat) : F)⁻¹) (permutationPrefix (reverseIndex bits)
    (runIndices true roots (List.finRange bits).reverse a) (2^bits))

theorem forward_algorithm_correct {F : Type} [Field F] [IsCharP F ZkBuild.scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    forwardAlgorithm bits (scalarStageRoots bits) a = CosetQap.dft (ScalarRoots.evaluationRoots bits) a := by
  unfold forwardAlgorithm
  rw [permutation_pass_correct _ (reverse_index_involutive bits)]
  rw [run_forward_correct (scalarStageRoots bits) (scalar_stage_roots_nonzero bits)]
  exact ScalarRoots.forward_correct bits bound a

theorem backward_algorithm_correct {F : Type} [Field F] [IsCharP F ZkBuild.scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    backwardAlgorithm bits (scalarStageRoots bits) (CosetQap.dft (ScalarRoots.evaluationRoots bits) a) = a := by
  unfold backwardAlgorithm
  rw [permutation_pass_correct _ (reverse_index_involutive bits)]
  rw [run_backward_correct (scalarStageRoots bits) (scalar_stage_roots_nonzero bits)]
  exact ScalarRoots.inverse_correct bits bound a

def executionTransform {F : Type} [Field F] [IsCharP F ZkBuild.scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) : CosetQap.InverseTransform (ScalarRoots.evaluationRoots (F := F) bits) where
  inverse := backwardAlgorithm bits (scalarStageRoots bits)
  leftInverse := backward_algorithm_correct bits bound

theorem quotient_algorithm_correct {F : Type} [Field F] [IsCharP F ZkBuild.scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (low high : Fin (2^bits) → F)
    (satisfied : ∀ i, CosetQap.splitNumerator low high (ScalarRoots.evaluationRoots bits i) = 0) :
    CosetQap.recoverQuotient (ScalarRoots.evaluationRoots bits) (executionTransform bits bound) 7 low high = high := by
  apply CosetQap.coset_quotient_correct
    (ScalarRoots.evaluationRoots bits) (executionTransform bits bound) (ScalarRoots.evaluation_roots_unity bits bound) 7
  · simpa only [Semiring.natCast_eq_ofNat] using
      small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  · exact ScalarRoots.coset_disjoint bits bound
  · exact satisfied

#print axioms run_pairs_at
#print axioms pairs_distinct
#print axioms forward_stage_correct
#print axioms backward_stage_correct
#print axioms block_loop_correct
#print axioms nested_forward_correct
#print axioms nested_backward_correct
#print axioms permutation_pass_correct
#print axioms first_permutation_iteration
#print axioms forward_algorithm_correct
#print axioms backward_algorithm_correct
#print axioms quotient_algorithm_correct

end ZkBuild.FftInPlace
