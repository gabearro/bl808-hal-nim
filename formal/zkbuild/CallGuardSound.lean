import CallTraceSound
set_option autoImplicit false
namespace ZkBuild.CallGuardSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents CallState
attribute [local instance] Ring.intCast Semiring.natCast

structure Spec (s : State) (kind : Kind) (code : Nat) (actual tag : Fin 8) : Prop where
  popOrder : popping kind code = true → s.pushed = false ∧ s.cleared = false
  indexType : popping kind code = true → s.pending = true → actual.val = 0 ∨ actual.val = 7
  argumentType : argument s kind code = true → actual = tag ∨ actual.val = 7
  push : pushing kind code = true → CallMode.tail code = false ∧ s.pending = false ∧ s.cleared = false ∧ s.params.val = 0 ∧ actual = tag
  clear : clearing kind code = true → CallMode.tail code = true ∧ s.params.val = 0 ∧ s.pending = false ∧ s.cleared = false
  finish : finishing kind code = true → s.params.val = 0 ∧ s.pending = false ∧ s.cleared = CallMode.tail code ∧ (CallMode.tail code = false → s.results.val = 0)
  noControl : CallMode.active code = true → kind ≠ .controlPush ∧ kind ≠ .controlPop

theorem flag_disjunction {F : Type} [Field F] (a b : Bool) (equation : 1-flag (F := F) a-flag b = 0) : a = true ∨ b = true := by
  cases a <;> cases b <;> simp [flag] at equation ⊢
  have bad : (1 : F) = 0 := by grind only
  exact False.elim (Field.zero_ne_one bad.symm)

theorem natural_eq {F : Type} [Field F] [IsCharP F scalarModulus] (a b : Fin 8) :
    (a.val : F)-(b.val : F) = 0 ↔ a = b := by
  have casts := IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans a.isLt (by decide)) (Nat.lt_trans b.isLt (by decide))
  constructor
  · intro h; apply Fin.ext; apply casts.mp; grind only
  · intro same; subst b; grind only

theorem types {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual tag : Fin 8) (ai : E values (f r.row 4) = (actual.val : F)) (ti : E values r.payload.low = (tag.val : F)) :
    E values (f r.after 22) = flag (decide (actual.val = 7)) ∧
    E values (f r.after 23) = flag (decide (actual.val = 0)) ∧
    E values (f r.after 26) = flag (decide (actual = tag)) := by
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have unknown := eqs.unknown
  have zero := eqs.actualZero
  have matched := eqs.matched
  have same7 : (actual.val : F)-7 = 0 ↔ actual.val = 7 := by
    simpa only [Fin.ext_iff,Semiring.natCast_eq_ofNat 7] using natural_eq (F := F) actual ⟨7,by decide⟩
  have same0 : (actual.val : F) = 0 ↔ actual.val = 0 := by
    have casts := IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans actual.isLt (by decide)) (show 0 < scalarModulus by decide)
    simpa only [Semiring.natCast_zero] using casts
  simp only [eval_sub,ai,ti,n,eval_constant values one,
    show ((Int.ofNat 7 : Int) : F) = 7 from Ring.intCast_ofNat 7,same7,same0,natural_eq] at unknown zero matched
  simpa only [flag,decide_eq_true_eq] using And.intro unknown (And.intro zero matched)

theorem ordinary (code : Nat) (active : CallMode.active code = true) :
    CallMode.ordinary code = !CallMode.tail code := by
  have kinds := _root_.of_decide_eq_true active
  rcases kinds with rfl | rfl | rfl | rfl <;> rfl

