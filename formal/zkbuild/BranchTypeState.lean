import BranchTypeData
import BranchTypePending
set_option autoImplicit false
namespace ZkBuild.BranchTypeState
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  length : Nat := 0
  arity : Nat := 0
  pops : Nat := 0
  pushes : Nat := 0
  seen : Bool := false
  last : Bool := false
  cleared : Nat := 0
  start : Nat := 0
  deriving Inhabited, DecidableEq

def mark (kind : Kind) (code : Nat) : Bool := decide (kind = .labelCheck ∧ code = 14)
def prepare (s : State) (kind : Kind) : State := if BranchTypePending.reset kind then {} else s
def select (s : State) (kind : Kind) (code index : Nat) (d : BranchTypeData.Data) : State :=
  if mark kind code then
    {length := d.size.val, arity := if s.seen then s.arity else d.size.val,
     pops := 0, pushes := 0, seen := true, last := d.terminal, cleared := s.cleared, start := index+1}
  else s
def advance (s : State) (kind : Kind) (code : Nat) (pending : Bool) : State :=
  {s with pops := s.pops+(BranchTypePending.selected kind .pop code && !pending).toNat
          pushes := s.pushes+(BranchTypePending.selected kind .push code).toNat
          cleared := s.cleared+(BranchTypePending.selected kind .clear code).toNat}

def Image {F : Type} [Field F] (values : Nat → F) (fields : Fields) (s : State) : Prop :=
  E values (f fields 0) = (s.length : F) ∧ E values (f fields 1) = (s.arity : F) ∧
  E values (f fields 2) = (s.pops : F) ∧ E values (f fields 3) = (s.pushes : F) ∧
  E values (f fields 4) = flag s.seen ∧ E values (f fields 5) = flag s.last ∧
  E values (f fields 6) = (s.cleared : F) ∧ E values (f fields 7) = (s.start : F)
def before (r : BranchTypeRowCheck.Record) : Fields := [1,2,3,4,6,7,8,9].map (f r.before)
def ready (r : BranchTypeRowCheck.Record) : Fields := [2,3,4,5,8,9,10,11].map (f r.after)
def chosen (r : BranchTypeRowCheck.Record) : Fields := [26,24,27,28,30,31,10,29].map (f r.after)
def after (r : BranchTypeRowCheck.Record) : Fields := [26,24,48,49,30,31,51,29].map (f r.after)

theorem field_zero (a : Linear) (rest : Fields) : f (a::rest) 0 = a := by simp [f,DeclarationMatrix.get]
theorem field_succ (a : Linear) (rest : Fields) (i : Nat) : f (a::rest) (i+1) = f rest i := by
  simp only [f,DeclarationMatrix.get,List.getD_cons_succ]

theorem ready_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : BranchTypeRowCheck.Record)
    (m : BranchTypeRowSound.Meaning values r) (kind : Kind) (code : Nat)
    (tags : BranchTypeCertificate.Tags values r kind code) (s : State)
    (image : Image values (before r) s) : Image values (ready r) (prepare s kind) := by
  have reset : E values (f r.flags 0++f r.flags 1) = flag (BranchTypePending.reset kind) := by
    have sum : E values (f r.flags 0++f r.flags 1) = E values (f r.flags 0)+E values (f r.flags 1) := eval_append values _ _
    rw [sum,tags.functionBegin,tags.instructionBegin]
    cases kind <;> simp [BranchTypePending.reset,flag] <;> grind only
  have eq (input output : Nat) (member : (f r.flags 0++f r.flags 1,z,f r.before input,output) ∈ selects r) :
      E values (f r.after output) = (if BranchTypePending.reset kind then 0 else E values (f r.before input)) := by
    have h := m.select _ _ _ _ member
    rw [reset] at h
    have z0 : E values z = 0 := by simp [z,eval_constant values one,Ring.intCast_zero]
    rw [z0] at h
    cases hreset : BranchTypePending.reset kind <;> simp only [hreset,flag,Bool.false_eq_true,ite_false,ite_true] at h ⊢ <;> grind only
  have e0 := eq 1 2 (by simp [selects])
  have e1 := eq 2 3 (by simp [selects])
  have e2 := eq 3 4 (by simp [selects])
  have e3 := eq 4 5 (by simp [selects])
  have e4 := eq 6 8 (by simp [selects])
  have e5 := eq 7 9 (by simp [selects])
  have e6 := eq 8 10 (by simp [selects])
  have e7 := eq 9 11 (by simp [selects])
  simp only [Image,before,List.map_cons,List.map_nil,field_succ,field_zero] at image
  simp only [Image,ready,List.map_cons,List.map_nil,field_succ,field_zero]
  rw [e0,e1,e2,e3,e4,e5,e6,e7]
  cases h : BranchTypePending.reset kind <;> simp [prepare,h,flag,Semiring.natCast_zero] <;> exact image

