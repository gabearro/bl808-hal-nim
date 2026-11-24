import Init.Omega

/- Policy model for proof-gated WASM loading. The verifier and validator are
   parameters, not axioms asserting correctness of the Nim implementations.
   The existing runtime/JIT semantics remain separate refinement obligations. -/
namespace ZkBuild.ProvenAdmission

abbrev Bytes := List (Fin 256)

def admit {State Module : Type} (capacity : Nat) (pinned : Bool)
    (verify : Bytes → Bytes → Bool) (validate : Bytes → Bool)
    (instantiate : Bytes → State → Option Module × State)
    (source proof : Bytes) (state : State) : Option Module × State :=
  if pinned && decide (8 ≤ source.length ∧ source.length ≤ capacity ∧ proof.length = 192) then
    if verify source proof then
      if validate source then instantiate source state else (none,state)
    else (none,state)
  else (none,state)

theorem wrong_pin_unchanged {State Module : Type} (capacity : Nat)
    (verify : Bytes → Bytes → Bool) (validate : Bytes → Bool)
    (instantiate : Bytes → State → Option Module × State)
    (source proof : Bytes) (state : State) :
    admit capacity false verify validate instantiate source proof state = (none,state) := by
  simp [admit]

theorem rejected_proof_unchanged {State Module : Type} (capacity : Nat) (pinned : Bool)
    (verify : Bytes → Bytes → Bool) (validate : Bytes → Bool)
    (instantiate : Bytes → State → Option Module × State)
    (source proof : Bytes) (state : State) (rejected : verify source proof = false) :
    admit capacity pinned verify validate instantiate source proof state = (none,state) := by
  simp [admit,rejected]

theorem failed_validation_unchanged {State Module : Type} (capacity : Nat) (pinned : Bool)
    (verify : Bytes → Bytes → Bool) (validate : Bytes → Bool)
    (instantiate : Bytes → State → Option Module × State)
    (source proof : Bytes) (state : State) (rejected : validate source = false) :
    admit capacity pinned verify validate instantiate source proof state = (none,state) := by
  simp [admit,rejected]

theorem accepted_same_source {State Module : Type} (capacity : Nat) (pinned : Bool)
    (verify : Bytes → Bytes → Bool) (validate : Bytes → Bool)
    (instantiate : Bytes → State → Option Module × State)
    (source proof : Bytes) (state next : State) (module : Module)
    (accepted : admit capacity pinned verify validate instantiate source proof state = (some module,next)) :
    pinned = true ∧ 8 ≤ source.length ∧ source.length ≤ capacity ∧ proof.length = 192 ∧
      verify source proof = true ∧ validate source = true ∧
      instantiate source state = (some module,next) := by
  unfold admit at accepted
  split at accepted
  · rename_i bounds
    have boundValues : pinned = true ∧ (8 ≤ source.length ∧ source.length ≤ capacity ∧ proof.length = 192) := by
      simpa using bounds
    split at accepted
    · rename_i verified
      split at accepted
      · rename_i validated
        exact ⟨boundValues.1,boundValues.2.1,boundValues.2.2.1,boundValues.2.2.2,verified,validated,accepted⟩
      · cases accepted
    · cases accepted
  · cases accepted

#print axioms wrong_pin_unchanged
#print axioms rejected_proof_unchanged
#print axioms failed_validation_unchanged
#print axioms accepted_same_source

end ZkBuild.ProvenAdmission
