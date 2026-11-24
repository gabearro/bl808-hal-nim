import StaticTyping
import NumericEvents

namespace ZkBuild.StaticEvents

open Lean.Grind OperandEvents ControlEvents StaticTyping
attribute [local instance] Semiring.natCast

def outputCount (rule : Rule) : Nat := if rule.output.isSome then 1 else 0

structure Gates {F : Type} [Field F] (rule : Rule) (kind : Kind) (value : Fin 8)
    (index : Fin 4) (pops pushes clears : Nat) : Prop where
  indexEq : selected kind .pop*((pops : F)-(index.val : F)) = 0
  inputAllowed : selected kind .pop*(1-flag (popAllowed rule index.val value.val)) = (0 : F)
  popOrder : selected kind .pop*(pushes : F) = 0
  outputType : selected kind .push*((value.val : F)-(rule.output.getD 0 : F)) = 0
  outputExists : selected kind .push*(1-(outputCount rule : F)) = 0
  pushArity : selected kind .push*((pops : F)-(rule.inputs.length : F)) = 0
  pushOnce : selected kind .push*(pushes : F) = 0
  noControl : selected kind .controlPush+selected kind .controlPop = (0 : F)
  clearAllowed : selected kind .clear*(1-flag rule.clears) = (0 : F)
  clearOnce : selected kind .clear*(clears : F) = 0
  endPops : selected kind .instructionEnd*((pops : F)-(rule.inputs.length : F)) = 0
  endPushes : selected kind .instructionEnd*((pushes : F)-(outputCount rule : F)) = 0
  endClears : selected kind .instructionEnd*((clears : F)-flag rule.clears) = 0

theorem pop_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (index : Fin 4) (pops pushes clears : Nat)
    (popsBound : pops < NumericEvents.countBound) (pushesBound : pushes < NumericEvents.countBound)
    (gates : Gates (F := F) rule .pop value index pops pushes clears) :
    index.val = pops ∧ popAllowed rule pops value.val = true ∧ pushes = 0 := by
  have indexEq := gates.indexEq
  have permitted := gates.inputAllowed
  have order := gates.popOrder
  simp [selected, flag] at indexEq permitted order
  have countEq : pops = index.val := NumericEvents.nat_eq (F := F) _ _ popsBound
    (by have := index.isLt; simp [NumericEvents.countBound]; omega) (by grind)
  refine ⟨countEq.symm, ?_, ?_⟩
  · cases h : popAllowed rule index.val value.val <;> try simpa [countEq] using h
    have bad : (1 : F) = 0 := by simp [flag, h] at permitted; grind
    exact False.elim (Field.zero_ne_one bad.symm)
  · exact NumericEvents.nat_eq (F := F) _ _ pushesBound (by decide)
      (by simp only [Semiring.natCast_zero]; grind)

theorem push_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (index : Fin 4) (pops pushes clears : Nat)
    (arityBound : rule.inputs.length < NumericEvents.countBound)
    (tagBound : rule.output.getD 0 < NumericEvents.countBound)
    (popsBound : pops < NumericEvents.countBound) (pushesBound : pushes < NumericEvents.countBound)
    (gates : Gates (F := F) rule .push value index pops pushes clears) :
    rule.output = some value.val ∧ pops = rule.inputs.length ∧ pushes = 0 := by
  have existsGate := gates.outputExists
  have typed := gates.outputType
  have arity := gates.pushArity
  have once := gates.pushOnce
  simp [selected, flag] at existsGate typed arity once
  have tag : value.val = rule.output.getD 0 := NumericEvents.nat_eq (F := F) _ _
    (by have := value.isLt; simp [NumericEvents.countBound]; omega) tagBound (by grind)
  refine ⟨?_, NumericEvents.nat_eq (F := F) _ _ popsBound arityBound (by grind),
    NumericEvents.nat_eq (F := F) _ _ pushesBound (by decide) (by simp only [Semiring.natCast_zero]; grind)⟩
  cases output : rule.output with
  | none =>
    have bad : (1 : F) = 0 := by simp [outputCount, output, Semiring.natCast_zero] at existsGate; grind
    exact False.elim (Field.zero_ne_one bad.symm)
  | some value => simp [output] at tag; simp [output, tag]

theorem clear_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (index : Fin 4) (pops pushes clears : Nat)
    (clearBound : clears < NumericEvents.countBound)
    (gates : Gates (F := F) rule .clear value index pops pushes clears) : rule.clears = true ∧ clears = 0 := by
  have allowed := gates.clearAllowed
  have once := gates.clearOnce
  simp [selected, flag] at allowed once
  constructor
  · cases h : rule.clears <;> try rfl
    have bad : (1 : F) = 0 := by simp [flag, h] at allowed; grind
    exact False.elim (Field.zero_ne_one bad.symm)
  · exact NumericEvents.nat_eq (F := F) _ _ clearBound (by decide)
      (by simp only [Semiring.natCast_zero]; grind)

theorem end_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (index : Fin 4) (pops pushes clears : Nat)
    (arityBound : rule.inputs.length < NumericEvents.countBound)
    (popsBound : pops < NumericEvents.countBound) (pushesBound : pushes < NumericEvents.countBound)
    (clearsBound : clears < NumericEvents.countBound)
    (gates : Gates (F := F) rule .instructionEnd value index pops pushes clears) :
    pops = rule.inputs.length ∧ pushes = outputCount rule ∧ clears = rule.clears.toNat := by
  have p := gates.endPops
  have q := gates.endPushes
  have c := gates.endClears
  simp [selected, flag] at p q c
  refine ⟨NumericEvents.nat_eq (F := F) _ _ popsBound arityBound (by grind), ?_, ?_⟩
  · exact NumericEvents.nat_eq (F := F) _ _ pushesBound
      (by cases h : rule.output <;> simp [outputCount, h, NumericEvents.countBound]) (by grind)
  · apply NumericEvents.nat_eq (F := F) _ _ clearsBound
      (by cases rule.clears <;> simp [Bool.toNat, NumericEvents.countBound])
    cases h : rule.clears <;>
      simp [h, Bool.toNat, Semiring.natCast_zero, Semiring.natCast_one] at c ⊢ <;> grind

