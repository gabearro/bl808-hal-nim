import CallSignatureBody
import CallBodyDecision
set_option autoImplicit false
namespace ZkBuild.CallRuntimeDecision
open CallEvents StaticEvents

def check (code : Nat) (params results current : List Nat) (tableTag : Nat) (tokens : List Token) : Bool :=
  CallMode.active code && decide (CallMode.indirect code = true → tableTag = 5) &&
    decide (CallMode.tail code = true → current = results) &&
    CallBodyDecision.check params results (CallMode.indirect code) false (CallMode.tail code) tokens

theorem correct (code : Nat) (params results current : List Nat) (tableTag : Nat) (tokens : List Token) :
    check code params results current tableTag tokens = true ↔
      CallMode.active code = true ∧ (CallMode.indirect code = true → tableTag = 5) ∧
      (CallMode.tail code = true → current = results) ∧
      CallBodyRun.Run params results (CallMode.indirect code) false (CallMode.tail code) tokens := by
  simp only [check,Bool.and_eq_true_iff,decide_eq_true_eq,CallBodyDecision.correct]
  exact and_assoc.trans and_assoc

theorem sound (code : Nat) (params results current : List Nat) (tableTag : Nat) (tokens : List Token)
    (accepted : check code params results current tableTag tokens = true) :
    CallSignatureBody.Typed code params results current tokens ∧
      callSignature code params.reverse results current tableTag =
        some ((if CallMode.indirect code then [0] else []) ++ params, if CallMode.tail code then [] else results) := by
  obtain ⟨active,table,root,run⟩ := (correct code params results current tableTag tokens).mp accepted
  obtain ⟨indexTokens,rest,shape,indexBody,body⟩ := CallBodyRun.refinement _ _ _ _ _ run
  constructor
  · rw [shape]
    exact CallSignatureBody.body code active params results current root indexTokens rest indexBody body
  · have cases := of_decide_eq_true active
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp_all [callSignature,CallMode.indirect,CallMode.tail]

#print axioms correct
#print axioms sound
end ZkBuild.CallRuntimeDecision
