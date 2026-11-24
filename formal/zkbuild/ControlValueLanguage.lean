import ControlActionLanguage
set_option autoImplicit false
namespace ZkBuild.ControlValueLanguage
open OperandEvents ControlTypeState ControlPlans

def token (kind : Kind) (actual : Nat) : List Action :=
  match kind with
  | .pop => [.pop actual]
  | .push => [.push actual]
  | .controlPush => [.openFrame]
  | .controlPop => [.closeFrame]
  | .clear => [.clear]
  | _ => []
def expected (inputs outputs : List Nat) (s : State) (kind : Kind) : List Action :=
  token kind (if kind=.pop then if s.pending then 0 else inputs.getD s.args 0 else outputs.getD s.pushes 0)
def history (condition : Bool) (inputs outputs : List Nat) (s : State) : List Action :=
  List.replicate (condition.toNat-s.pending.toNat) (.pop 0) ++ (inputs.take s.args).map Action.pop ++
    List.replicate s.closed .closeFrame ++ List.replicate s.opened .openFrame ++
    (outputs.take s.pushes).map Action.push ++ List.replicate s.cleared .clear

structure Types (inputs outputs : List Nat) (s : State) (kind : Kind) (actual : Nat) : Prop where
  pop : kind=.pop → if s.pending then CallEvents.InputOk 0 actual else
    s.args<inputs.length ∧ CallEvents.InputOk (inputs.getD s.args 0) actual
  push : kind=.push → s.pushes<outputs.length ∧ actual=outputs.getD s.pushes 0

theorem append {e a f b : List Action} (left : Matches e a) (right : Matches f b) : Matches (e++f) (a++b) := by
  induction left with
  | nil => exact right
  | pop typed prior ih => exact .pop typed ih
  | push prior ih => exact .push ih
  | openFrame prior ih => exact .openFrame ih
  | closeFrame prior ih => exact .closeFrame ih
  | clear prior ih => exact .clear ih

theorem take_snoc (tags : List Nat) (i : Nat) (bound : i<tags.length) :
    tags.take (i+1)=tags.take i++[tags.getD i 0] := by
  simpa only [List.getD,List.getElem?_eq_getElem bound,Option.getD_some] using List.take_succ_eq_append_getElem bound

theorem replicate_snoc (n : Nat) (a : Action) : List.replicate (n+1) a=List.replicate n a++[a] := by
  induction n with
  | zero => rfl
  | succ n ih => simpa only [List.replicate_succ,List.cons_append] using congrArg (List.cons a) ih

theorem next_history (condition : Bool) (inputs outputs : List Nat) (s : State) (kind : Kind) (code actual : Nat)
    (active : ControlTypeModes.supported code=true) (allowed : ControlActionGuards.Allowed kind code)
    (pending : s.pending=true → condition=true ∧ s.args=0)
    (guards : ControlActionGuards.Spec s kind code) (types : Types inputs outputs s kind actual) :
    history condition inputs outputs (advance s kind code)=history condition inputs outputs s++expected inputs outputs s kind := by
  rcases allowed with rfl | rfl | rfl | rfl | rfl | ⟨rfl,_⟩
  · have g := guards.pop rfl
    cases p : s.pending
    · have t := types.pop rfl
      simp only [p,Bool.false_eq_true,ite_false] at t
      simp only [history,advance,ControlTypeMasks.selected,active,p,reduceCtorEq,decide_true,decide_false,
        Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_false,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,Nat.sub_zero,
        g.1,g.2.1,g.2.2.1,g.2.2.2,List.replicate_zero,List.take_zero,List.map_nil,List.append_nil,
        take_snoc inputs s.args t.1,List.map_append,List.map_cons,List.map_nil,expected,token,ite_true,ite_false,List.append_assoc]
    · have cp := pending p
      simp [history,advance,ControlTypeMasks.selected,active,p,cp.1,cp.2,g.1,g.2.1,g.2.2.1,g.2.2.2,expected,token]
  · have g := guards.push rfl
    have t := types.push rfl
    simp only [history,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,Nat.sub_zero,
      g.2,List.replicate_zero,List.append_nil,take_snoc outputs s.pushes t.1,List.map_append,List.map_cons,List.map_nil,
      expected,token,ite_false,List.append_assoc]
  · have g := guards.opening rfl
    simp only [history,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,Nat.sub_zero,
      g.2.1,g.2.2.1,List.replicate_zero,List.take_zero,List.map_nil,List.append_nil,replicate_snoc,expected,token,List.append_assoc]
  · have g := guards.closing rfl
    simp only [history,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,Nat.sub_zero,
      g.2.1,g.2.2.1,g.2.2.2.1,List.replicate_zero,List.take_zero,List.map_nil,List.append_nil,replicate_snoc,expected,token,List.append_assoc]
  · have g := guards.clear rfl
    simp only [history,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,Nat.sub_zero,
      replicate_snoc,expected,token,List.append_assoc]
  · simp only [history,advance,ControlTypeMasks.selected,active,reduceCtorEq,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_false,Nat.add_zero,expected,token,List.append_nil]

theorem typed_token (inputs outputs : List Nat) (s : State) (kind : Kind) (actual : Nat)
    (types : Types inputs outputs s kind actual) : Matches (expected inputs outputs s kind) (token kind actual) := by
  cases kind <;> try exact .nil
  case pop =>
    have t := types.pop rfl
    cases p : s.pending
    · simp only [p,Bool.false_eq_true,ite_false] at t
      simpa only [expected,token,p,reduceCtorEq,Bool.false_eq_true,ite_false,ite_true] using Matches.pop t.2 Matches.nil
    · simp only [p,ite_true] at t
      simpa only [expected,token,p,reduceCtorEq,ite_true] using Matches.pop t Matches.nil
  case push =>
    have t := (types.push rfl).2
    simp only [expected,token,reduceCtorEq,ite_false,t]
    exact .push .nil
  case controlPush => exact .openFrame .nil
  case controlPop => exact .closeFrame .nil
  case clear => exact .clear .nil

theorem step (condition : Bool) (inputs outputs : List Nat) (s : State) (kind : Kind) (code actual : Nat) (actions : List Action)
    (active : ControlTypeModes.supported code=true) (allowed : ControlActionGuards.Allowed kind code)
    (pending : s.pending=true → condition=true ∧ s.args=0)
    (guards : ControlActionGuards.Spec s kind code) (types : Types inputs outputs s kind actual)
    (prior : Matches (history condition inputs outputs s) actions) :
    Matches (history condition inputs outputs (advance s kind code)) (actions++token kind actual) := by
  rw [next_history condition inputs outputs s kind code actual active allowed pending guards types]
  exact append prior (typed_token inputs outputs s kind actual types)

#print axioms append
#print axioms take_snoc
#print axioms replicate_snoc
#print axioms next_history
#print axioms typed_token
#print axioms step
end ZkBuild.ControlValueLanguage
