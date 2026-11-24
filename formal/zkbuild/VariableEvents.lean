import VariableTyping

/- The field gates used by wasm_variable_events.nim, after opcode selection
   and environment lookup. The declared type is authenticated separately.
   Out-of-arity pop indices use type zero; the completed-body proof shows
   such an index cannot occur in an accepted instruction. -/
namespace ZkBuild.VariableEvents

open Lean.Grind OperandEvents ControlEvents StaticTyping StaticEvents
attribute [local instance] Semiring.natCast

def inputType (rule : Rule) (index : Nat) : Nat := rule.inputs[index]?.getD 0

def MatchGates {F : Type} [Field F] (actual expected : Nat) : Prop :=
  ∃ (same unknown a b : F),
    ((actual : F)-(expected : F))*same = 0 ∧
    ((actual : F)-(expected : F))*a = 1-same ∧
    ((actual : F)-7)*unknown = 0 ∧
    ((actual : F)-7)*b = 1-unknown ∧ 1-same-unknown = 0

theorem match_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Fin 8) (expected : Fin 7) (gates : MatchGates (F := F) actual.val expected.val) :
    actual.val = expected.val ∨ actual.val = 7 := by
  obtain ⟨same, unknown, a, b, sameZero, sameInv, unknownZero, unknownInv, accepted⟩ := gates
  have ax : actual.val < NumericEvents.countBound := by have := actual.isLt; simp [NumericEvents.countBound]; omega
  have ex : expected.val < NumericEvents.countBound := by have := expected.isLt; simp [NumericEvents.countBound]; omega
  by_cases eq : (actual.val : F) = (expected.val : F)
  · exact Or.inl (NumericEvents.nat_eq (F := F) _ _ ax ex eq)
  · have sameIsZero : same = 0 := by grind
    have isUnknown : (actual.val : F) = (7 : F) := by grind
    apply Or.inr
    apply NumericEvents.nat_eq (F := F) _ _ ax (by decide)
    have seven : ((7 : Nat) : F) = (7 : F) := Semiring.natCast_eq_ofNat 7
    rw [seven]
    exact isUnknown

structure Gates {F : Type} [Field F] (rule : Rule) (kind : Kind)
    (actual : Fin 8) (pops pushes : Nat) : Prop where
  matchInput : kind = .pop → MatchGates (F := F) actual.val (inputType rule pops)
  popOrder : selected kind .pop*(pushes : F) = 0
  outputType : selected kind .push*((actual.val : F)-(rule.output.getD 0 : F)) = 0
  outputExists : selected kind .push*(1-(outputCount rule : F)) = 0
  pushArity : selected kind .push*((pops : F)-(rule.inputs.length : F)) = 0
  pushOnce : selected kind .push*(pushes : F) = 0
  noControl : selected kind .controlPush+selected kind .controlPop+selected kind .clear = (0 : F)
  endPops : selected kind .instructionEnd*((pops : F)-(rule.inputs.length : F)) = 0
  endPushes : selected kind .instructionEnd*((pushes : F)-(outputCount rule : F)) = 0

theorem pop_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (actual : Fin 8) (pops pushes : Nat)
    (typeBound : inputType rule pops < 7) (pushesBound : pushes < NumericEvents.countBound)
    (gates : Gates (F := F) rule .pop actual pops pushes) :
    (actual.val = inputType rule pops ∨ actual.val = 7) ∧ pushes = 0 := by
  refine ⟨match_sound actual ⟨inputType rule pops, typeBound⟩ (gates.matchInput rfl), ?_⟩
  have order := gates.popOrder
  simp [selected, flag] at order
  exact NumericEvents.nat_eq (F := F) _ _ pushesBound (by decide)
    (by simp only [Semiring.natCast_zero]; grind)

theorem push_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (actual : Fin 8) (pops pushes : Nat)
    (arityBound : rule.inputs.length < NumericEvents.countBound)
    (tagBound : rule.output.getD 0 < NumericEvents.countBound)
    (popsBound : pops < NumericEvents.countBound) (pushesBound : pushes < NumericEvents.countBound)
    (gates : Gates (F := F) rule .push actual pops pushes) :
    rule.output = some actual.val ∧ pops = rule.inputs.length ∧ pushes = 0 := by
  have existsGate := gates.outputExists
  have typed := gates.outputType
  have arity := gates.pushArity
  have once := gates.pushOnce
  simp [selected, flag] at existsGate typed arity once
  have tag : actual.val = rule.output.getD 0 := NumericEvents.nat_eq (F := F) _ _
    (by have := actual.isLt; simp [NumericEvents.countBound]; omega) tagBound (by grind)
  refine ⟨?_, NumericEvents.nat_eq (F := F) _ _ popsBound arityBound (by grind),
    NumericEvents.nat_eq (F := F) _ _ pushesBound (by decide) (by simp only [Semiring.natCast_zero]; grind)⟩
  cases output : rule.output with
  | none =>
    have bad : (1 : F) = 0 := by simp [outputCount, output, Semiring.natCast_zero] at existsGate; grind
    exact False.elim (Field.zero_ne_one bad.symm)
  | some value => simp [output] at tag; simp [output, tag]

