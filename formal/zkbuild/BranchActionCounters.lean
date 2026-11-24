import BranchTypeRestoration
set_option autoImplicit false
namespace ZkBuild.BranchActionCounters
open OperandEvents BranchTypeState

def add (s : State) (kind : Kind) (count : Nat) : State :=
  {s with pops:=s.pops+(if kind=.pop then count else 0), pushes:=s.pushes+(if kind=.push then count else 0)}

theorem run (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (start count : Nat) (kind : Kind) (allowed : kind=.pop ∨ kind=.push)
    (ready : BranchTypePending.state rows ops start=false)
    (kinds : ∀ k, k<count → (rows.getD (start+k) default).kind=kind)
    (codes : ∀ k, k<count → ops.getD (start+k) 0=14) :
    BranchTypePending.state rows ops (start+count)=false ∧
      BranchTypeTrace.state rows ops data (start+count)=add (BranchTypeTrace.state rows ops data start) kind count := by
  induction count with
  | zero =>
    refine ⟨by simpa only [Nat.add_zero] using ready,?_⟩
    rcases allowed with rfl | rfl <;> simp [add]
  | succ count ih =>
    have prior := ih (by intro k kb; exact kinds k (by omega)) (by intro k kb; exact codes k (by omega))
    have kindEq := kinds count (by omega)
    have code := codes count (by omega)
    rw [show start+(count+1)=start+count+1 from by omega]
    constructor
    · change BranchTypePending.advance _ _ (BranchTypePending.prepare _ _ _)=false
      rw [kindEq,code]
      rcases allowed with rfl | rfl <;>
        simp only [BranchTypePending.prepare,BranchTypePending.reset,BranchTypePending.advance,
          reduceCtorEq,or_self,decide_false,Bool.false_eq_true,ite_false,prior.1,Bool.false_and]
    · change advance (select (prepare _ _) _ _ _ _) _ _ (BranchTypePending.prepare _ _ _)=_
      rw [kindEq,code]
      rcases allowed with rfl | rfl
      all_goals
        simp only [prepare,select,mark,BranchTypePending.prepare,BranchTypePending.reset,
          reduceCtorEq,false_and,or_self,decide_false,Bool.false_eq_true,ite_false,prior.1,prior.2]
        simp [add,advance,BranchTypePending.selected,Nat.add_assoc]

theorem label (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) (j : Nat) (jb : j<rows.length)
    (kind : (rows.getD j default).kind=.labelCheck) (code : ops.getD j 0=14) :
    BranchTypePending.state rows ops (j+1)=false ∧
      (BranchTypeTrace.state rows ops data (j+1)).pops=0 ∧
      (BranchTypeTrace.state rows ops data (j+1)).pushes=0 ∧
      (BranchTypeTrace.state rows ops data (j+1)).length=(data j).size.val ∧
      (BranchTypeTrace.state rows ops data (j+1)).start=j+1 := by
  have ready := (guards j jb).label (by simp only [mark,kind,code,and_self,decide_true])
  have pending : BranchTypePending.state rows ops j=false := by
    simpa only [BranchTypePending.prepare,BranchTypePending.reset,kind,reduceCtorEq,or_self,decide_false,Bool.false_eq_true,ite_false] using ready.1
  simp only [BranchTypePending.state,BranchTypeTrace.state,kind,code]
  simp [prepare,select,advance,mark,BranchTypePending.prepare,BranchTypePending.reset,
    BranchTypePending.advance,BranchTypePending.selected,pending]

/-- Every restoration row reads the mirror-position pop from the same group. -/
theorem restored (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) (restores : BranchTypeRestoration.Trace rows ops data)
    (j arity : Nat) (bound : j+1+2*arity≤rows.length)
    (kind : (rows.getD j default).kind=.labelCheck) (code : ops.getD j 0=14)
    (size : (data j).size.val=arity)
    (pops : ∀ k, k<arity → (rows.getD (j+1+k) default).kind=.pop)
    (pushes : ∀ k, k<arity → (rows.getD (j+1+arity+k) default).kind=.push)
    (codes : ∀ k, k<2*arity → ops.getD (j+1+k) 0=14)
    (ordinal : Nat) (inside : ordinal<arity) :
    (rows.getD (j+1+arity+ordinal) default).valueType=(rows.getD (j+1+(arity-1-ordinal)) default).valueType := by
  have initial := label rows ops data guards j (by omega) kind code
  have popped := run rows ops data (j+1) arity .pop (Or.inl rfl) initial.1 pops (by intro k kb; exact codes k (by omega))
  have pushed := run rows ops data (j+1+arity) ordinal .push (Or.inr rfl) popped.1
    (by intro k kb; exact pushes k (by omega))
    (by intro k kb; simpa only [Nat.add_assoc] using codes (arity+k) (by omega))
  have codeAt : ops.getD (j+1+arity+ordinal) 0=14 := by
    simpa only [Nat.add_assoc] using codes (arity+ordinal) (by omega)
  have pick := restores (j+1+arity+ordinal) (by omega)
    (by simp only [BranchTypePending.selected,pushes ordinal inside,codeAt,and_self,decide_true])
  have current : BranchTypeTrace.chosen rows ops data (j+1+arity+ordinal)=BranchTypeTrace.state rows ops data (j+1+arity+ordinal) := by
    simp only [BranchTypeTrace.chosen,BranchTypeTrace.ready,prepare,select,mark,BranchTypePending.reset,
      pushes ordinal inside,codeAt,reduceCtorEq,false_and,or_self,decide_false,Bool.false_eq_true,ite_false]
  obtain ⟨_,source,_,sourceIndex,_,_,same⟩ := pick
  rw [current,pushed.2,popped.2] at sourceIndex
  simp only [add,reduceCtorEq,ite_false,ite_true,Nat.add_zero,initial.2.2.1,initial.2.2.2.1,
    initial.2.2.2.2,size,Nat.zero_add] at sourceIndex
  simpa only [sourceIndex] using same

#print axioms run
#print axioms label
#print axioms restored
end ZkBuild.BranchActionCounters
