import ByteCompileComposition

/- Semantic facts needed by the byte-to-slot bridge. A zero token represents
   a nop; every other operation is nonzero and includes the exact i32 constant.
   Queue overflow must fail instead of discarding an executable prefix. -/
namespace ZkBuild.ByteCompileQueue

open Lean.Grind
attribute [local instance] Ring.intCast Semiring.natCast

def binaryToken : BinOp → Nat
  | .add => 4 | .sub => 5 | .mul => 6 | .band => 7 | .bor => 8 | .bxor => 9

def token : Op → Nat
  | .nop => 0
  | .get index => 1+index.val
  | .const value => 3+16*value.toNat
  | .binary op => binaryToken op

theorem token_zero (op : Op) : token op = 0 ↔ op = .nop := by
  cases op with
  | nop => simp [token]
  | get index => simp [token]
  | const value => simp [token]
  | binary op => cases op <;> simp [token, binaryToken]

theorem token_bound (op : Op) : token op < 2^36 := by
  cases op with
  | nop => simp [token]
  | get index => have := index.isLt; simp only [token]; omega
  | const value => have := value.isLt; simp only [token]; omega
  | binary op => cases op <;> decide

theorem token_injective (a b : Op) (same : token a = token b) : a = b := by
  cases a with
  | nop => exact ((token_zero b).mp same.symm).symm
  | get left =>
    cases b with
    | nop => simp [token] at same
    | get right =>
      have eq : left.val = right.val := by simp only [token] at same; omega
      exact congrArg Op.get (Fin.ext eq)
    | const value => have := left.isLt; simp only [token] at same; omega
    | binary op => cases op <;> simp only [token, binaryToken] at same <;> have := left.isLt <;> omega
  | const left =>
    cases b with
    | nop => simp [token] at same
    | get index => have := index.isLt; simp only [token] at same; omega
    | const right =>
      have eq : left.toNat = right.toNat := by simp only [token] at same; omega
      exact congrArg Op.const (BitVec.eq_of_toNat_eq eq)
    | binary op => cases op <;> simp only [token, binaryToken] at same <;> omega
  | binary op =>
    cases op <;> cases b with
    | nop => simp [token, binaryToken] at same
    | get index => have := index.isLt; simp only [token, binaryToken] at same; omega
    | const value => simp only [token, binaryToken] at same; omega
    | binary other => cases other <;> simp_all [token, binaryToken]

