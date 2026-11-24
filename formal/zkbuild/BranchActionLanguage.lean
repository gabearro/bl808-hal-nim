import BranchTypeSemanticSound
set_option autoImplicit false
namespace ZkBuild.BranchActionLanguage
open OperandEvents BranchTypeState

def block (arity : Nat) : List Kind :=
  [.labelCheck]++List.replicate arity .pop++List.replicate arity .push
def blocks (arity : Nat) : Nat → List Kind
  | 0 => []
  | n+1 => blocks arity n++block arity
def plan (arity previous : Nat) : List Kind :=
  [.pop]++blocks arity previous++[.labelCheck]++List.replicate arity .pop++[.clear]

/-- Completed nondefault groups followed by the current label's partial work.
    No bound on partial counts is assumed; completion guards close them. -/
def Prefix (s : State) (pending : Bool) (actions : List Kind) : Prop :=
  if s.seen then
    pending=false ∧ s.length=s.arity ∧ ∃ previous,
      actions=[.pop]++blocks s.arity previous++[.labelCheck]++
        List.replicate s.pops .pop++List.replicate s.pushes .push++List.replicate s.cleared .clear
  else s.length=0 ∧ s.arity=0 ∧ s.pops=0 ∧ s.pushes=0 ∧ s.cleared=0 ∧
    actions=(if pending then [] else [.pop])

theorem initial : Prefix {} true [] := by simp [Prefix]

theorem replicate_snoc (n : Nat) (kind : Kind) :
    List.replicate (n+1) kind=List.replicate n kind++[kind] := by
  induction n with
  | zero => rfl
  | succ n ih => simpa only [List.replicate_succ,List.cons_append] using congrArg (List.cons kind) ih

