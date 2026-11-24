import BranchTypeTrace
import BranchTypeScratch
set_option autoImplicit false
namespace ZkBuild.BranchTypeGuards
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchTypeRowCheck BranchTypeState
attribute [local instance] Ring.intCast Semiring.natCast

def argument (kind : Kind) (code : Nat) (pending : Bool) : Bool :=
  BranchTypePending.selected kind .pop code && !pending

structure Spec (kind : Kind) (code index size : Nat) (pending nextPending : Bool)
    (ready chosen after : State) : Prop where
  label : mark kind code = true → pending = false ∧ ready.last = false ∧ ready.cleared = 0
  repeated : mark kind code = true → ready.seen = true →
    ready.pops = ready.length ∧ ready.pushes = ready.length ∧ size = ready.arity
  pop : argument kind code pending = true → chosen.seen = true ∧ pending = false ∧
    chosen.pushes = 0 ∧ chosen.cleared = 0 ∧ index = chosen.start+chosen.pops
  push : BranchTypePending.selected kind .push code = true → chosen.seen = true ∧ pending = false ∧
    chosen.last = false ∧ chosen.cleared = 0 ∧ chosen.pops = chosen.length ∧ chosen.pushes < chosen.length
  clear : BranchTypePending.selected kind .clear code = true → chosen.seen = true ∧ chosen.last = true ∧
    pending = false ∧ chosen.pushes = 0 ∧ chosen.cleared = 0 ∧ chosen.pops = chosen.length
  finish : BranchTypePending.selected kind .instructionEnd code = true → chosen.seen = true ∧
    chosen.last = true ∧ nextPending = false ∧ after.pushes = 0 ∧ after.pops = chosen.length ∧ after.cleared = 1

theorem zero_sum {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b c : Nat) (ab : a < 2^32) (bb : b < 2^32) (cb : c < 2^32)
    (eq : (a : F)+(b : F)+(c : F) = 0) : a = 0 ∧ b = 0 ∧ c = 0 := by
  have sum : a+b+c = 0 := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by decide)
    (by simpa only [Semiring.natCast_add,Semiring.natCast_zero] using eq)
  omega

theorem zero_flags {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Bool) (c : Nat) (cb : c < 2^32)
    (eq : flag (F := F) a+flag b+(c : F) = 0) : a = false ∧ b = false ∧ c = 0 := by
  have z := zero_sum (F := F) a.toNat b.toNat c
    (by cases a <;> decide) (by cases b <;> decide) cb
    (by simpa only [OperandMemorySound.flag_nat] using eq)
  cases a <;> cases b <;> simp_all

theorem flag_one {F : Type} [Field F] (b : Bool) (eq : flag (F := F) b = 1) : b = true := by
  cases b
  · exact False.elim (Field.zero_ne_one (by simpa [flag] using eq))
  · rfl

