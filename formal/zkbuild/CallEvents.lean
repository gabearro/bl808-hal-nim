import SignatureLists
import VariableEvents

namespace ZkBuild.CallEvents

open Lean.Grind SignatureLists StaticEvents VariableEvents
attribute [local instance] Semiring.natCast

def InputOk (expected actual : Nat) : Prop := actual = expected ∨ actual = 7

inductive Aligned : List Nat → List Nat → Prop where
  | nil : Aligned [] []
  | cons {e a : Nat} {es actuals : List Nat} : InputOk e a → Aligned es actuals → Aligned (e :: es) (a :: actuals)

def callSignature (code : Nat) (params results current : List Nat) (tableTag : Nat) :
    Option (List Nat × List Nat) :=
  if code < 0x10 ∨ code > 0x13 then none
  else if (code = 0x11 ∨ code = 0x13) ∧ tableTag ≠ 5 then none
  else if code ≥ 0x12 ∧ current ≠ results then none
  else some ((if code = 0x11 ∨ code = 0x13 then [0] else []) ++ params.reverse,
    if code ≥ 0x12 then [] else results)

theorem direct_signature (params results current : List Nat) (tableTag : Nat) :
    callSignature 0x10 params results current tableTag = some (params.reverse, results) := by simp [callSignature]

theorem tail_signature (params results : List Nat) (tableTag : Nat) :
    callSignature 0x12 params results results tableTag = some (params.reverse, []) := by simp [callSignature]

theorem tail_mismatch (params results current : List Nat) (different : current ≠ results) :
    callSignature 0x12 params results current 5 = none ∧ callSignature 0x13 params results current 5 = none := by
  simp [callSignature, different]

/- The abstract signature walk, after field guards and authenticated reads.
   The nil terminator is never a readable cell. -/
inductive CursorBody (table : Table) : Nat → Nat → Bool → List Token → Prop where
  | done : CursorBody table 0 0 false []
  | clear (results : Nat) : CursorBody table 0 results true [.clear]
  | pop {id results : Nat} {node : Node} {tail : Bool} {value : Nat} {rest : List Token} :
      id ≠ 0 → table id = some node → InputOk node.tag.val value →
      CursorBody table node.next results tail rest → CursorBody table id results tail (.pop value :: rest)
  | push {id : Nat} {node : Node} {rest : List Token} :
      id ≠ 0 → table id = some node → CursorBody table 0 node.next false rest →
      CursorBody table 0 id false (.push node.tag.val :: rest)

inductive Body : List Nat → List Nat → Bool → List Token → Prop where
  | done : Body [] [] false []
  | clear (results : List Nat) : Body [] results true [.clear]
  | pop {expected : Nat} {params results : List Nat} {tail : Bool} {actual : Nat} {rest : List Token} :
      InputOk expected actual → Body params results tail rest → Body (expected :: params) results tail (.pop actual :: rest)
  | push {value : Nat} {results : List Nat} {rest : List Token} :
      Body [] results false rest → Body [] (value :: results) false (.push value :: rest)

theorem cursor_refinement (table : Table) (p r : Nat) (tail : Bool) (tokens : List Token)
    (walk : CursorBody table p r tail tokens) (params results : List Nat)
    (pr : Represents table p params) (rr : Represents table r results) : Body params results tail tokens := by
  induction walk generalizing params results with
  | done =>
    have pe := represents_zero table params pr
    have re := represents_zero table results rr
    subst params; subst results
    exact .done
  | clear id =>
    have pe := represents_zero table params pr
    subst params
    exact .clear results
  | @pop id r node tail value rest nonzero found typed walk ih =>
    obtain ⟨remaining, same, rep⟩ := uncons table id node params nonzero found pr
    subst params
    exact .pop typed (ih remaining results rep rr)
  | @push id node rest nonzero found walk ih =>
    have pe := represents_zero table params pr
    obtain ⟨remaining, same, rep⟩ := uncons table id node results nonzero found rr
    subst params; subst results
    exact .push (ih [] remaining .nil rep)

