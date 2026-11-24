import BranchCommonOperands
set_option autoImplicit false
namespace ZkBuild.BranchValuePlan
open OperandEvents BranchPlans

def action (row : Row) : Action :=
  match row.kind with
  | .pop => .pop row.valueType.val
  | .push => .push row.valueType.val
  | .clear => .clear
  | _ => .label

def actions (rows : List Row) (start : Nat) : Nat → List Action
  | 0 => []
  | count+1 => action (rows.getD start default) :: actions rows (start+1) count

theorem append (rows : List Row) (start left right : Nat) :
    actions rows start (left+right)=actions rows start left++actions rows (start+left) right := by
  induction left generalizing start with
  | zero => simp only [Nat.zero_add,Nat.add_zero,actions,List.nil_append]
  | succ left ih =>
    rw [Nat.succ_add,actions,actions,ih,List.cons_append]
    rw [show start+1+left=start+(left+1) from by omega]

theorem pops (rows : List Row) (start count : Nat)
    (kinds : ∀ i, i<count → (rows.getD (start+i) default).kind=.pop) :
    actions rows start count=(BranchOperandRuns.values rows start count).map (fun tag => Action.pop tag.val) := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih =>
    have kind : (rows.getD start default).kind=.pop := by simpa only [Nat.add_zero] using kinds 0 (by omega)
    have tail := ih (start+1) (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using kinds (i+1) (by omega))
    simp only [actions,action,kind,BranchOperandRuns.values,List.map_cons,tail]

theorem pushes (rows : List Row) (start count : Nat)
    (kinds : ∀ i, i<count → (rows.getD (start+i) default).kind=.push) :
    actions rows start count=(BranchOperandRuns.values rows start count).map (fun tag => Action.push tag.val) := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih =>
    have kind : (rows.getD start default).kind=.push := by simpa only [Nat.add_zero] using kinds 0 (by omega)
    have tail := ih (start+1) (by intro i ib; simpa only [Nat.add_assoc,Nat.add_comm 1 i] using kinds (i+1) (by omega))
    simp only [actions,action,kind,BranchOperandRuns.values,List.map_cons,tail]

def repeated (actual : List Nat) : Nat → List Action
  | 0 => .label :: actual.map Action.pop ++ [.clear]
  | previous+1 => .label :: actual.map Action.pop ++ actual.reverse.map Action.push ++ repeated actual previous

theorem target_values_irrelevant (actual : List Nat) (targets : List (List Nat)) (previous : Nat)
    (size : targets.length=previous+1) : plan actual targets=repeated actual previous := by
  induction previous generalizing targets with
  | zero =>
    cases targets with
    | nil => simp at size
    | cons first rest =>
      have empty : rest=[] := List.length_eq_zero_iff.mp (by simp only [List.length_cons] at size; omega)
      subst rest
      rfl
  | succ previous ih =>
    cases targets with
    | nil => simp at size
    | cons first rest =>
      cases rest with
      | nil => simp at size
      | cons second rest =>
        simp only [plan,repeated,ih (second::rest) (by simp only [List.length_cons] at size ⊢; omega)]

theorem body (rows : List Row) (start count previous : Nat) (actual : List (Fin 8))
    (labels : ∀ g, g≤previous → (rows.getD (start+g*(1+2*count)) default).kind=.labelCheck)
    (popKinds : ∀ g, g≤previous → ∀ i, i<count → (rows.getD (start+g*(1+2*count)+1+i) default).kind=.pop)
    (pushKinds : ∀ g, g<previous → ∀ i, i<count → (rows.getD (start+g*(1+2*count)+1+count+i) default).kind=.push)
    (popValues : ∀ g, g≤previous → BranchOperandRuns.values rows (start+g*(1+2*count)+1) count=actual)
    (pushValues : ∀ g, g<previous → BranchOperandRuns.values rows (start+g*(1+2*count)+1+count) count=actual.reverse)
    (clear : (rows.getD (start+previous*(1+2*count)+1+count) default).kind=.clear) :
    actions rows start (previous*(1+2*count)+count+2)=repeated (actual.map Fin.val) previous := by
  induction previous generalizing start with
  | zero =>
    have label : (rows.getD start default).kind=.labelCheck := by simpa using labels 0 (by omega)
    have pop := pops rows (start+1) count (by simpa using popKinds 0 (by omega))
    have vals : BranchOperandRuns.values rows (start+1) count=actual := by simpa using popValues 0 (by omega)
    have endKind : (rows.getD (start+1+count) default).kind=.clear := by simpa using clear
    rw [show 0*(1+2*count)+count+2=(count+1)+1 from by omega]
    rw [actions,append rows (start+1) count 1,pop,vals]
    simp only [actions,label,action,endKind,repeated,List.map_map,Function.comp_def,List.cons_append]
  | succ previous ih =>
    let next := start+(1+2*count)
    have shift (g : Nat) : next+g*(1+2*count)=start+(g+1)*(1+2*count) := by
      dsimp [next]
      rw [Nat.succ_mul g (1+2*count)]
      omega
    have tail := ih next
      (by intro g gb; rw [shift]; exact labels (g+1) (by omega))
      (by intro g gb i ib; rw [shift]; exact popKinds (g+1) (by omega) i ib)
      (by intro g gb i ib; rw [shift]; exact pushKinds (g+1) (by omega) i ib)
      (by intro g gb; rw [shift]; exact popValues (g+1) (by omega))
      (by intro g gb; rw [shift]; exact pushValues (g+1) (by omega))
      (by rw [shift]; exact clear)
    have label : (rows.getD start default).kind=.labelCheck := by simpa using labels 0 (by omega)
    have pop := pops rows (start+1) count (by simpa using popKinds 0 (by omega))
    have push := pushes rows (start+1+count) count (by simpa using pushKinds 0 (by omega))
    have pv : BranchOperandRuns.values rows (start+1) count=actual := by simpa using popValues 0 (by omega)
    have qv : BranchOperandRuns.values rows (start+1+count) count=actual.reverse := by simpa using pushValues 0 (by omega)
    rw [show (previous+1)*(1+2*count)+count+2=(count+count+(previous*(1+2*count)+count+2))+1 from by rw [Nat.succ_mul previous (1+2*count)]; omega]
    rw [actions,show count+count+(previous*(1+2*count)+count+2)=count+(count+(previous*(1+2*count)+count+2)) from by omega,
      append rows (start+1) count,append rows (start+1+count) count,pop,push,pv,qv]
    have location : start+1+count+count=next := by dsimp [next]; omega
    rw [location,tail]
    simp only [action,label,repeated,List.map_reverse,List.map_map,Function.comp_def,List.append_assoc,List.cons_append]

#print axioms body
#print axioms target_values_irrelevant
end ZkBuild.BranchValuePlan