theorem activity {F : Type} [Field F] (kind : Kind) (code : Nat) (pending : Bool) :
    flag (F := F) (argument kind code pending)+flag (BranchTypePending.selected kind .push code)+
      flag (BranchTypePending.selected kind .clear code) =
    flag (argument kind code pending || BranchTypePending.selected kind .push code || BranchTypePending.selected kind .clear code) := by
  cases kind <;> by_cases c : code = 14 <;> cases pending <;>
    simp [argument,BranchTypePending.selected,flag,c] <;> grind only

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (pending nextPending : Bool)
    (tags : BranchTypeCertificate.Tags values r kind code)
    (masks : BranchTypePending.Masks values r kind code pending)
    (ni : E values (f r.after 50) = flag nextPending)
    (d : BranchTypeData.Data) (di : BranchTypeData.Images values r d)
    (ready chosen after : State)
    (ri : Image values (BranchTypeState.ready r) ready)
    (ci : Image values (BranchTypeState.chosen r) chosen)
    (ai : Image values (BranchTypeState.after r) after)
    (rb : BranchTypeTrace.Bounded ready (2^32-1))
    (cb : BranchTypeTrace.Bounded chosen (2^32-1))
    (ab : BranchTypeTrace.Bounded after (2^32-1)) (ib : r.index < 2^32) :
    Spec kind code r.index d.size.val pending nextPending ready chosen after := by
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  simp only [Image,BranchTypeState.ready,BranchTypeState.chosen,BranchTypeState.after,
    List.map_cons,List.map_nil,field_succ,field_zero] at ri ci ai
  unfold BranchTypeTrace.Bounded at rb cb ab
  have eqnat (a b : Nat) (aSmall : a < 2^32) (bSmall : b < 2^32)
      (eq : (a : F)-(b : F) = 0) : a = b :=
    DeclarationLocations.natural_equal (F := F) a b (by omega) (by omega) (by grind only)
  have label := m.guard (f r.flags 9) (f r.after 7++f r.after 9++f r.after 10) (by simp [guards])
  simp only [eval_append,tags.label,masks.pending,ri.2.2.2.2.2.1,ri.2.2.2.2.2.2.1] at label
  have labelFact (marked : mark kind code = true) : pending = false ∧ ready.last = false ∧ ready.cleared = 0 := by
    change flag (F := F) (mark kind code)*(flag pending+flag ready.last+(ready.cleared : F)) = 0 at label
    simp only [marked,flag,ite_true,Semiring.one_mul] at label
    apply zero_flags (F := F) pending ready.last ready.cleared (by omega)
    simpa only [flag] using label
  have rep := m.multiply (f r.flags 9) (f r.after 8) 12 (by simp [multiplies])
  simp only [tags.label,ri.2.2.2.2.1] at rep
  have repeatedPops := m.guard (f r.after 12) (sub (f r.after 4) (f r.after 2)) (by simp [guards])
  have repeatedPushes := m.guard (f r.after 12) (sub (f r.after 5) (f r.after 13)) (by simp [guards])
  have repeatedArity := m.guard (f r.after 12) (sub r.size.value (f r.after 3)) (by simp [guards])
  have restore := m.multiply (sub o (f r.after 9)) (f r.after 2) 13 (by simp [multiplies])
  simp only [rep,restore,eval_sub,o,eval_constant values one,Ring.intCast_one,
    ri.1,ri.2.1,ri.2.2.1,ri.2.2.2.1,ri.2.2.2.2.2.1,di.1] at repeatedPops repeatedPushes repeatedArity
  have seen := m.guard (BranchTypeRowCheck.argument r++f r.after 34++f r.after 35) (sub o (f r.after 30)) (by simp [guards])
  simp only [eval_append,eval_sub,o,eval_constant values one,Ring.intCast_one,
    masks.argument,masks.push,masks.clear,ci.2.2.2.2.1] at seen
  have seenFact (enabled : argument kind code pending = true ∨ BranchTypePending.selected kind .push code = true ∨
      BranchTypePending.selected kind .clear code = true) : chosen.seen = true := by
    have active : (argument kind code pending || BranchTypePending.selected kind .push code || BranchTypePending.selected kind .clear code) = true := by
      rcases enabled with h | h | h <;> simp [h]
    change (flag (F := F) (argument kind code pending)+flag (BranchTypePending.selected kind .push code)+
      flag (BranchTypePending.selected kind .clear code))*(1-flag chosen.seen) = 0 at seen
    rw [activity,active] at seen
    simp only [flag,ite_true] at seen
    apply flag_one (F := F) chosen.seen
    simp only [flag]; grind only
  have pop := m.guard (BranchTypeRowCheck.argument r) (f r.after 7++f r.after 28++f r.after 10) (by simp [guards])
  simp only [eval_append,masks.argument,masks.pending,ci.2.2.2.1,ci.2.2.2.2.2.2.1] at pop
  have push := m.guard (f r.after 34) (f r.after 7++f r.after 31++f r.after 10) (by simp [guards])
  have pushPops := m.guard (f r.after 34) (sub (f r.after 27) (f r.after 26)) (by simp [guards])
  simp only [eval_append,eval_sub,masks.push,masks.pending,ci.1,ci.2.2.1,ci.2.2.2.2.2.1,ci.2.2.2.2.2.2.1] at push pushPops
  have clearLast := m.guard (f r.after 35) (sub o (f r.after 31)) (by simp [guards])
  have clear := m.guard (f r.after 35) (f r.after 7++f r.after 28++f r.after 10) (by simp [guards])
  have clearPops := m.guard (f r.after 35) (sub (f r.after 27) (f r.after 26)) (by simp [guards])
  simp only [eval_append,eval_sub,o,eval_constant values one,Ring.intCast_one,masks.clear,masks.pending,
    ci.1,ci.2.2.1,ci.2.2.2.1,ci.2.2.2.2.2.1,ci.2.2.2.2.2.2.1] at clearLast clear clearPops
  have finishSeen := m.guard (f r.after 52) (sub o (f r.after 30)) (by simp [guards])
  have finishLast := m.guard (f r.after 52) (sub o (f r.after 31)) (by simp [guards])
  have finishPending := m.guard (f r.after 52) (f r.after 50++f r.after 49) (by simp [guards])
  have finishPops := m.guard (f r.after 52) (sub (f r.after 48) (f r.after 26)) (by simp [guards])
  have finishClear := m.guard (f r.after 52) (sub (f r.after 51) o) (by simp [guards])
  simp only [eval_append,eval_sub,o,eval_constant values one,Ring.intCast_one,masks.finish,ni,
    ci.1,ci.2.2.2.2.1,ci.2.2.2.2.2.1,ai.2.2.1,ai.2.2.2.1,ai.2.2.2.2.2.2.1]
    at finishSeen finishLast finishPending finishPops finishClear
  refine ⟨labelFact,?_,?_,?_,?_,?_⟩
  · intro marked seen
    have last := (labelFact marked).2.1
    change decide (kind = .labelCheck ∧ code = 14) = true at marked
    simp only [marked,seen,last,flag,ite_true,Bool.false_eq_true,ite_false,Semiring.one_mul] at repeatedPops repeatedPushes repeatedArity
    exact ⟨eqnat _ _ (by omega) rb.1 repeatedPops,eqnat _ _ (by omega) rb.1 (by grind only),
      eqnat _ _ d.size.isLt rb.2.1 repeatedArity⟩
  · intro active
    have enabled : flag (F := F) (BranchTypePending.selected kind .pop code && !pending) = 1 := by
      change flag (F := F) (argument kind code pending) = 1
      simp only [active,flag,ite_true]
    have z : pending.toNat = 0 ∧ chosen.pushes = 0 ∧ chosen.cleared = 0 := by
      apply zero_sum (F := F) _ _ _ (by cases pending <;> decide) (by omega) (by omega)
      simpa only [enabled,Semiring.one_mul,OperandMemorySound.flag_nat] using pop
    have pendingZero : pending = false := by cases pending <;> simp_all
    have position := BranchTypeScratch.consecutive matrix r checked values one satisfied
      ⟨chosen.start,by omega⟩ ⟨chosen.pops,by omega⟩ ci.2.2.2.2.2.2.2 ci.2.2.1 ib
      (masks.argument.trans enabled)
    exact ⟨seenFact (.inl active),pendingZero,z.2.1,z.2.2,position⟩
  · intro active
    have z : pending = false ∧ chosen.last = false ∧ chosen.cleared = 0 := by
      apply zero_flags (F := F) _ _ _ (by omega)
      simpa only [active,flag,ite_true,Semiring.one_mul] using push
    have pc := eqnat chosen.pops chosen.length (by omega) cb.1
      (by simpa only [active,flag,ite_true,Semiring.one_mul] using pushPops)
    have ordinal := BranchTypeScalar.restore_ordinal matrix r checked values one satisfied
      ⟨chosen.length,cb.1⟩ ⟨chosen.pushes,by omega⟩ ci.1 ci.2.2.2.1
      (by simpa only [active,flag,ite_true] using masks.push)
    exact ⟨seenFact (.inr (.inl active)),z.1,z.2.1,z.2.2,pc,ordinal.1⟩
  · intro active
    have enabled : flag (F := F) (BranchTypePending.selected kind .clear code) = 1 := by simp only [active,flag,ite_true]
    have z : pending.toNat = 0 ∧ chosen.pushes = 0 ∧ chosen.cleared = 0 := by
      apply zero_sum (F := F) _ _ _ (by cases pending <;> decide) (by omega) (by omega)
      simpa only [enabled,Semiring.one_mul,OperandMemorySound.flag_nat] using clear
    have last : chosen.last = true := by
      apply flag_one (F := F) chosen.last
      simp only [active,flag,ite_true,Semiring.one_mul] at clearLast
      simp only [flag]; grind only
    have pc := eqnat chosen.pops chosen.length (by omega) cb.1
      (by simpa only [active,flag,ite_true,Semiring.one_mul] using clearPops)
    exact ⟨seenFact (.inr (.inr active)),last,by cases pending <;> simp_all,z.2.1,z.2.2,pc⟩
  · intro active
    have enabled : flag (F := F) (BranchTypePending.selected kind .instructionEnd code) = 1 := by simp only [active,flag,ite_true]
    simp only [enabled,Semiring.one_mul] at finishSeen finishLast finishPending finishPops finishClear
    have sn := flag_one (F := F) chosen.seen (by grind only)
    have ln := flag_one (F := F) chosen.last (by grind only)
    have z := zero_sum (F := F) nextPending.toNat after.pushes 0 (by cases nextPending <;> decide) (by omega) (by decide)
      (by simpa only [OperandMemorySound.flag_nat,Semiring.natCast_zero,Semiring.add_zero] using finishPending)
    have pc := eqnat after.pops chosen.length (by omega) cb.1 finishPops
    have cc := eqnat after.cleared 1 (by omega) (by decide) (by simpa only [Semiring.natCast_one] using finishClear)
    exact ⟨sn,ln,by cases nextPending <;> simp_all,z.2.1,pc,cc⟩

#print axioms zero_sum
#print axioms zero_flags
#print axioms activity
#print axioms sound
end ZkBuild.BranchTypeGuards
