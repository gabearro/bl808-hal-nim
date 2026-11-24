import CallState
set_option autoImplicit false
namespace ZkBuild.CallTransition
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents CallState
attribute [local instance] Ring.intCast Semiring.natCast

theorem cursors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (s : State) (image : Image values (ready r) s)
    (masks : Masks values r s kind code) (next : Fin (2^32)) (ni : E values r.payload.high = (next.val : F)) :
    E values (f r.after 27) = ((advance s kind code next).params.val : F) ∧
    E values (f r.after 28) = ((advance s kind code next).results.val : F) ∧
    E values (f r.after 29) = flag (advance s kind code next).pending ∧
    E values (f r.after 30) = flag (advance s kind code next).pushed := by
  obtain ⟨pop,index,arg,push,clear,finish,ordinary⟩ := masks
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have p : E values (f r.after 12) = (s.params.val : F) := image.1
  have q : E values (f r.after 13) = (s.results.val : F) := image.2.1
  have i : E values (f r.after 14) = flag s.pending := image.2.2.1
  have u : E values (f r.after 15) = flag s.pushed := image.2.2.2.1
  have hp := eqs.nextParams
  have hq := eqs.nextResults
  have hi := eqs.nextPending
  have hu := eqs.nextPushed
  simp only [p,q,i,u,ni,arg,push,index,eval_sub,o,eval_constant values one,Ring.intCast_one] at hp hq hi hu
  refine ⟨?_,?_,?_,?_⟩
  · cases pick : argument s kind code <;> simp [advance,pick,flag] at hp ⊢ <;> grind only
  · cases pick : pushing kind code <;> simp [advance,pick,flag] at hq ⊢ <;> grind only
  · cases old : s.pending <;> cases pick : popping kind code <;> simp [advance,old,pick,flag] at hi ⊢ <;> grind only
  · cases old : s.pushed <;> cases pick : pushing kind code <;> simp [advance,old,pick,flag] at hu ⊢ <;> grind only

theorem clear_ready {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (s : State) (image : Image values (ready r) s)
    (masks : Masks values r s kind code) (next : Fin (2^32)) (ni : E values r.payload.high = (next.val : F))
    (enabled : clearing kind code = true) : s.params.val = 0 ∧ s.pending = false ∧ s.cleared = false := by
  have parts := Bool.and_eq_true_iff.mp enabled
  have kindEq : kind = .clear := of_decide_eq_true parts.2
  have state := cursors matrix r checked values one satisfied kind code s image masks next ni
  have pi : E values (f r.after 27) = (s.params.val : F) := by simpa [advance,argument,popping,kindEq] using state.1
  have ii : E values (f r.after 29) = flag s.pending := by simpa [advance,popping,kindEq] using state.2.2.1
  have ci : E values (f r.after 16) = flag s.cleared := image.2.2.2.2.1
  have empty := (CallRowEquations.meaning matrix r checked values one satisfied).clearEmpty
  rw [masks.2.2.2.2.1,enabled] at empty
  simp only [flag,ite_true,Semiring.one_mul,eval_append,pi,ii,ci] at empty
  exact CallEvents.sum_zero_sound s.params.val s.pending s.cleared s.params.isLt empty

theorem image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (s : State) (readyImage : Image values (ready r) s)
    (masks : Masks values r s kind code) (next : Fin (2^32)) (ni : E values r.payload.high = (next.val : F)) :
    Image values (after r) (advance s kind code next) := by
  have state := cursors matrix r checked values one satisfied kind code s readyImage masks next ni
  have once (enabled : clearing kind code = true) : s.cleared = false :=
    (clear_ready matrix r checked values one satisfied kind code s readyImage masks next ni enabled).2.2
  have ci : E values (f r.after 16) = flag s.cleared := readyImage.2.2.2.2.1
  have nextClear := (CallRowEquations.meaning matrix r checked values one satisfied).nextCleared
  simp only [eval_append,ci,masks.2.2.2.2.1] at nextClear
  have cleared : E values (f r.after 31) = flag (s.cleared || clearing kind code) :=
    CallEvents.cleared_update (clearing kind code) s.cleared _ once nextClear
  exact ⟨state.1,state.2.1,state.2.2.1,state.2.2.2,cleared,readyImage.2.2.2.2.2⟩

#print axioms cursors
#print axioms clear_ready
#print axioms image
end ZkBuild.CallTransition
