import BranchConditionTrace
set_option autoImplicit false
namespace ZkBuild.BranchActionLayout
open OperandEvents BranchActionLanguage

def width (arity : Nat) := 1+2*arity
def label (first arity group : Nat) := first+2+group*width arity

theorem blocks_length (arity count : Nat) : (blocks arity count).length=count*width arity := by
  induction count with
  | zero => simp [blocks]
  | succ count ih => simp only [blocks,List.length_append,ih,block,List.length_append,
      List.length_cons,List.length_nil,List.length_replicate,width,Nat.succ_mul]; omega

theorem blocks_add (arity a b : Nat) : blocks arity (a+b)=blocks arity a++blocks arity b := by
  induction b with
  | zero => simp [blocks]
  | succ b ih => rw [Nat.add_succ,blocks,ih,blocks,List.append_assoc]

theorem blocks_left (arity count : Nat) : blocks arity (count+1)=block arity++blocks arity count := by
  have h := blocks_add arity 1 count
  simpa only [Nat.add_comm 1 count,blocks,List.nil_append] using h

theorem full_group (arity previous group : Nat) (inside : group<previous) :
    ∃ tail, plan arity previous=([.pop]++blocks arity group)++block arity++tail := by
  have sum : group+(previous-group)=previous := by omega
  have remaining : previous-group=(previous-group-1)+1 := by omega
  have split := blocks_add arity group (previous-group)
  rw [sum,remaining,blocks_left] at split
  refine ⟨blocks arity (previous-group-1)++[.labelCheck]++List.replicate arity .pop++[.clear],?_⟩
  simp only [plan,split,List.append_assoc]

theorem any_group (arity previous group : Nat) (inside : group≤previous) :
    ∃ tail, plan arity previous=([.pop]++blocks arity group)++([.labelCheck]++List.replicate arity .pop)++tail := by
  by_cases last : group=previous
  · subst group
    exact ⟨[.clear],by simp only [plan,List.append_assoc]⟩
  · obtain ⟨tail,eq⟩ := full_group arity previous group (by omega)
    exact ⟨List.replicate arity .push++tail,by simpa only [block,List.append_assoc] using eq⟩

theorem at_middle (before middle after : List Kind) (i : Nat) (inside : i<middle.length) :
    (before++middle++after).getD (before.length+i) .padding=middle.getD i .padding := by
  simp only [List.append_assoc,List.getD]
  rw [List.getElem?_append_right (by omega),Nat.add_sub_cancel_left,List.getElem?_append_left inside]

theorem in_middle (before middle after : List Kind) (i : Nat) (inside : i<middle.length) :
    before.length+i<(before++middle++after).length := by simp only [List.length_append]; omega

theorem source_middle (rows : List Row) (first last arity previous : Nat)
    (planEq : BranchActionSequence.kinds rows (first+1) (last-first-1)=plan arity previous)
    (before middle after : List Kind) (eq : plan arity previous=before++middle++after)
    (i : Nat) (inside : i<middle.length) :
    (rows.getD (first+1+(before.length+i)) default).kind=middle.getD i .padding := by
  have length := congrArg List.length planEq
  simp only [BranchActionSequence.kinds,List.length_map,List.length_range] at length
  have bounded := in_middle before middle after i inside
  rw [← eq,← length] at bounded
  have h := congrArg (fun xs : List Kind => xs.getD (before.length+i) .padding) planEq
  rw [BranchConditionTrace.point rows (first+1) (last-first-1) _ bounded,eq,at_middle before middle after i inside] at h
  exact h

structure Layout (rows : List Row) (first last arity previous : Nat) : Prop where
  endIndex : last=first+4+previous*width arity+arity
  labels : ∀ group, group≤previous → (rows.getD (label first arity group) default).kind=.labelCheck
  pops : ∀ group, group≤previous → ∀ ordinal, ordinal<arity →
    (rows.getD (label first arity group+1+ordinal) default).kind=.pop
  pushes : ∀ group, group<previous → ∀ ordinal, ordinal<arity →
    (rows.getD (label first arity group+1+arity+ordinal) default).kind=.push
  clear : (rows.getD (last-1) default).kind=.clear

theorem sound (rows : List Row) (first last arity previous : Nat) (ordered : first<last)
    (planEq : BranchActionSequence.kinds rows (first+1) (last-first-1)=plan arity previous) :
    Layout rows first last arity previous := by
  have length := congrArg List.length planEq
  simp only [BranchActionSequence.kinds,List.length_map,List.length_range,plan,List.length_append,
    List.length_cons,List.length_nil,List.length_replicate,blocks_length] at length
  have endIndex : last=first+4+previous*width arity+arity := by omega
  refine ⟨endIndex,?_,?_,?_,?_⟩
  · intro group inside
    obtain ⟨tail,eq⟩ := any_group arity previous group inside
    have h := source_middle rows first last arity previous planEq _ _ tail eq 0 (by simp)
    simp only [List.length_append,List.length_cons,List.length_nil,blocks_length,List.singleton_append,
      List.getD_cons_zero,Nat.add_zero] at h
    have location : first+1+(group*width arity+1)=label first arity group := by unfold label; omega
    rw [location] at h
    exact h
  · intro group inside ordinal ob
    obtain ⟨tail,eq⟩ := any_group arity previous group inside
    have h := source_middle rows first last arity previous planEq _ _ tail eq (ordinal+1) (by simp; omega)
    have value : ([Kind.labelCheck]++List.replicate arity Kind.pop).getD (ordinal+1) Kind.padding=Kind.pop := by
      simp [List.getD,ob]
    rw [value] at h
    simp only [List.length_append,List.length_cons,List.length_nil,blocks_length] at h
    have location : first+1+(0+1+group*width arity+(ordinal+1))=label first arity group+1+ordinal := by unfold label; omega
    rw [location] at h
    exact h
  · intro group inside ordinal ob
    obtain ⟨tail,eq⟩ := full_group arity previous group inside
    have h := source_middle rows first last arity previous planEq _ _ tail eq (1+arity+ordinal) (by simp [block]; omega)
    have value : (block arity).getD (1+arity+ordinal) .padding=.push := by
      have h := at_middle ([.labelCheck]++List.replicate arity .pop) (List.replicate arity .push) [] ordinal (by simpa using ob)
      simpa only [block,List.append_nil,List.length_append,List.length_cons,List.length_nil,List.length_replicate,
        List.getD,List.getElem?_replicate,ob,ite_true,Option.getD_some] using h
    rw [value] at h
    simp only [List.length_append,List.length_cons,List.length_nil,blocks_length] at h
    have location : first+1+(0+1+group*width arity+(1+arity+ordinal))=label first arity group+1+arity+ordinal := by unfold label; omega
    rw [location] at h
    exact h
  · have h := source_middle rows first last arity previous planEq
      ([.pop]++blocks arity previous++[.labelCheck]++List.replicate arity .pop) [.clear] []
      (by simp only [plan,List.append_nil]) 0 (by simp)
    simp only [List.length_append,List.length_cons,List.length_nil,List.length_replicate,blocks_length,
      List.getD_cons_zero,Nat.add_zero] at h
    have location : first+1+(0+1+previous*width arity+(0+1)+arity)=last-1 := by omega
    rw [location] at h
    exact h

#print axioms sound
end ZkBuild.BranchActionLayout