theorem end_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (actual : Fin 8) (pops pushes : Nat)
    (arityBound : rule.inputs.length < NumericEvents.countBound)
    (popsBound : pops < NumericEvents.countBound) (pushesBound : pushes < NumericEvents.countBound)
    (gates : Gates (F := F) rule .instructionEnd actual pops pushes) :
    pops = rule.inputs.length ∧ pushes = outputCount rule := by
  have p := gates.endPops
  have q := gates.endPushes
  simp [selected, flag] at p q
  refine ⟨NumericEvents.nat_eq (F := F) _ _ popsBound arityBound (by grind), ?_⟩
  exact NumericEvents.nat_eq (F := F) _ _ pushesBound
    (by cases h : rule.output <;> simp [outputCount, h, NumericEvents.countBound]) (by grind)

theorem no_control {F : Type} [Field F] (rule : Rule) (kind : Kind)
    (actual : Fin 8) (pops pushes : Nat) (gates : Gates (F := F) rule kind actual pops pushes) :
    kind ≠ .controlPush ∧ kind ≠ .controlPop ∧ kind ≠ .clear := by
  have h := gates.noControl
  cases kind <;> simp [selected, flag] at h ⊢ <;>
    have bad : (1 : F) = 0 := by grind
  all_goals exact False.elim (Field.zero_ne_one bad.symm)

def Body (rule : Rule) (pops pushes : Nat) : List Token → Prop
  | [] => pops = rule.inputs.length ∧ pushes = outputCount rule
  | .pop value :: rest => pushes = 0 ∧ (value = inputType rule pops ∨ value = 7) ∧
      Body rule (pops+1) pushes rest
  | .push value :: rest => pushes = 0 ∧ pops = rule.inputs.length ∧ rule.output = some value ∧
      Body rule pops (pushes+1) rest
  | .clear :: _ => False

theorem pops_bound (rule : Rule) (tokens : List Token) (pops pushes : Nat)
    (body : Body rule pops pushes tokens) : pops ≤ rule.inputs.length := by
  induction tokens generalizing pops pushes with
  | nil => exact Nat.le_of_eq body.1
  | cons token rest ih =>
    cases token with
    | pop value => have := ih (pops+1) pushes body.2.2; omega
    | push value => exact Nat.le_of_eq body.2.1
    | clear => exact False.elim body

theorem to_static (rule : Rule) (tokens : List Token) (pops pushes : Nat)
    (noClear : rule.clears = false)
    (known : ∀ t ∈ rule.inputs, t < 7) (body : Body rule pops pushes tokens) :
    StaticEvents.Body rule pops pushes 0 tokens := by
  induction tokens generalizing pops pushes with
  | nil => exact ⟨body.1, body.2, by simp [noClear, Bool.toNat]⟩
  | cons token rest ih =>
    cases token with
    | clear => exact False.elim body
    | push value => exact ⟨body.1, body.2.1, body.2.2.1, ih pops (pushes+1) body.2.2.2⟩
    | pop value =>
      have bound := pops_bound rule rest (pops+1) pushes body.2.2
      have index : pops < rule.inputs.length := by omega
      have present : rule.inputs[pops]? = some rule.inputs[pops] := List.getElem?_eq_getElem index
      have typed : allowed rule.inputs[pops] value := by
        have expected := known rule.inputs[pops] (List.getElem_mem index)
        rcases body.2.1 with same | unknown
        · have same' : value = rule.inputs[pops] := by simpa [inputType, present] using same
          simp [allowed, same']; omega
        · simp [allowed, unknown]
      have permitted : popAllowed rule pops value = true := by simp [popAllowed, present, typed]
      exact ⟨body.1, permitted, ih (pops+1) pushes body.2.2⟩

theorem body_shape (rule : Rule) (tokens : List Token)
    (noClear : rule.clears = false) (known : ∀ t ∈ rule.inputs, t < 7)
    (body : Body rule 0 0 tokens) :
    ∃ values : List Nat, values.length = rule.inputs.length ∧
      (∀ i (h : i < values.length), popAllowed rule i values[i] = true) ∧
      tokens = values.map Token.pop ++ (rule.output.toList.map Token.push) := by
  simpa using StaticEvents.body_shape rule tokens 0 noClear (to_static rule tokens 0 0 noClear known body)

theorem body_complete (rule : Rule) (inputs : List Nat) (pops : Nat)
    (count : pops+inputs.length = rule.inputs.length)
    (typed : ∀ i (h : i < inputs.length), inputs[i] = inputType rule (pops+i) ∨ inputs[i] = 7) :
    Body rule pops 0 (inputs.map Token.pop ++ rule.output.toList.map Token.push) := by
  induction inputs generalizing pops with
  | nil => cases h : rule.output <;> simp [Body, outputCount, h] <;> simpa using count
  | cons value rest ih =>
    simp only [List.map_cons, List.cons_append, Body]
    refine ⟨trivial, ?_, ?_⟩
    · have h := typed 0 (by simp)
      change value = inputType rule (pops+0) ∨ value = 7 at h
      simpa only [Nat.add_zero] using h
    · apply ih (pops+1) (by simp at count; omega)
      intro i hi
      have h := typed (i+1) (by simpa using hi)
      change rest[i] = inputType rule (pops+(i+1)) ∨ rest[i] = 7 at h
      simpa only [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using h

#print axioms match_sound
#print axioms pop_sound
#print axioms push_sound
#print axioms end_sound
#print axioms no_control
#print axioms pops_bound
#print axioms to_static
#print axioms body_shape
#print axioms body_complete

end ZkBuild.VariableEvents