theorem step (s : State) (pending : Bool) (actions : List Kind)
    (kind : Kind) (index : Nat) (d : BranchTypeData.Data)
    (allowed : kind=.pop ∨ kind=.push ∨ kind=.labelCheck ∨ kind=.clear)
    (prior : Prefix s pending actions)
    (guards : BranchTypeGuards.Spec kind 14 index d.size.val pending
      (BranchTypePending.advance kind 14 pending) s (select s kind 14 index d)
      (advance (select s kind 14 index d) kind 14 pending)) :
    Prefix (advance (select s kind 14 index d) kind 14 pending)
      (BranchTypePending.advance kind 14 pending) (actions++[kind]) := by
  rcases allowed with rfl | rfl | rfl | rfl
  · cases p : pending
    · have g := guards.pop (by simp [BranchTypeGuards.argument,BranchTypePending.selected,p])
      have seen : s.seen=true := by simpa [select,mark] using g.1
      have pushes : s.pushes=0 := by simpa [select,mark] using g.2.2.1
      have cleared : s.cleared=0 := by simpa [select,mark] using g.2.2.2.1
      simp only [Prefix,seen,ite_true] at prior
      obtain ⟨_,length,n,history⟩ := prior
      simp only [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,p,
        reduceCtorEq,and_true,and_false,decide_false,decide_true,ite_false,ite_true,
        Bool.not_false,Bool.true_and,Bool.false_and,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,seen]
      refine ⟨True.intro,length,n,?_⟩
      rw [history,pushes,cleared]
      simp only [List.replicate_zero,List.append_nil,replicate_snoc,List.append_assoc,List.nil_append]
    · have noSeen : s.seen=false := by
        cases h : s.seen
        · rfl
        · simp only [Prefix,h,ite_true,p] at prior
          have := prior.1
          contradiction
      simp only [Prefix,noSeen,Bool.false_eq_true,ite_false,p,ite_true] at prior
      obtain ⟨length,arity,pops,pushes,cleared,history⟩ := prior
      simp [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,
        p,noSeen,length,arity,pops,pushes,cleared,history]
  · have g := guards.push (by simp [BranchTypePending.selected])
    have seen : s.seen=true := by simpa [select,mark] using g.1
    have p : pending=false := g.2.1
    have cleared : s.cleared=0 := by simpa [select,mark] using g.2.2.2.1
    simp only [Prefix,seen,ite_true] at prior
    obtain ⟨_,length,n,history⟩ := prior
    simp only [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,p,
      reduceCtorEq,and_true,and_false,decide_false,decide_true,ite_false,ite_true,
      Bool.not_false,Bool.true_and,Bool.false_and,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,seen]
    refine ⟨True.intro,length,n,?_⟩
    rw [history,cleared]
    simp only [List.replicate_zero,List.append_nil,replicate_snoc,List.append_assoc,List.nil_append]
  · have g := guards.label (by simp [mark])
    have p : pending=false := g.1
    have cleared : s.cleared=0 := g.2.2
    cases seen : s.seen
    · simp only [Prefix,seen,Bool.false_eq_true,ite_false,p] at prior
      obtain ⟨length,arity,pops,pushes,_,history⟩ := prior
      simp [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,
        p,seen,cleared,history,blocks]
      exact ⟨0,rfl⟩
    · have repeated := guards.repeated (by simp [mark]) seen
      simp only [Prefix,seen,ite_true] at prior
      obtain ⟨_,length,n,history⟩ := prior
      simp only [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,p,
        reduceCtorEq,and_true,and_false,decide_false,decide_true,ite_false,ite_true,
        Bool.not_false,Bool.true_and,Bool.false_and,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,seen]
      refine ⟨True.intro,repeated.2.2,n+1,?_⟩
      rw [history,cleared,repeated.1,repeated.2.1,length]
      simp only [List.replicate_zero,List.append_nil,blocks,block,List.append_assoc]
  · have g := guards.clear (by simp [BranchTypePending.selected])
    have seen : s.seen=true := by simpa [select,mark] using g.1
    have p : pending=false := g.2.2.1
    have cleared : s.cleared=0 := by simpa [select,mark] using g.2.2.2.2.1
    simp only [Prefix,seen,ite_true] at prior
    obtain ⟨_,length,n,history⟩ := prior
    simp only [Prefix,select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,p,
      reduceCtorEq,and_true,and_false,decide_false,decide_true,ite_false,ite_true,
      Bool.not_false,Bool.true_and,Bool.false_and,Bool.false_eq_true,Bool.toNat_true,Bool.toNat_false,Nat.add_zero,seen]
    refine ⟨True.intro,length,n,?_⟩
    rw [history,cleared]
    simp only [List.replicate_zero,List.append_nil,replicate_snoc,List.append_assoc,List.nil_append]

theorem finish (s : State) (pending : Bool) (actions : List Kind)
    (index : Nat) (d : BranchTypeData.Data) (prior : Prefix s pending actions)
    (guards : BranchTypeGuards.Spec .instructionEnd 14 index d.size.val pending
      (BranchTypePending.advance .instructionEnd 14 pending) s (select s .instructionEnd 14 index d)
      (advance (select s .instructionEnd 14 index d) .instructionEnd 14 pending)) :
    ∃ previous, actions=plan s.arity previous := by
  have g := guards.finish (by simp [BranchTypePending.selected])
  simp only [select,mark,BranchTypePending.selected,advance,BranchTypePending.advance,
    reduceCtorEq,and_false,and_true,decide_false,decide_true,ite_false,Bool.not_false,Bool.and_false,
    Bool.false_and,Bool.toNat_false,Nat.add_zero] at g
  simp only [Prefix,g.1,ite_true] at prior
  obtain ⟨_,length,n,history⟩ := prior
  refine ⟨n,?_⟩
  rw [history,g.2.2.2.1,g.2.2.2.2.1,g.2.2.2.2.2,length]
  simp only [plan,List.replicate_zero,List.append_nil,List.replicate_succ]

#print axioms step
#print axioms finish
end ZkBuild.BranchActionLanguage