theorem no_control {F : Type} [Field F] (rule : Rule) (kind : Kind) (value : Fin 8)
    (index : Fin 4) (pops pushes clears : Nat) (gates : Gates (F := F) rule kind value index pops pushes clears) :
    kind ≠ .controlPush ∧ kind ≠ .controlPop := by
  have h := gates.noControl
  cases kind <;> simp [selected, flag] at h ⊢ <;>
    have bad : (1 : F) = 0 := by grind
  all_goals exact False.elim (Field.zero_ne_one bad.symm)

inductive Token where
  | pop (value : Nat)
  | push (value : Nat)
  | clear
  deriving DecidableEq

def Body (rule : Rule) (pops pushes clears : Nat) : List Token → Prop
  | [] => pops = rule.inputs.length ∧ pushes = outputCount rule ∧ clears = rule.clears.toNat
  | .pop value :: rest => pushes = 0 ∧ popAllowed rule pops value = true ∧ Body rule (pops+1) pushes clears rest
  | .push value :: rest => pushes = 0 ∧ pops = rule.inputs.length ∧ rule.output = some value ∧
      Body rule pops (pushes+1) clears rest
  | .clear :: rest => rule.clears = true ∧ clears = 0 ∧ Body rule pops pushes (clears+1) rest

theorem after_push_empty (rule : Rule) (tokens : List Token) (pops pushes clears : Nat)
    (noClear : rule.clears = false) (positive : 0 < pushes) (ok : Body rule pops pushes clears tokens) : tokens = [] := by
  cases tokens with
  | nil => rfl
  | cons token rest => cases token <;> simp [Body, noClear] at ok <;> omega

theorem body_shape (rule : Rule) (tokens : List Token) (pops : Nat)
    (noClear : rule.clears = false) (ok : Body rule pops 0 0 tokens) :
    ∃ inputs : List Nat, pops+inputs.length = rule.inputs.length ∧
      (∀ i (hi : i < inputs.length), popAllowed rule (pops+i) inputs[i] = true) ∧
      tokens = inputs.map Token.pop ++ rule.output.toList.map Token.push := by
  induction tokens generalizing pops with
  | nil =>
    have noOutput : rule.output = none := by cases h : rule.output <;> simp [Body, outputCount, h] at ok ⊢
    refine ⟨[], ?_, ?_, ?_⟩
    · simp [Body] at ok; simp; exact ok.1
    · simp
    · simp [noOutput]
  | cons token rest ih =>
    cases token with
    | pop value =>
      obtain ⟨inputs, count, typed, same⟩ := ih (pops+1) ok.2.2
      refine ⟨value :: inputs, ?_, ?_, ?_⟩
      · simp; omega
      · intro i hi
        cases i with
        | zero => simpa using ok.2.1
        | succ i => simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using typed i (by simpa using hi)
      · simp [same]
    | push value =>
      have empty := after_push_empty rule rest pops 1 0 noClear (by decide) ok.2.2.2
      refine ⟨[], ?_, ?_, ?_⟩
      · simp; exact ok.2.1
      · simp
      · simp [empty, ok.2.2.1]
    | clear => simp [Body, noClear] at ok

theorem body_complete (rule : Rule) (inputs : List Nat) (pops : Nat) (noClear : rule.clears = false)
    (count : pops+inputs.length = rule.inputs.length)
    (typed : ∀ i (hi : i < inputs.length), popAllowed rule (pops+i) inputs[i] = true) :
    Body rule pops 0 0 (inputs.map Token.pop ++ rule.output.toList.map Token.push) := by
  induction inputs generalizing pops with
  | nil => cases h : rule.output <;> simp [Body, outputCount, h, noClear] <;> simpa using count
  | cons value rest ih =>
    simp only [List.map_cons, List.cons_append, Body]
    refine ⟨trivial, ?_, ?_⟩
    · have h := typed 0 (by simp)
      change popAllowed rule (pops+0) value = true at h
      simpa only [Nat.add_zero] using h
    · apply ih (pops+1) (by simp at count; omega)
      intro i hi
      have h := typed (i+1) (by simpa using hi)
      change popAllowed rule (pops+(i+1)) rest[i] = true at h
      simpa only [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using h

theorem clear_body (rule : Rule) (tokens : List Token)
    (inputs : rule.inputs = []) (output : rule.output = none) (clear : rule.clears = true)
    (ok : Body rule 0 0 0 tokens) : tokens = [Token.clear] := by
  cases tokens with
  | nil => simp [Body, clear] at ok
  | cons token rest =>
    cases token with
    | pop value => simp [Body, popAllowed, inputs] at ok
    | push value => simp [Body, output] at ok
    | clear =>
      have tail := ok.2.2
      cases rest with
      | nil => rfl
      | cons token rest => cases token <;> simp [Body, popAllowed, inputs, output] at tail

theorem clear_complete (rule : Rule) (inputs : rule.inputs = [])
    (output : rule.output = none) (clear : rule.clears = true) : Body rule 0 0 0 [.clear] := by
  simp [Body, outputCount, inputs, output, clear]

#print axioms pop_sound
#print axioms push_sound
#print axioms clear_sound
#print axioms end_sound
#print axioms body_shape
#print axioms body_complete
#print axioms clear_body
#print axioms clear_complete

end ZkBuild.StaticEvents
