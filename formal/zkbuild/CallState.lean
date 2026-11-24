import CallRowEquations
import CallEvents
set_option autoImplicit false
namespace ZkBuild.CallState
open Lean.Grind OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  params : Fin (2^32) := ⟨0,by decide⟩
  results : Fin (2^32) := ⟨0,by decide⟩
  pending : Bool := false
  pushed : Bool := false
  cleared : Bool := false
  root : Fin (2^32) := ⟨0,by decide⟩
  deriving Inhabited

def prepare (before : State) (kind : Kind) (code : Nat) (params results : Fin (2^32)) : State :=
  { params := if kind = .functionBegin ∨ kind = .instructionBegin then params else before.params
    results := if kind = .functionBegin ∨ kind = .instructionBegin then results else before.results
    pending := if kind = .functionBegin ∨ kind = .instructionBegin then CallMode.indirect code else before.pending
    pushed := if kind = .functionBegin ∨ kind = .instructionBegin then false else before.pushed
    cleared := if kind = .functionBegin ∨ kind = .instructionBegin then false else before.cleared
    root := if kind = .functionBegin then results else before.root }

def popping (kind : Kind) (code : Nat) := CallMode.active code && decide (kind = .pop)
def pushing (kind : Kind) (code : Nat) := CallMode.active code && decide (kind = .push)
def clearing (kind : Kind) (code : Nat) := CallMode.active code && decide (kind = .clear)
def finishing (kind : Kind) (code : Nat) := CallMode.active code && decide (kind = .instructionEnd)
def argument (s : State) (kind : Kind) (code : Nat) := popping kind code && !s.pending

def advance (s : State) (kind : Kind) (code : Nat) (next : Fin (2^32)) : State :=
  { s with params := if argument s kind code then next else s.params
           results := if pushing kind code then next else s.results
           pending := s.pending && !popping kind code
           pushed := s.pushed || pushing kind code
           cleared := s.cleared || clearing kind code }

open CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix

def Image {F : Type} [Field F] (values : Nat → F) (fields : Fields) (s : State) : Prop :=
  E values (f fields 0) = (s.params.val : F) ∧ E values (f fields 1) = (s.results.val : F) ∧
  E values (f fields 2) = flag s.pending ∧ E values (f fields 3) = flag s.pushed ∧
  E values (f fields 4) = flag s.cleared ∧ E values (f fields 5) = (s.root.val : F)

def ready (r : CallRowCheck.Record) : Fields := [12,13,14,15,16,10].map (f r.after)
def after (r : CallRowCheck.Record) : Fields := [27,28,29,30,31,10].map (f r.after)

theorem initial_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : CallRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (s : State) (before : Image values r.before s)
    (params results : Fin (2^32)) (pi : E values r.heads.low = (params.val : F))
    (ri : E values r.heads.high = (results.val : F)) :
    Image values (ready r) (prepare s kind code params results) := by
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  obtain ⟨t0,t1,_,_,_,_,_,_,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  obtain ⟨p,q,i,u,c,root⟩ := before
  have h0 := eqs.params
  have h1 := eqs.results
  have h2 := eqs.pending
  have h3 := eqs.pushed
  have h4 := eqs.cleared
  have h5 := eqs.root
  simp only [eval_append,z,eval_constant values one,Ring.intCast_zero,p,q,i,u,c,root,pi,ri,mode.2.2.1,t0,t1] at h0 h1 h2 h3 h4 h5
  simp only [Image,ready,List.map_cons,List.map_nil,f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ]
  change E values (f r.after 12) = _ ∧ E values (f r.after 13) = _ ∧ E values (f r.after 14) = _ ∧
    E values (f r.after 15) = _ ∧ E values (f r.after 16) = _ ∧ E values (f r.after 10) = _
  cases kind <;> simp [prepare,ControlEvents.selected,flag] at h0 h1 h2 h3 h4 h5 ⊢ <;> grind only

def Masks {F : Type} [Field F] (values : Nat → F) (r : CallRowCheck.Record) (s : State) (kind : Kind) (code : Nat) : Prop :=
  E values (f r.after 18) = flag (popping kind code) ∧
  E values (f r.after 19) = flag (popping kind code && s.pending) ∧
  E values (CallRowCheck.argument r) = flag (argument s kind code) ∧
  E values (f r.after 20) = flag (pushing kind code) ∧
  E values (f r.after 21) = flag (clearing kind code) ∧
  E values (f r.after 32) = flag (finishing kind code) ∧
  E values (f r.after 33) = flag (CallMode.ordinary code && decide (kind = .instructionEnd))

theorem masks {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : CallRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16)
    (ci : E values (f r.row 8) = (code : F)) (s : State) (image : Image values (ready r) s) :
    Masks values r s kind code := by
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have mode := CallMode.images matrix r checked values one satisfied code cb ci
  obtain ⟨_,_,t2,t3,_,_,t6,t7,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  change E values (f r.flags 2) = _ at t2
  change E values (f r.flags 3) = _ at t3
  change E values (f r.flags 6) = _ at t6
  change E values (f r.flags 7) = _ at t7
  have pending : E values (f r.after 14) = flag s.pending := image.2.2.1
  have pop := eqs.pop
  have index := eqs.indexPop
  have push := eqs.push
  have clear := eqs.clear
  have finish := eqs.finish
  have ordinary := eqs.ordinaryEnd
  rw [mode.1,t3] at pop
  rw [pop,pending] at index
  rw [mode.1,t2] at push
  rw [mode.1,t6] at clear
  rw [mode.1,t7] at finish
  rw [mode.2.2.2,t7] at ordinary
  have product (a b : Bool) : flag (F := F) a*flag b = flag (a && b) := by
    cases a <;> cases b <;> simp [flag,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul]
  have difference (a b : Bool) : flag (F := F) a-flag (a && b) = flag (a && !b) := by
    cases a <;> cases b <;> simp [flag] <;> grind only
  simp only [ControlEvents.selected,product] at pop index push clear finish ordinary
  refine ⟨pop,index,?_,push,clear,finish,ordinary⟩
  simp only [CallRowCheck.argument,eval_sub,pop,index]
  exact difference _ _

#print axioms initial_image
#print axioms masks
end ZkBuild.CallState
