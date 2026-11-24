import ParametricGuardCounts
import ParametricGuardTypes
set_option autoImplicit false
namespace ZkBuild.ParametricBodyRun
open OperandEvents StaticEvents ParametricState

def popState (s : State) (actual : Fin 8) : State :=
  {s with pops := s.pops+1
          first := if s.pops = 1 then actual else s.first
          second := if s.pops = 2 then actual else s.second}
def pushState (s : State) : State := {s with pushes := s.pushes+1}
def initial (primary : Nat) : State := {declared := (ParametricEvents.typeForCode primary).getD 0}
def action : Token → ControlPlans.Action
  | .pop v => .pop v
  | .push v => .push v
  | .clear => .clear

inductive Run (code : Nat) : State → List Token → Prop where
  | done {s : State} : s.pops = ParametricGuardCounts.arity code → s.pushes = 1 → Run code s []
  | pop {s : State} {actual : Fin 8} {rest : List Token} :
      ParametricGuardCounts.Spec s .pop code actual → ParametricGuardTypes.Spec s .pop code actual →
      Run code (popState s actual) rest → Run code s (.pop actual.val :: rest)
  | push {s : State} {actual : Fin 8} {rest : List Token} :
      ParametricGuardCounts.Spec s .push code actual → ParametricGuardTypes.Spec s .push code actual →
      Run code (pushState s) rest → Run code s (.push actual.val :: rest)

theorem advance_pop (s : State) (code : Nat) (actual : Fin 8) (active : ParametricMode.active code = true) :
    advance s .pop code actual = popState s actual := by simp [advance,popState,popping,pushing,firstPop,secondPop,active]
theorem advance_push (s : State) (code : Nat) (actual : Fin 8) (active : ParametricMode.active code = true) :
    advance s .push code actual = pushState s := by simp [advance,pushState,popping,pushing,firstPop,secondPop,active]

theorem pushed_empty (code : Nat) (active : ParametricMode.active code = true) (s : State) (tokens : List Token)
    (run : Run code s tokens) (pushed : s.pushes ≠ 0) : tokens = [] := by
  cases run with
  | done _ _ => rfl
  | pop counts _ _ => have h := (counts.pop (by simp [popping,active])).2.2; contradiction
  | push counts _ _ => have h := (counts.push (by simp [pushing,active])).2; contradiction

theorem pop_next (code : Nat) (active : ParametricMode.active code = true) (selecting : ParametricMode.selecting code = true)
    (s : State) (tokens : List Token) (run : Run code s tokens) (short : s.pops < 3) :
    ∃ actual : Fin 8, ∃ rest, tokens = .pop actual.val :: rest ∧
      ParametricGuardCounts.Spec s .pop code actual ∧ ParametricGuardTypes.Spec s .pop code actual ∧ Run code (popState s actual) rest := by
  cases run with
  | done count _ => simp [ParametricGuardCounts.arity,selecting] at count; omega
  | @pop _ actual rest counts types next => exact ⟨actual,rest,rfl,counts,types,next⟩
  | push counts _ _ => have h := (counts.push (by simp [pushing,active])).1; simp [ParametricGuardCounts.arity,selecting] at h; omega

theorem push_only (code : Nat) (active : ParametricMode.active code = true)
    (s : State) (tokens : List Token) (run : Run code s tokens) (full : s.pops = ParametricGuardCounts.arity code) (empty : s.pushes = 0) :
    ∃ actual : Fin 8, tokens = [.push actual.val] ∧ actual.val = ParametricGuardTypes.output s code := by
  cases run with
  | done _ count => omega
  | pop counts _ _ =>
    have h := counts.pop (by simp [popping,active])
    simp [ParametricGuardCounts.arity,h.1] at full
    omega
  | @push _ actual rest counts types next =>
    have restEmpty := pushed_empty code active (pushState s) rest next (by simp [pushState,empty])
    exact ⟨actual,by rw [restEmpty],types.push (by simp [pushing,active])⟩

theorem checked (code primary : Nat) (active : ParametricMode.active code = true)
    (valid : ParametricBegin.Valid code primary) (tokens : List Token) (run : Run code (initial primary) tokens) :
    ParametricEvents.check code primary (tokens.map action) = true := by
  have codes : code = 27 ∨ code = 28 ∨ code = 208 := of_decide_eq_true active
  rcases codes with code | code | code
  any_goals (subst code)
  case inr.inr =>
    obtain ⟨tag,found⟩ := valid.2.2 rfl
    obtain ⟨actual,shape,result⟩ := push_only 208 (by decide) _ tokens run (by simp [initial,ParametricGuardCounts.arity,ParametricMode.selecting]) rfl
    obtain ⟨rfl,rfl⟩ | ⟨rfl,rfl⟩ := ParametricEvents.reference_bound primary tag found
    all_goals simp [shape,action,ParametricEvents.check,ParametricEvents.referenceForCode,ParametricEvents.typeForCode,initial,ParametricGuardTypes.output] at result ⊢; exact result.symm
  all_goals
    obtain ⟨condition,ts0,shape0,conditionCounts,_,walk0⟩ := pop_next _ active (by decide) _ tokens run (by simp [initial])
    obtain ⟨first,ts1,shape1,_,firstTypes,walk1⟩ := pop_next _ active (by decide) _ ts0 walk0 (by simp [popState,initial])
    obtain ⟨second,ts2,shape2,_,secondTypes,walk2⟩ := pop_next _ active (by decide) _ ts1 walk1 (by simp [popState,initial])
    obtain ⟨result,shape3,resultType⟩ := push_only _ active _ ts2 walk2 (by simp [popState,initial,ParametricGuardCounts.arity,ParametricMode.selecting]) rfl
    have conditionType := conditionCounts.condition (by simp [popping,active]) rfl
    rw [shape0,shape1,shape2,shape3]
  case inl =>
    have p := firstTypes.inferred (by simp [popping,active]) (by simp [popState,initial]) rfl
    have q := secondTypes.inferred (by simp [popping,active]) (by simp [popState,initial]) rfl
    have inferred : ParametricEvents.Inferred first.val second.val result.val := by
      refine ⟨first.isLt,second.isLt,p.1,p.2.1,q.1,q.2.1,?_,?_⟩
      · simpa [popState,initial] using q.2.2 (by simp [popState,initial])
      · simpa [ParametricGuardTypes.output,popState,initial] using resultType
    have checked := ParametricEvents.infer_complete first.val second.val result.val inferred
    simp only [List.map_cons,List.map_nil,action,ParametricEvents.check,decide_eq_true_eq]
    exact ⟨valid.1 rfl,conditionType,checked⟩
  case inr.inl =>
    obtain ⟨tag,found⟩ := valid.2.1 rfl
    have p := firstTypes.typed (by simp [popping,active]) (by simp [popState,initial]) rfl
    have q := secondTypes.typed (by simp [popping,active]) (by simp [popState,initial]) rfl
    simp only [popState,initial,found,Option.getD_some] at p q
    have resultEq : result.val = tag := by simpa [ParametricGuardTypes.output,popState,initial,found] using resultType
    simp only [List.map_cons,List.map_nil,action,ParametricEvents.check,found,decide_eq_true_eq]
    exact ⟨conditionType,p,q,resultEq⟩

#print axioms checked
end ZkBuild.ParametricBodyRun