theorem chosen_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : BranchTypeRowCheck.Record)
    (m : BranchTypeRowSound.Meaning values r) (kind : Kind) (code : Nat)
    (tags : BranchTypeCertificate.Tags values r kind code) (s : State)
    (image : Image values (ready r) s) (d : BranchTypeData.Data) (di : BranchTypeData.Images values r d) :
    Image values (chosen r) (select s kind code r.index d) := by
  simp only [Image,ready,List.map_cons,List.map_nil,field_succ,field_zero] at image
  have first := m.multiply (f r.flags 9) (sub o (f r.after 8)) 23 (by simp [multiplies])
  simp only [tags.label,eval_sub,o,eval_constant values one,Ring.intCast_one,image.2.2.2.2.1] at first
  have e0 := m.select (f r.flags 9) r.size.value (f r.after 2) 26 (by simp [selects])
  have e1 := m.select (f r.after 23) r.size.value (f r.after 3) 24 (by simp [selects])
  have e2 := m.select (f r.flags 9) z (f r.after 4) 27 (by simp [selects])
  have e3 := m.select (f r.flags 9) z (f r.after 5) 28 (by simp [selects])
  have e4 := m.select (f r.flags 9) o (f r.after 8) 30 (by simp [selects])
  have e5 := m.select (f r.flags 9) r.terminal (f r.after 9) 31 (by simp [selects])
  have e7 := m.select (f r.flags 9) (n (r.index+1)) (f r.after 11) 29 (by simp [selects])
  simp only [Image,chosen,List.map_cons,List.map_nil,field_succ,field_zero]
  rw [e0,e1,e2,e3,e4,e5,e7,first,tags.label,di.1,di.2,image.1,image.2.1,image.2.2.1,image.2.2.2.1,
    image.2.2.2.2.1,image.2.2.2.2.2.1,image.2.2.2.2.2.2.1,image.2.2.2.2.2.2.2]
  have ni : E values (n (r.index+1)) = ((r.index+1 : Nat) : F) :=
    (eval_constant values one (Int.ofNat (r.index+1))).trans (Ring.intCast_natCast (r.index+1))
  rw [ni]
  simp only [z,o,eval_constant values one,Ring.intCast_zero,Ring.intCast_one]
  change _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _
  cases mk : mark kind code <;> cases sn : s.seen
  all_goals have dm := mk; unfold mark at dm
  all_goals simp only [select,mk,dm,flag,sn,Bool.false_eq_true,ite_false,ite_true,Semiring.natCast_zero] <;> grind only

theorem after_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : BranchTypeRowCheck.Record) (m : BranchTypeRowSound.Meaning values r)
    (kind : Kind) (code : Nat) (pending : Bool) (s : State)
    (masks : BranchTypePending.Masks values r kind code pending)
    (image : Image values (chosen r) s) : Image values (after r) (advance s kind code pending) := by
  have pops := m.equality (f r.after 27++argument r) 48 (by simp [equalities])
  have pushes := m.equality (f r.after 28++f r.after 34) 49 (by simp [equalities])
  have clear := m.equality (f r.after 10++f r.after 35) 51 (by simp [equalities])
  simp only [eval_append,masks.argument,masks.push,masks.clear] at pops pushes clear
  simp only [Image,chosen,List.map_cons,List.map_nil,field_succ,field_zero] at image
  simp only [Image,after,advance,List.map_cons,List.map_nil,field_succ,field_zero,
    pops,pushes,clear,Semiring.natCast_add,OperandMemorySound.flag_nat]
  simp only [E,OperandMemorySound.flag_nat] at image ⊢
  constructor; exact image.1
  constructor; exact image.2.1
  constructor; rw [image.2.2.1]
  constructor; rw [image.2.2.2.1]
  constructor; exact image.2.2.2.2.1
  constructor; exact image.2.2.2.2.2.1
  constructor; rw [image.2.2.2.2.2.2.1]
  exact image.2.2.2.2.2.2.2

#print axioms ready_image
#print axioms chosen_image
#print axioms after_image
end ZkBuild.BranchTypeState
