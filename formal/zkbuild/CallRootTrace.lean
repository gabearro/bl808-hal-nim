import CallReadTrace
import FunctionTraceSound
set_option autoImplicit false
namespace ZkBuild.CallRootTrace
open Lean.Grind OperandEvents

def Schedule (rows : List Row) (first : Nat) : Prop := ∀ i, i < rows.length →
  FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
  ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (FunctionTraceSound.state rows first i).index)

/-- The root result cursor of an open function comes from its actual begin
    row, and that row has the same function index as the current schedule. -/
theorem opened (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs) (first : Nat)
    (schedule : Schedule rows first) (i : Nat) (ib : i ≤ rows.length)
    (active : (FunctionTraceSound.state rows first i).opened = true) :
    ∃ start, start < i ∧ (rows.getD start default).kind = .functionBegin ∧
      (rows.getD start default).functionIndex = (FunctionTraceSound.state rows first i).index ∧
      (CallTraceSound.state rows ops data i).root = (data start).results := by
  induction i with
  | zero => contradiction
  | succ i ih =>
    have inside : i < rows.length := by omega
    have next : (FunctionTraceSound.state rows first (i+1)).opened =
        FunctionEvents.nextOpen (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind := rfl
    rw [next] at active
    by_cases beginKind : (rows.getD i default).kind = .functionBegin
    · refine ⟨i,by omega,beginKind,?_,?_⟩
      · simpa only [FunctionTraceSound.state,FunctionEvents.nextIndex,beginKind,reduceCtorEq,ite_false,Nat.add_zero] using
          (schedule i inside).2 (by rw [beginKind]; decide)
      · simp only [CallTraceSound.state,CallState.advance,CallState.prepare,beginKind,ite_true]
    · by_cases endKind : (rows.getD i default).kind = .functionEnd
      · simp only [endKind,FunctionEvents.nextOpen] at active
        contradiction
      · have prior : (FunctionTraceSound.state rows first i).opened = true := by
          cases kind : (rows.getD i default).kind <;> simp_all [FunctionEvents.nextOpen]
        obtain ⟨start,bound,kind,index,root⟩ := ih (by omega) prior
        refine ⟨start,by omega,kind,?_,?_⟩
        · simpa only [FunctionTraceSound.state,FunctionEvents.nextIndex,endKind,ite_false,Nat.add_zero] using index
        · simpa only [CallTraceSound.state,CallState.advance,CallState.prepare,beginKind,ite_false] using root

theorem instruction (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs) (first : Nat)
    (schedule : Schedule rows first) (i : Nat) (ib : i < rows.length) (kind : (rows.getD i default).kind = .instructionBegin) :
    ∃ start, start < i ∧ (rows.getD start default).kind = .functionBegin ∧
      (rows.getD start default).functionIndex = (rows.getD i default).functionIndex ∧
      (CallTraceSound.ready rows ops data i).root = (data start).results := by
  have active : (FunctionTraceSound.state rows first i).opened = true := by
    simpa only [FunctionEvents.ScheduleOk,kind,reduceCtorEq,or_self,ite_false] using (schedule i ib).1
  obtain ⟨start,bound,beginKind,index,root⟩ := opened rows ops data first schedule i (by omega) active
  exact ⟨start,bound,beginKind,index.trans ((schedule i ib).2 (by rw [kind]; decide)).symm,
    by simpa only [CallTraceSound.ready,CallState.prepare,kind,reduceCtorEq,ite_false] using root⟩

#print axioms opened
#print axioms instruction
end ZkBuild.CallRootTrace