theorem guards {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : CallRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (s : State) (image : Image values (ready r) s)
    (masks : Masks values r s kind code) (next : Fin (2^32)) (ni : E values r.payload.high = (next.val : F))
    (actual tag : Fin 8) (ai : E values (f r.row 4) = (actual.val : F)) (ti : E values r.payload.low = (tag.val : F)) :
    Spec s kind code actual tag := by
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  have typed := types matrix r checked values one satisfied actual tag ai ti
  have pi : E values (f r.after 12) = (s.params.val : F) := image.1
  have ii : E values (f r.after 14) = flag s.pending := image.2.2.1
  have ui : E values (f r.after 15) = flag s.pushed := image.2.2.2.1
  have clearImage : E values (f r.after 16) = flag s.cleared := image.2.2.2.2.1
  constructor
  · intro enabled
    have gate := eqs.popOrder
    simp only [masks.1,enabled,flag,ite_true,Semiring.one_mul,eval_append,ui,clearImage] at gate
    exact CallEvents.pop_order_sound s.pushed s.cleared gate
  · intro enabled pending
    have gate := eqs.indexType
    simp only [masks.2.1,enabled,pending,Bool.and_self,flag,ite_true,Semiring.one_mul,
      eval_sub,o,eval_constant values one,Ring.intCast_one,typed.1,typed.2.1] at gate
    have result := flag_disjunction _ _ gate
    exact result.elim (fun h => Or.inr (_root_.of_decide_eq_true h)) (fun h => Or.inl (_root_.of_decide_eq_true h))
  · intro enabled
    have gate := eqs.argumentType
    simp only [masks.2.2.1,enabled,flag,ite_true,Semiring.one_mul,
      eval_sub,o,eval_constant values one,Ring.intCast_one,typed.1,typed.2.2] at gate
    have result := flag_disjunction _ _ gate
    exact result.elim (fun h => Or.inr (_root_.of_decide_eq_true h)) (fun h => Or.inl (_root_.of_decide_eq_true h))
  · intro enabled
    have order := eqs.pushOrder
    have empty := eqs.pushEmpty
    have value := eqs.resultType
    simp only [masks.2.2.2.1,enabled,flag,ite_true,Semiring.one_mul,eval_append,mode.2.1,ii,clearImage] at order
    simp only [masks.2.2.2.1,enabled,flag,ite_true,Semiring.one_mul,pi] at empty
    simp only [masks.2.2.2.1,enabled,flag,ite_true,Semiring.one_mul,eval_sub,ai,ti] at value
    have orders := CallEvents.push_order_sound (CallMode.tail code) s.pending s.cleared order
    have params := NumericEvents.nat_eq (F := F) s.params.val 0
      (Nat.lt_trans s.params.isLt (by decide)) (by decide) (by simpa only [Semiring.natCast_zero] using empty)
    exact ⟨orders.1,orders.2.1,orders.2.2,params,(natural_eq actual tag).mp value⟩
  · intro enabled
    have clear := CallTransition.clear_ready matrix r checked values one satisfied kind code s image masks next ni enabled
    have tail := eqs.clearTail
    simp only [masks.2.2.2.2.1,enabled,flag,ite_true,Semiring.one_mul,eval_sub,o,
      eval_constant values one,Ring.intCast_one,mode.2.1] at tail
    exact ⟨VariableTyping.mutation_gate (CallMode.tail code) tail,clear⟩
  · intro enabled
    have kindEq : kind = .instructionEnd := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp enabled).2
    have active : CallMode.active code = true := (Bool.and_eq_true_iff.mp enabled).1
    have advanced := CallTransition.image matrix r checked values one satisfied kind code s image masks next ni
    have same : advance s kind code next = s := by
      cases s; simp [advance,argument,popping,pushing,clearing,kindEq]
    rw [same] at advanced
    have p : E values (f r.after 27) = (s.params.val : F) := advanced.1
    have q : E values (f r.after 28) = (s.results.val : F) := advanced.2.1
    have i : E values (f r.after 29) = flag s.pending := advanced.2.2.1
    have c : E values (f r.after 31) = flag s.cleared := advanced.2.2.2.2.1
    have hp := eqs.endParams
    have hi := eqs.endPending
    have hc := eqs.endCleared
    have hq := eqs.endResults
    simp only [masks.2.2.2.2.2.1,enabled,flag,ite_true,Semiring.one_mul,p,i,eval_sub,c,mode.2.1] at hp hi hc
    simp only [masks.2.2.2.2.2.2,kindEq,decide_true,Bool.and_true,ordinary code active,q] at hq
    have opposite : flag (F := F) (!CallMode.tail code) = 1-flag (CallMode.tail code) := by
      cases CallMode.tail code <;> simp [flag] <;> grind only
    rw [opposite] at hq
    exact CallEvents.end_sound s.params.val s.results.val (CallMode.tail code) s.pending s.cleared s.params.isLt s.results.isLt hp hi hc hq
  · intro active
    have equation := eqs.noControl
    obtain ⟨_,_,_,_,t4,t5,_,_,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
    change E values (f r.flags 4) = _ at t4
    change E values (f r.flags 5) = _ at t5
    simp only [mode.1,active,flag,ite_true,Semiring.one_mul,eval_append,t4,t5] at equation
    constructor <;> intro bad <;> subst kind <;> simp [ControlEvents.selected,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add] at equation
    all_goals exact Field.zero_ne_one equation.symm

structure StartSpec {F : Type} [Field F] (values : Nat → F) (r : CallRowCheck.Record)
    (s : State) (kind : Kind) (code : Nat) (results : Fin (2^32)) : Prop where
  tailResults : kind = .instructionBegin → CallMode.tail code = true → results = s.root
  tableType : kind = .instructionBegin → CallMode.indirect code = true → E values r.tableQuery.value = 5
  inactiveImmediates : kind ≠ .instructionBegin → E values r.primary = 0 ∧ E values r.secondary = 0

theorem start {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : CallRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (s : State) (image : Image values (ready r) s)
    (results : Fin (2^32)) (ri : E values r.heads.high = (results.val : F)) : StartSpec values r s kind code results := by
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  obtain ⟨_,t1,_,_,_,_,_,_,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  change E values (f r.flags 1) = _ at t1
  have root : E values (f r.after 10) = (s.root.val : F) := image.2.2.2.2.2
  constructor
  · intro beginKind tail
    have returning := eqs.returning
    simp only [mode.2.1,tail,t1,beginKind,ControlEvents.selected,decide_true,flag,ite_true,Semiring.one_mul] at returning
    have same := eqs.tailResult
    simp only [returning,Semiring.one_mul,eval_sub,ri,root] at same
    apply Fin.ext
    exact NumericEvents.nat_eq (F := F) results.val s.root.val
      (Nat.lt_trans results.isLt (by decide)) (Nat.lt_trans s.root.isLt (by decide)) (by grind only)
  · intro beginKind indirect
    have enabled := eqs.indirectBegin
    simp only [mode.2.2.1,indirect,t1,beginKind,ControlEvents.selected,decide_true,flag,ite_true,Semiring.one_mul] at enabled
    have typed := eqs.tableType
    simp only [enabled,Semiring.one_mul,eval_sub,n,eval_constant values one,
      show ((Int.ofNat 5 : Int) : F) = 5 from Ring.intCast_ofNat 5] at typed
    grind only
  · intro other
    have first := eqs.primaryInactive
    have second := eqs.secondaryInactive
    simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,t1,ControlEvents.selected,
      other,decide_false,flag,ite_false] at first second
    constructor <;> grind only

#print axioms start
#print axioms types
#print axioms guards
end ZkBuild.CallGuardSound
