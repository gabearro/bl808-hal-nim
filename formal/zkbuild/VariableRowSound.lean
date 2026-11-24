import VariableRowCheck
import InstructionCounts
import VariableEvents
set_option autoImplicit false
namespace ZkBuild.VariableRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : VariableRowCheck.Record) (checked : VariableRowCheck.check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (VariableRowCheck.gates r) :=
  OperandRowSound.includes_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

def Tags {F : Type} [Field F] (values : Nat → F) (r : VariableRowCheck.Record) (kind : OperandEvents.Kind) : Prop :=
  InstructionRowSound.Tags values ⟨[],r.flags,[],[],default,default,0,0,0,0⟩ kind

-- This bridge is independent of the environment lookup. Its rule expressions
-- are connected to the environment and opcode selectors separately.
structure RuleImage {F : Type} [Field F] (values : Nat → F) (r : VariableRowCheck.Record)
    (rule : StaticTyping.Rule) (pops : Nat) : Prop where
  present : E values (f r.selectors 13) = 1
  inputs : E values (VariableRowCheck.inputCount r) = (rule.inputs.length : F)
  outputs : E values (VariableRowCheck.outputCount r) = (StaticEvents.outputCount rule : F)
  outputType : E values (f r.after 2) = (rule.output.getD 0 : F)
  inputType : E values (f r.after 7) = (VariableEvents.inputType rule pops : F)

theorem gates {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : VariableRowCheck.Record) (checked : VariableRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind)
    (rule : StaticTyping.Rule) (actual : Fin 8) (pops pushes : Nat)
    (image : RuleImage values r rule pops)
    (actualImage : E values (f r.row 4) = (actual.val : F))
    (popImage : E values (f r.after 0) = (pops : F))
    (pushImage : E values (f r.after 1) = (pushes : F)) :
    VariableEvents.Gates (F := F) rule kind actual pops pushes := by
  have all := facts matrix r checked values satisfied
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a*E values b = 0 := by
    change E values a*E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have get (a b : Linear) (member : gate a b ∈ VariableRowCheck.gates r) := raw a b (all _ member)
  have multiplied (a b c : Linear) (member : mulGate a b c ∈ VariableRowCheck.gates r) : E values c = E values a*E values b := (all _ member).symm
  obtain ⟨_,_,t2,t3,t4,t5,t6,t7,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  have pop := multiplied (f r.selectors 13) (f r.flags 3) (f r.after 10) (by simp [VariableRowCheck.gates])
  have push := multiplied (f r.selectors 13) (f r.flags 2) (f r.after 11) (by simp [VariableRowCheck.gates])
  have finish := multiplied (f r.selectors 13) (f r.flags 7) (f r.after 12) (by simp [VariableRowCheck.gates])
  change E values (f r.flags 2) = _ at t2
  change E values (f r.flags 3) = _ at t3
  change E values (f r.flags 4) = _ at t4
  change E values (f r.flags 5) = _ at t5
  change E values (f r.flags 6) = _ at t6
  change E values (f r.flags 7) = _ at t7
  simp only [image.present,t2,t3,t7,Semiring.one_mul] at pop push finish
  have h0 := get (f r.after 10) (sub o (f r.after 8++f r.after 9)) (by simp [VariableRowCheck.gates])
  have h1 := get (f r.after 10) (f r.after 1) (by simp [VariableRowCheck.gates])
  have h2 := get (f r.after 11) (sub (f r.row 4) (f r.after 2)) (by simp [VariableRowCheck.gates])
  have h3 := get (f r.after 11) (sub o (VariableRowCheck.outputCount r)) (by simp [VariableRowCheck.gates])
  have h4 := get (f r.after 11) (sub (f r.after 0) (VariableRowCheck.inputCount r)) (by simp [VariableRowCheck.gates])
  have h5 := get (f r.after 11) (f r.after 1) (by simp [VariableRowCheck.gates])
  have h6 := get (f r.selectors 13) (f r.flags 4++f r.flags 5++f r.flags 6) (by simp [VariableRowCheck.gates])
  have h7 := get (f r.after 12) (sub (f r.after 0) (VariableRowCheck.inputCount r)) (by simp [VariableRowCheck.gates])
  have h8 := get (f r.after 12) (sub (f r.after 1) (VariableRowCheck.outputCount r)) (by simp [VariableRowCheck.gates])
  simp only [eval_sub,eval_append,o,eval_constant values one,Ring.intCast_one,pop,push,finish,
    image.present,image.inputs,image.outputs,image.outputType,actualImage,popImage,pushImage,t4,t5,t6,Semiring.one_mul]
    at h0 h1 h2 h3 h4 h5 h6 h7 h8
  refine ⟨?_,h1,h2,h3,h4,h5,h6,h7,h8⟩
  intro k
  have a := get (sub (f r.row 4) (f r.after 7)) (f r.after 8) (by simp [VariableRowCheck.gates,zeroGates,gate,z])
  have b := all (mulGate (sub (f r.row 4) (f r.after 7)) (f r.reciprocals 2) (sub o (f r.after 8)))
    (by simp [VariableRowCheck.gates,zeroGates,mulGate,o])
  have c := get (sub (f r.row 4) (n 7)) (f r.after 9) (by simp [VariableRowCheck.gates,zeroGates,gate,z])
  have d := all (mulGate (sub (f r.row 4) (n 7)) (f r.reciprocals 3) (sub o (f r.after 9)))
    (by simp [VariableRowCheck.gates,zeroGates,mulGate,o])
  change E values (sub (f r.row 4) (f r.after 7))*E values (f r.reciprocals 2) = E values (sub o (f r.after 8)) at b
  change E values (sub (f r.row 4) (n 7))*E values (f r.reciprocals 3) = E values (sub o (f r.after 9)) at d
  simp only [eval_sub,n,o,eval_constant values one,Ring.intCast_one,
    show ((Int.ofNat 7 : Int) : F) = 7 from Ring.intCast_ofNat 7,actualImage,image.inputType] at a b c d
  simp only [k,ControlEvents.selected,OperandEvents.flag,↓reduceIte,Semiring.one_mul] at h0
  exact ⟨E values (f r.after 8),E values (f r.after 9),E values (f r.reciprocals 2),E values (f r.reciprocals 3),
    a,b,c,d,by grind only⟩

theorem counts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : VariableRowCheck.Record) (checked : VariableRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind) (prior : InstructionCounts.Counts)
    (popImage : E values (f r.before 0) = (prior.pops : F))
    (pushImage : E values (f r.before 1) = (prior.pushes : F)) :
    E values (f r.after 0) = ((InstructionCounts.before prior kind).pops : F) ∧
    E values (f r.after 1) = ((InstructionCounts.before prior kind).pushes : F) ∧
    E values (f r.after 13) = ((InstructionCounts.next prior kind).pops : F) ∧
    E values (f r.after 14) = ((InstructionCounts.next prior kind).pushes : F) := by
  have all := facts matrix r checked values satisfied
  obtain ⟨t0,t1,t2,t3,_,_,_,_,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  have h0 := select_sound values (f r.flags 0++f r.flags 1) z (f r.before 0) (f r.after 0)
    (all _ (by simp [VariableRowCheck.gates]))
  have h1 := select_sound values (f r.flags 0++f r.flags 1) z (f r.before 1) (f r.after 1)
    (all _ (by simp [VariableRowCheck.gates]))
  have h2 := equality_sound values one (f r.after 13) (f r.after 0++f r.flags 3)
    (all _ (by simp [VariableRowCheck.gates]))
  have h3 := equality_sound values one (f r.after 14) (f r.after 1++f r.flags 2)
    (all _ (by simp [VariableRowCheck.gates]))
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  change E values (f r.flags 2) = _ at t2
  change E values (f r.flags 3) = _ at t3
  simp only [eval_append,z,eval_constant values one,Ring.intCast_zero,popImage,pushImage,t0,t1,t2,t3] at h0 h1 h2 h3
  cases k : kind <;> simp only [InstructionCounts.before,InstructionCounts.next,k,ControlEvents.selected,OperandEvents.flag,
    ↓reduceIte,decide_true,decide_false,Semiring.natCast_add,Semiring.natCast_zero,Semiring.natCast_one] at h0 h1 h2 h3 ⊢
  all_goals constructor <;> (repeat constructor) <;> grind only

#print axioms counts

#print axioms facts
#print axioms gates
end ZkBuild.VariableRowSound