theorem cursor_complete (table : Table) (params results : List Nat) (tail : Bool) (tokens : List Token)
    (body : Body params results tail tokens) (p r : Nat)
    (pr : Represents table p params) (rr : Represents table r results) : CursorBody table p r tail tokens := by
  induction body generalizing p r with
  | done =>
    have pe := represents_empty table p pr
    have re := represents_empty table r rr
    subst p; subst r
    exact .done
  | clear results =>
    have pe := represents_empty table p pr
    subst p
    exact .clear r
  | @pop expected params results tail actual rest typed body ih =>
    cases pr with
    | cons nonzero found rep => exact .pop nonzero found typed (ih _ r rep rr)
  | @push value results rest body ih =>
    have pe := represents_empty table p pr
    subst p
    cases rr with
    | cons nonzero found rep => exact .push nonzero found (ih 0 _ .nil rep)

theorem normal_shape (params results : List Nat) (tokens : List Token) (body : Body params results false tokens) :
    ∃ actuals, Aligned params actuals ∧ tokens = actuals.map Token.pop ++ results.map Token.push := by
  generalize tailEq : false = tail at body
  induction body with
  | done => exact ⟨[], .nil, rfl⟩
  | clear results => cases tailEq
  | pop typed body ih =>
    obtain ⟨actuals, types, shape⟩ := ih tailEq
    exact ⟨_ :: actuals, .cons typed types, by simp [shape]⟩
  | push body ih =>
    obtain ⟨actuals, types, shape⟩ := ih rfl
    have empty : actuals = [] := by cases types; rfl
    subst actuals
    exact ⟨[], .nil, by simp_all⟩

theorem tail_shape (params results : List Nat) (tokens : List Token) (body : Body params results true tokens) :
    ∃ actuals, Aligned params actuals ∧ tokens = actuals.map Token.pop ++ [.clear] := by
  generalize tailEq : true = tail at body
  induction body with
  | done => cases tailEq
  | clear results => exact ⟨[], .nil, rfl⟩
  | pop typed body ih =>
    obtain ⟨actuals, types, shape⟩ := ih tailEq
    exact ⟨_ :: actuals, .cons typed types, by simp [shape]⟩
  | push body ih => cases tailEq

theorem normal_complete (params actuals results : List Nat) (typed : Aligned params actuals) :
    Body params results false (actuals.map Token.pop ++ results.map Token.push) := by
  induction typed with
  | nil =>
    simp only [List.map_nil, List.nil_append]
    induction results with
    | nil => exact .done
    | cons value rest ih => exact .push ih
  | cons head tail ih => exact .pop head ih

theorem tail_complete (params actuals results : List Nat) (typed : Aligned params actuals) :
    Body params results true (actuals.map Token.pop ++ [.clear]) := by
  induction typed with
  | nil => exact .clear results
  | cons head tail ih => exact .pop head ih

theorem input_gate_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Fin 8) (expected : Fin 7) (gate : MatchGates (F := F) actual.val expected.val) :
    InputOk expected.val actual.val := VariableEvents.match_sound actual expected gate

theorem output_gate_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Fin 8) (expected : Fin 7) (gate : (actual.val : F)-(expected.val : F) = 0) :
    actual.val = expected.val := NumericEvents.nat_eq (F := F) _ _
      (by have := actual.isLt; simp [NumericEvents.countBound]; omega)
      (by have := expected.isLt; simp [NumericEvents.countBound]; omega) (by grind)

def flag {F : Type} [Field F] (b : Bool) : F := if b then 1 else 0

theorem sum_zero_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (cursor : Nat) (a b : Bool) (bound : cursor < 2^32)
    (gate : (cursor : F)+flag a+flag b = 0) : cursor = 0 ∧ a = false ∧ b = false := by
  have eq : ((cursor+a.toNat+b.toNat : Nat) : F) = (0 : F) := by
    cases a <;> cases b <;>
      simp [flag, Bool.toNat, Semiring.natCast_add, Semiring.natCast_zero, Semiring.natCast_one] at gate ⊢ <;> grind
  have zero : cursor+a.toNat+b.toNat = 0 := NumericEvents.nat_eq (F := F) _ _
    (by cases a <;> cases b <;> simp [Bool.toNat, NumericEvents.countBound] <;> omega)
    (by decide) (by simpa only [Semiring.natCast_zero] using eq)
  cases a <;> cases b <;> simp [Bool.toNat] at zero ⊢ <;> omega

