import ParametricEvents
set_option autoImplicit false
namespace ZkBuild.ParametricBodySpec
open ControlPlans

/-- Declarative operand-stack effects, including WASM's unknown stack type. -/
inductive Typed : Nat → Nat → List Action → Prop where
  | untyped (condition first second result : Nat) :
      CallEvents.InputOk 0 condition → ParametricEvents.Inferred first second result →
      Typed 27 0 [.pop condition,.pop first,.pop second,.push result]
  | typed (immediate tag condition first second result : Nat) :
      ParametricEvents.typeForCode immediate = some tag → CallEvents.InputOk 0 condition →
      CallEvents.InputOk tag first → CallEvents.InputOk tag second → result = tag →
      Typed 28 immediate [.pop condition,.pop first,.pop second,.push result]
  | reference (immediate result : Nat) : ParametricEvents.referenceForCode immediate = some result →
      Typed 208 immediate [.push result]

theorem sound (code immediate : Nat) (actions : List Action)
    (accepted : ParametricEvents.check code immediate actions = true) : Typed code immediate actions := by
  unfold ParametricEvents.check at accepted
  split at accepted
  · rename_i condition first second result
    simp only [decide_eq_true_eq] at accepted
    rcases accepted with ⟨rfl,conditionOk,found⟩
    exact Typed.untyped condition first second result conditionOk (ParametricEvents.infer_sound first second result found)
  · rename_i condition first second result
    split at accepted
    · contradiction
    · rename_i tag found
      simp only [decide_eq_true_eq] at accepted
      exact Typed.typed immediate tag condition first second result found accepted.1 accepted.2.1 accepted.2.2.1 accepted.2.2.2
  · rename_i result
    exact Typed.reference immediate result (of_decide_eq_true accepted)
  · contradiction

theorem complete (code immediate : Nat) (actions : List Action) (typed : Typed code immediate actions) :
    ParametricEvents.check code immediate actions = true := by
  cases typed with
  | untyped condition first second result conditionOk inferred =>
    simp only [ParametricEvents.check,decide_eq_true_eq]
    exact ⟨True.intro,conditionOk,ParametricEvents.infer_complete first second result inferred⟩
  | typed immediate tag condition first second result found conditionOk firstOk secondOk resultOk =>
    simp only [ParametricEvents.check,found,decide_eq_true_eq]
    exact ⟨conditionOk,firstOk,secondOk,resultOk⟩
  | reference immediate result found => simp only [ParametricEvents.check,found,decide_true]

theorem correct (code immediate : Nat) (actions : List Action) :
    ParametricEvents.check code immediate actions = true ↔ Typed code immediate actions :=
  ⟨sound code immediate actions,complete code immediate actions⟩

#print axioms sound
#print axioms complete
#print axioms correct
end ZkBuild.ParametricBodySpec
