import ParametricBegin
set_option autoImplicit false
namespace ZkBuild.ParametricState
open Lean.Grind OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  declared : Nat := 0
  pops : Nat := 0
  pushes : Nat := 0
  first : Fin 8 := ⟨0,by decide⟩
  second : Fin 8 := ⟨0,by decide⟩
  deriving Inhabited

def prepare (s : State) (kind : Kind) (primary : Nat) : State :=
  if kind = .functionBegin ∨ kind = .instructionBegin then
    {declared := (ParametricEvents.typeForCode primary).getD 0}
  else s

def popping (kind : Kind) (code : Nat) := ParametricMode.active code && decide (kind = .pop)
def pushing (kind : Kind) (code : Nat) := ParametricMode.active code && decide (kind = .push)
def firstPop (s : State) (kind : Kind) (code : Nat) := popping kind code && decide (s.pops = 1)
def secondPop (s : State) (kind : Kind) (code : Nat) := popping kind code && decide (s.pops = 2)

def advance (s : State) (kind : Kind) (code : Nat) (actual : Fin 8) : State :=
  {s with pops := s.pops+(popping kind code).toNat
          pushes := s.pushes+(pushing kind code).toNat
          first := if firstPop s kind code then actual else s.first
          second := if secondPop s kind code then actual else s.second}

open CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix ParametricRowCheck

def Image {F : Type} [Field F] (values : Nat → F) (fields : Fields) (s : State) : Prop :=
  E values (f fields 0) = (s.declared : F) ∧ E values (f fields 1) = (s.pops : F) ∧
  E values (f fields 2) = (s.pushes : F) ∧ E values (f fields 3) = (s.first.val : F) ∧ E values (f fields 4) = (s.second.val : F)
def ready (r : ParametricRowCheck.Record) : Fields := [14,15,16,17,18].map (f r.after)
def after (r : ParametricRowCheck.Record) : Fields := [14,43,44,34,35].map (f r.after)

theorem initial_image {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (kind : Kind) (tags : ParametricRowSound.Tags values r kind)
    (s : State) (image : Image values r.before s) (primary : Fin (2^32)) (pi : E values r.primary = (primary.val : F)) :
    Image values (ready r) (prepare s kind primary.val) := by
  have ti := (ParametricMode.type_images values one r meaning primary pi).1
  obtain ⟨t0,t1,_⟩ := InstructionRowSound.selectors values _ kind tags
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  obtain ⟨d,p,q,a,b⟩ := image
  have h0 := meaning.select (f r.flags 0++f r.flags 1) (tag r) (f r.before 0) 14 (by simp [selects])
  have h1 := meaning.select (f r.flags 0++f r.flags 1) (z) (f r.before 1) 15 (by simp [selects])
  have h2 := meaning.select (f r.flags 0++f r.flags 1) (z) (f r.before 2) 16 (by simp [selects])
  have h3 := meaning.select (f r.flags 0++f r.flags 1) (z) (f r.before 3) 17 (by simp [selects])
  have h4 := meaning.select (f r.flags 0++f r.flags 1) (z) (f r.before 4) 18 (by simp [selects])
  simp only [eval_append,z,eval_constant values one,Ring.intCast_zero,ti,t0,t1,d,p,q,a,b] at h0 h1 h2 h3 h4
  simp only [Image,ready,List.map_cons,List.map_nil,f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ]
  change E values (f r.after 14) = _ ∧ E values (f r.after 15) = _ ∧ E values (f r.after 16) = _ ∧ E values (f r.after 17) = _ ∧ E values (f r.after 18) = _
  cases kind <;> simp [prepare,ControlEvents.selected,flag] at h0 h1 h2 h3 h4 ⊢ <;> grind only

#print axioms initial_image
end ZkBuild.ParametricState
