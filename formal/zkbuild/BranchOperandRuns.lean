import OperandStackCertificate
set_option autoImplicit false
namespace ZkBuild.BranchOperandRuns
open OperandEvents OperandStackRefinement OperandStackTrace

def values (rows : List Row) (start : Nat) : Nat → List (Fin 8)
  | 0 => []
  | count+1 => (rows.getD start default).valueType :: values rows (start+1) count

@[simp] theorem length (rows : List Row) (start count : Nat) : (values rows start count).length=count := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih => simp only [values,List.length_cons,ih]

theorem point (rows : List Row) (start count i : Nat) (inside : i<count) :
    (values rows start count).getD i 0=(rows.getD (start+i) default).valueType := by
  induction count generalizing start i with
  | zero => omega
  | succ count ih =>
    cases i with
    | zero => simp only [values,List.getD_cons_zero,Nat.add_zero]
    | succ i => simpa only [values,List.getD_cons_succ,Nat.add_assoc,Nat.add_comm 1 i] using ih (start+1) i (by omega)

theorem pushes (rows : List Row) (start count : Nat)
    (kinds : ∀ i, i<count → (rows.getD (start+i) default).kind=.push) :
    stack rows (start+count)=stack rows start++values rows start count := by
  induction count generalizing start with
  | zero => simp only [Nat.add_zero,values,List.append_nil]
  | succ count ih =>
    have tail := ih (start+1) (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using kinds (i+1) (by omega))
    rw [show start+(count+1)=start+1+count from by omega,tail]
    have kind : (rows.getD start default).kind=.push := by simpa only [Nat.add_zero] using kinds 0 (by omega)
    simp only [stack,next,kind,values,List.append_assoc,List.singleton_append]

theorem floor_after (rows : List Row) (i : Nat) (pop : (rows.getD i default).kind=.pop)
    (valid : PopSpec (stack rows i) (rows.getD i default)) :
    (rows.getD i default).floor≤(stack rows (i+1)).length := by
  have h := valid pop
  cases poly : (rows.getD i default).polymorphic
  · simp only [poly,Bool.false_eq_true,ite_false] at h
    obtain ⟨rest,equal,bound⟩ := h
    simpa only [stack,next,pop,poly,Bool.false_eq_true,ite_false,equal,List.length_append,
      List.length_singleton,Nat.add_sub_cancel,List.take_left] using bound
  · simp only [poly,ite_true] at h
    simpa only [stack,next,pop,poly,ite_true] using Nat.le_of_eq h.1.symm

/-- Once actual values have been restored above the current floor, subsequent
    pops read those exact values, even if the original values were unknown. -/
theorem restored (rows : List Row) (start : Nat) (tail actual : List (Fin 8))
    (initial : stack rows start=tail++actual.reverse)
    (kinds : ∀ i, i<actual.length → (rows.getD (start+i) default).kind=.pop)
    (valid : ∀ i, i<actual.length → PopSpec (stack rows (start+i)) (rows.getD (start+i) default))
    (floors : ∀ i, i<actual.length → (rows.getD (start+i) default).floor≤tail.length) :
    values rows start actual.length=actual ∧ stack rows (start+actual.length)=tail := by
  induction actual generalizing start with
  | nil => exact ⟨rfl,by simpa only [List.length_nil,List.reverse_nil,List.append_nil,Nat.add_zero] using initial⟩
  | cons tag actual ih =>
    have kind : (rows.getD start default).kind=.pop := by simpa only [Nat.add_zero] using kinds 0 (by simp)
    have spec : PopSpec (stack rows start) (rows.getD start default) := by simpa only [Nat.add_zero] using valid 0 (by simp)
    have floor : (rows.getD start default).floor≤tail.length := by simpa only [Nat.add_zero] using floors 0 (by simp)
    have nonpoly : (rows.getD start default).polymorphic=false := by
      cases poly : (rows.getD start default).polymorphic
      · rfl
      · have bad := spec kind
        simp only [poly,ite_true] at bad
        have size := bad.1
        rw [initial] at size
        simp only [List.length_append,List.length_reverse,List.length_cons] at size
        omega
    have read := spec kind
    simp only [nonpoly,Bool.false_eq_true,ite_false] at read
    obtain ⟨rest,equal,_⟩ := read
    have split : (tail++actual.reverse)++[tag]=rest++[(rows.getD start default).valueType] := by
      simpa only [List.reverse_cons,List.append_assoc] using initial.symm.trans equal
    have matched := List.append_inj' split rfl
    have tagEq : (rows.getD start default).valueType=tag := (List.cons.inj matched.2).1.symm
    have after : stack rows (start+1)=tail++actual.reverse := by
      simp only [stack,next,kind,nonpoly,Bool.false_eq_true,ite_false,equal,List.length_append,
        List.length_singleton,Nat.add_sub_cancel,List.take_left]
      exact matched.1.symm
    have result := ih (start+1) after
      (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using kinds (i+1) (by simp only [List.length_cons]; omega))
      (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using valid (i+1) (by simp only [List.length_cons]; omega))
      (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using floors (i+1) (by simp only [List.length_cons]; omega))
    exact ⟨by simp only [List.length_cons,values,tagEq,result.1],
      by simpa only [List.length_cons,Nat.add_assoc,Nat.add_comm 1 actual.length] using result.2⟩

theorem reversed (rows : List Row) (popStart pushStart count : Nat)
    (mirror : ∀ i, i<count → (rows.getD (pushStart+i) default).valueType=(rows.getD (popStart+(count-1-i)) default).valueType) :
    values rows pushStart count=(values rows popStart count).reverse := by
  apply List.ext_getElem (by simp only [length,List.length_reverse])
  intro i ib jb
  have inside : i<count := by simpa only [length] using ib
  have left := point rows pushStart count i inside
  have right := point rows popStart count (count-1-i) (by omega)
  simp only [List.getD,List.getElem?_eq_getElem ib,Option.getD_some] at left
  have rb : count-1-i<(values rows popStart count).length := by rw [length]; omega
  simp only [List.getD,List.getElem?_eq_getElem rb,Option.getD_some] at right
  simp only [left,List.getElem_reverse,length]
  exact (mirror i inside).trans right.symm

#print axioms restored
#print axioms reversed
end ZkBuild.BranchOperandRuns