theorem pop_order_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (pushed cleared : Bool) (gate : flag pushed+flag cleared = (0 : F)) :
    pushed = false ∧ cleared = false := by
  have sum := sum_zero_sound (F := F) 0 pushed cleared (by decide)
    (by simp only [Semiring.natCast_zero]; grind)
  exact sum.2

theorem push_order_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (tail pending cleared : Bool) (gate : flag tail+flag pending+flag cleared = (0 : F)) :
    tail = false ∧ pending = false ∧ cleared = false := by
  have cast : ((tail.toNat : Nat) : F) = flag tail := by cases tail <;> simp [flag, Bool.toNat, Semiring.natCast_zero, Semiring.natCast_one]
  have sum := sum_zero_sound (F := F) tail.toNat pending cleared
    (by cases tail <;> simp [Bool.toNat]) (by simpa [cast] using gate)
  have normal : tail = false := by cases tail <;> simp [Bool.toNat] at sum ⊢
  exact ⟨normal, sum.2⟩

theorem clear_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (params : Nat) (tail pending cleared : Bool) (pb : params < 2^32)
    (authorized : 1-flag tail = (0 : F)) (empty : (params : F)+flag pending+flag cleared = 0) :
    tail = true ∧ params = 0 ∧ pending = false ∧ cleared = false := by
  have tailEq := VariableTyping.mutation_gate tail authorized
  exact ⟨tailEq, sum_zero_sound params pending cleared pb empty⟩

theorem end_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (params results : Nat) (tail pending cleared : Bool) (pb : params < 2^32) (rb : results < 2^32)
    (args : (params : F) = 0) (index : flag pending = (0 : F))
    (clear : flag cleared-flag tail = (0 : F)) (outputs : (1-flag tail)*(results : F) = 0) :
    params = 0 ∧ pending = false ∧ cleared = tail ∧ (tail = false → results = 0) := by
  have paramsZero := NumericEvents.nat_eq (F := F) params 0
    (by simp [NumericEvents.countBound]; omega) (by decide) (by simpa only [Semiring.natCast_zero] using args)
  have indexZero : pending = false := by
    cases pending with
    | false => rfl
    | true => exact False.elim (Field.zero_ne_one index.symm)
  have clearEq : cleared = tail := by
    cases cleared <;> cases tail <;> try rfl
    all_goals
      have bad : (1 : F) = 0 := by simp [flag] at clear; grind
      exact False.elim (Field.zero_ne_one bad.symm)
  refine ⟨paramsZero, indexZero, clearEq, ?_⟩
  intro normal
  subst tail
  apply NumericEvents.nat_eq (F := F) results 0
    (by simp [NumericEvents.countBound]; omega) (by decide)
  simp [flag] at outputs
  simp only [Semiring.natCast_zero]
  grind

theorem cursor_update {F : Type} [Field F] (enabled : Bool) (before next : Nat) (after : F)
    (gate : after = (before : F)+flag enabled*((next : F)-(before : F))) :
    after = ((if enabled then next else before : Nat) : F) := by
  cases enabled <;> simp [flag] at gate ⊢ <;> grind

theorem cleared_update {F : Type} [Field F] (enabled before : Bool) (after : F)
    (once : enabled = true → before = false) (gate : after = flag before+flag enabled) :
    after = flag (before || enabled) := by
  cases enabled <;> cases before <;> simp_all [flag] <;> grind

#print axioms cursor_refinement
#print axioms cursor_complete
#print axioms normal_shape
#print axioms tail_shape
#print axioms normal_complete
#print axioms tail_complete
#print axioms input_gate_sound
#print axioms output_gate_sound
#print axioms sum_zero_sound
#print axioms pop_order_sound
#print axioms push_order_sound
#print axioms clear_sound
#print axioms end_sound
#print axioms cursor_update
#print axioms cleared_update

end ZkBuild.CallEvents