theorem field_token_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Op) (same : (token a : F) = (token b : F)) : a = b := by
  have aBound : token a < scalarModulus := Nat.lt_trans (token_bound a) (by decide)
  have bBound : token b < scalarModulus := Nat.lt_trans (token_bound b) (by decide)
  exact token_injective a b ((IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp same)

theorem field_token_zero {F : Type} [CommRing F] [IsCharP F scalarModulus] (op : Op) :
    (token op : F) = 0 ↔ op = .nop := by
  constructor
  · intro same
    apply field_token_injective (F := F) op .nop
    simpa [token, Semiring.natCast_zero] using same
  · rintro rfl
    simp [token, Semiring.natCast_zero]

theorem select_equation {F : Type} [CommRing F] (selector yes no output : F)
    (_binary : selector = 0 ∨ selector = 1)
    (equation : selector * (yes-no) = output-no) :
    (selector = 0 → output = no) ∧ (selector = 1 → output = yes) := by grind

def stripNops (ops : List Op) : List Op := ops.filter fun op => op != .nop

theorem strip_execution (locals : Fin 2 → Word) (ops : List Op) :
    ∀ stack, run locals (stripNops ops) stack = run locals ops stack := by
  induction ops with
  | nil => intro stack; rfl
  | cons op rest ih =>
    intro stack
    cases op <;> simp only [stripNops, List.filter_cons, bne_self_eq_false,
      Bool.false_eq_true, ↓reduceIte, run, step, Option.bind_some] at *
    · exact ih stack
    · exact ih _
    · exact ih _
    · cases stack with
      | nil => rfl
      | cons right tail =>
        cases tail with
        | nil => rfl
        | cons left tail => exact ih _

theorem leading_nops (locals : Fin 2 → Word) (count : Nat) (ops : List Op) (stack : List Word) :
    run locals (List.replicate count .nop ++ ops) stack = run locals ops stack := by
  induction count with
  | zero => rfl
  | succ count ih => simpa [List.replicate_succ, run, step] using ih

def padded (capacity : Nat) (items : List Nat) : List Nat :=
  List.replicate (capacity-items.length) 0 ++ items

def shift (items : List Nat) (value : Nat) : List Nat := items.drop 1 ++ [value]

theorem shift_padded (capacity : Nat) (items : List Nat) (value : Nat)
    (room : items.length < capacity) :
    shift (padded capacity items) value = padded capacity (items ++ [value]) := by
  have positive : capacity-items.length = (capacity-items.length-1)+1 := by omega
  simp only [padded]
  rw [positive, List.replicate_succ]
  simp only [List.cons_append, shift, List.drop_succ_cons, List.drop_zero,
    List.length_append, List.length_singleton, List.append_assoc]
  rw [show capacity - items.length - 1 = capacity - (items.length+1) by omega]

theorem padded_head_zero (capacity : Nat) (items : List Nat) (room : items.length < capacity) :
    (padded capacity items).head? = some 0 := by
  have positive : capacity-items.length = (capacity-items.length-1)+1 := by omega
  unfold padded
  rw [positive, List.replicate_succ]
  rfl

theorem full_head_not_zero (capacity : Nat) (items : List Nat)
    (full : items.length = capacity) (nonzero : ∀ value ∈ items, value ≠ 0) :
    (padded capacity items).head? ≠ some 0 := by
  simp only [padded, full, Nat.sub_self, List.replicate_zero, List.nil_append]
  cases items with
  | nil => simp
  | cons first rest =>
    have firstNonzero := nonzero first (by simp)
    simpa using firstNonzero

def collect : List Nat → List Nat → Option (List Nat)
  | queue, [] => some queue
  | queue, value :: rest =>
    if queue.head? = some 0 then collect (shift queue value) rest else none

theorem collect_preserves_all (capacity : Nat) (rest : List Nat) :
    ∀ seen output, seen.length ≤ capacity →
      (∀ value ∈ seen, value ≠ 0) → (∀ value ∈ rest, value ≠ 0) →
      collect (padded capacity seen) rest = some output →
      (seen ++ rest).length ≤ capacity ∧ output = padded capacity (seen ++ rest) := by
  induction rest with
  | nil =>
    intro seen output bound _ _ accepted
    simp only [collect, Option.some.injEq] at accepted
    exact ⟨by simpa using bound, by simpa using accepted.symm⟩
  | cons value rest ih =>
    intro seen output bound nonzeroSeen nonzeroRest accepted
    by_cases room : seen.length < capacity
    · rw [collect, ite_eq_left (padded_head_zero capacity seen room), shift_padded capacity seen value room] at accepted
      have nextNonzero : ∀ x ∈ seen ++ [value], x ≠ 0 := by
        intro x member
        rcases List.mem_append.mp member with prior | current
        · exact nonzeroSeen x prior
        · have same : x = value := by simpa using current
          subst x
          exact nonzeroRest value (by simp)
      have result := ih (seen ++ [value]) output (by simp; omega) nextNonzero
        (fun x member => nonzeroRest x (by simp [member])) accepted
      simpa only [List.append_assoc, List.singleton_append] using result
    · have full : seen.length = capacity := by omega
      rw [collect, ite_eq_right (full_head_not_zero capacity seen full nonzeroSeen)] at accepted
      contradiction

theorem collect_fits (capacity : Nat) (rest : List Nat) :
    ∀ seen, (seen ++ rest).length ≤ capacity →
      collect (padded capacity seen) rest = some (padded capacity (seen ++ rest)) := by
  induction rest with
  | nil => intro seen _; simp [collect]
  | cons value rest ih =>
    intro seen bound
    have room : seen.length < capacity := by simp only [List.length_append, List.length_cons] at bound; omega
    rw [collect, ite_eq_left (padded_head_zero capacity seen room), shift_padded capacity seen value room]
    have result := ih (seen ++ [value]) (by simpa [List.append_assoc] using bound)
    simpa only [List.append_assoc, List.singleton_append] using result

theorem queue_exact (capacity : Nat) (events output : List Nat)
    (nonzero : ∀ value ∈ events, value ≠ 0) :
    collect (List.replicate capacity 0) events = some output ↔
      events.length ≤ capacity ∧ output = padded capacity events := by
  constructor
  · intro accepted
    have start : padded capacity [] = List.replicate capacity 0 := by simp [padded]
    rw [← start] at accepted
    simpa using collect_preserves_all capacity events [] output (by simp) (by simp) nonzero accepted
  · rintro ⟨bound, rfl⟩
    simpa [padded] using collect_fits capacity events [] (by simpa using bound)

#print axioms field_token_injective
#print axioms strip_execution
#print axioms shift_padded
#print axioms queue_exact

end ZkBuild.ByteCompileQueue
