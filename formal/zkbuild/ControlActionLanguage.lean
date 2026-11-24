import ControlActionGuards
set_option autoImplicit false
namespace ZkBuild.ControlActionLanguage
open OperandEvents ControlTypeState

/-- Label checks carry exception-clause obligations separately. The action
    projection retains every stack operation, frame change, and clear. -/
def token (kind : Kind) : List Kind :=
  match kind with
  | .pop | .push | .controlPush | .controlPop | .clear => [kind]
  | _ => []

def history (condition : Bool) (s : State) : List Kind :=
  List.replicate (condition.toNat-s.pending.toNat+s.args) .pop ++
    List.replicate s.closed .controlPop ++ List.replicate s.opened .controlPush ++
    List.replicate s.pushes .push ++ List.replicate s.cleared .clear

def Prefix (condition : Bool) (s : State) (actions : List Kind) : Prop :=
  (s.pending=true → condition=true ∧ s.args=0) ∧ actions=history condition s

theorem initial (condition : Bool) : Prefix condition {pending:=condition} [] := by
  cases condition <;> simp [Prefix,history]

theorem replicate_snoc (n : Nat) (kind : Kind) :
    List.replicate (n+1) kind=List.replicate n kind++[kind] := by
  induction n with
  | zero => rfl
  | succ n ih => simpa only [List.replicate_succ,List.cons_append] using congrArg (List.cons kind) ih

theorem step (condition : Bool) (s : State) (actions : List Kind) (kind : Kind) (code : Nat)
    (active : ControlTypeModes.supported code=true) (allowed : ControlActionGuards.Allowed kind code)
    (prior : Prefix condition s actions) (guards : ControlActionGuards.Spec s kind code) :
    Prefix condition (advance s kind code) (actions++token kind) := by
  obtain ⟨pending,historyEq⟩ := prior
  rcases allowed with rfl | rfl | rfl | rfl | rfl | ⟨rfl,_⟩
  · have g := guards.pop rfl
    cases p : s.pending
    · simp only [Prefix,advance,ControlTypeMasks.selected,active,p,reduceCtorEq,decide_true,decide_false,
        Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_false,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
      refine ⟨by intro h; contradiction,?_⟩
      rw [historyEq]
      simp only [history,p,g.1,g.2.1,g.2.2.1,g.2.2.2,token,Bool.toNat_false,Nat.sub_zero,
        List.replicate_zero,List.append_nil]
      rw [← Nat.add_assoc,replicate_snoc]
    · have cp := pending p
      simp only [Prefix,advance,ControlTypeMasks.selected,active,p,reduceCtorEq,decide_true,decide_false,
        Bool.true_and,Bool.false_and,Bool.not_true,Bool.and_false,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
      refine ⟨by intro h; contradiction,?_⟩
      rw [historyEq]
      simp [history,p,cp.1,cp.2,g.1,g.2.1,g.2.2.1,g.2.2.2,token]
  · have g := guards.push rfl
    simp only [Prefix,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
    refine ⟨by intro h; contradiction,?_⟩
    rw [historyEq]
    simp only [history,g.1,g.2,token,Bool.toNat_false,Nat.sub_zero,List.replicate_zero,List.append_nil,
      replicate_snoc,List.append_assoc]
  · have g := guards.opening rfl
    simp only [Prefix,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
    refine ⟨by intro h; contradiction,?_⟩
    rw [historyEq]
    simp only [history,g.1,g.2.1,g.2.2.1,token,Bool.toNat_false,Nat.sub_zero,List.replicate_zero,List.append_nil,
      replicate_snoc,List.append_assoc]
  · have g := guards.closing rfl
    simp only [Prefix,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
    refine ⟨by intro h; contradiction,?_⟩
    rw [historyEq]
    simp only [history,g.1,g.2.1,g.2.2.1,g.2.2.2.1,token,Bool.toNat_false,Nat.sub_zero,List.replicate_zero,List.append_nil,
      replicate_snoc,List.append_assoc]
  · have g := guards.clear rfl
    simp only [Prefix,advance,ControlTypeMasks.selected,active,g.1,reduceCtorEq,decide_true,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero]
    refine ⟨by intro h; contradiction,?_⟩
    rw [historyEq]
    simp only [history,g.1,token,Bool.toNat_false,Nat.sub_zero,replicate_snoc,List.append_assoc]
  · simpa only [Prefix,advance,ControlTypeMasks.selected,active,reduceCtorEq,decide_false,
      Bool.true_and,Bool.false_and,Bool.not_false,Bool.and_true,Bool.toNat_false,Nat.add_zero,token,List.append_nil]
      using And.intro pending historyEq

#print axioms initial
#print axioms replicate_snoc
#print axioms step
end ZkBuild.ControlActionLanguage
