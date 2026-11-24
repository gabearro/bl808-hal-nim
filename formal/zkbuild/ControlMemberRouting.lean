import ControlHeldLists
set_option autoImplicit false
namespace ZkBuild.ControlMemberRouting
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def inputParams (code : Nat) (loop : Bool) := FrameOpcodes.opens code || (FrameOpcodes.branches code && loop)
def outputParams (code : Nat) (loop : Bool) := FrameOpcodes.opens code || decide (code=5) || (decide (code=13) && loop)

theorem flag_modes {F : Type} [Field F] (code : Nat) (loop : Bool) :
    flag (F:=F) (FrameOpcodes.opens code)+flag (FrameOpcodes.branches code)*flag loop=flag (inputParams code loop) ∧
    flag (F:=F) (FrameOpcodes.opens code)+flag (decide (code=5))+flag (decide (code=13))*flag loop=flag (outputParams code loop) := by
  by_cases c2 : code=2
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  by_cases c3 : code=3
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  by_cases c4 : code=4
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  by_cases c31 : code=31
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  by_cases c5 : code=5
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  by_cases c13 : code=13
  · subst code; cases loop <;> simp [inputParams,outputParams,FrameOpcodes.opens,FrameOpcodes.branches,flag] <;> grind only
  have opens : FrameOpcodes.opens code=false := by simp [FrameOpcodes.opens,c2,c3,c4,c31]
  simp only [inputParams,outputParams,opens,c5,c13,decide_false,Bool.false_or,Bool.false_and,Bool.or_false,flag,
    Bool.false_eq_true,ite_false,AddCommMonoid.zero_add,Semiring.zero_mul]
  cases FrameOpcodes.branches code <;> cases loop <;> simp [flag] <;> grind only

theorem selectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (code : Nat) (modes : ControlTypeModes.Flags values row code) (token : Nat)
    (image : ControlFrameMetadata.Image values row token) :
    E values (ControlTypeRowCheck.parameterInput row)=flag (inputParams code (decide (token%4=1))) ∧
    E values (ControlTypeRowCheck.parameterOutput row)=flag (outputParams code (decide (token%4=1))) := by
  have m := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have loop := ControlTypeScalar.indicator values one row m _ (token%4) 1 19
    (by have := Nat.mod_lt token (by decide : 0<4); omega) (by decide) image.kind
    (by simp [ControlTypeRowCheck.zeros,n,o])
  have pi := m.multiply (f row.frame 18) (f row.after 19) 21 (by simp [ControlTypeRowCheck.multiplies])
  have po := m.multiply (f row.frame 15) (f row.after 19) 24 (by simp [ControlTypeRowCheck.multiplies])
  have e := modes.opcode 3 (by decide)
  have b := modes.opcode 7 (by decide)
  change E values (f row.frame 11)=flag (decide (code=5)) at e
  change E values (f row.frame 15)=flag (decide (code=13)) at b
  simpa only [ControlTypeRowCheck.parameterInput,ControlTypeRowCheck.parameterOutput,eval_append,
    pi,po,loop,modes.opening,modes.branching,e,b] using flag_modes (F:=F) code (decide (token%4=1))

theorem input {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (one : values 0=1) (row : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values row)
    (parameters : Bool) (mode : E values (ControlTypeRowCheck.parameterInput row)=flag parameters)
    (argument : E values (ControlTypeRowCheck.argument row)=1) (noPush : E values (f row.after 32)=0) :
    E values (f row.after 41)=(if parameters then E values (f row.after 7) else E values (f row.after 8)) ∧
    E values (f row.after 42)=(if parameters then E values (f row.after 13) else E values (f row.after 12)-1-E values (f row.after 13)) := by
  have chosen := m.select (ControlTypeRowCheck.parameterInput row) (f row.after 7) (f row.after 8) 22 (by simp [ControlTypeRowCheck.selects])
  have ordinal := m.select (ControlTypeRowCheck.parameterInput row) (f row.after 13) (sub (sub (f row.after 12) o) (f row.after 13)) 35 (by simp [ControlTypeRowCheck.selects])
  have ah := m.multiply (ControlTypeRowCheck.argument row) (f row.after 22) 37 (by simp [ControlTypeRowCheck.multiplies])
  have ph := m.multiply (f row.after 32) (f row.after 29) 38 (by simp [ControlTypeRowCheck.multiplies])
  have ao := m.multiply (ControlTypeRowCheck.argument row) (f row.after 35) 39 (by simp [ControlTypeRowCheck.multiplies])
  have po := m.multiply (f row.after 32) (f row.after 36) 40 (by simp [ControlTypeRowCheck.multiplies])
  have h := m.multiply (ControlTypeRowCheck.argument row++f row.after 32) (f row.after 37++f row.after 38) 41 (by simp [ControlTypeRowCheck.multiplies])
  have o := m.multiply (ControlTypeRowCheck.argument row++f row.after 32) (f row.after 39++f row.after 40) 42 (by simp [ControlTypeRowCheck.multiplies])
  simp only [eval_append,argument,noPush,Semiring.one_mul,Semiring.zero_mul,AddCommMonoid.add_zero,ah,ph,ao,po] at h o
  simp only [mode,eval_sub,DeclarationMatrix.o,eval_constant values one,Ring.intCast_one] at chosen ordinal
  cases parameters <;> simp only [flag,Bool.false_eq_true,ite_false,ite_true] at chosen ordinal ⊢
  all_goals constructor <;> grind only

theorem output {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (one : values 0=1) (row : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values row)
    (parameters : Bool) (mode : E values (ControlTypeRowCheck.parameterOutput row)=flag parameters)
    (noArgument : E values (ControlTypeRowCheck.argument row)=0) (push : E values (f row.after 32)=1) :
    E values (f row.after 41)=(if parameters then E values (f row.after 7) else E values (f row.after 8)) ∧
    E values (f row.after 42)=(if parameters then E values (f row.after 11)-1-E values (f row.after 14) else E values (f row.after 14)) := by
  have chosen := m.select (ControlTypeRowCheck.parameterOutput row) (f row.after 7) (f row.after 8) 29 (by simp [ControlTypeRowCheck.selects])
  have ordinal := m.select (ControlTypeRowCheck.parameterOutput row) (sub (sub (f row.after 11) o) (f row.after 14)) (f row.after 14) 36 (by simp [ControlTypeRowCheck.selects])
  have ah := m.multiply (ControlTypeRowCheck.argument row) (f row.after 22) 37 (by simp [ControlTypeRowCheck.multiplies])
  have ph := m.multiply (f row.after 32) (f row.after 29) 38 (by simp [ControlTypeRowCheck.multiplies])
  have ao := m.multiply (ControlTypeRowCheck.argument row) (f row.after 35) 39 (by simp [ControlTypeRowCheck.multiplies])
  have po := m.multiply (f row.after 32) (f row.after 36) 40 (by simp [ControlTypeRowCheck.multiplies])
  have h := m.multiply (ControlTypeRowCheck.argument row++f row.after 32) (f row.after 37++f row.after 38) 41 (by simp [ControlTypeRowCheck.multiplies])
  have o := m.multiply (ControlTypeRowCheck.argument row++f row.after 32) (f row.after 39++f row.after 40) 42 (by simp [ControlTypeRowCheck.multiplies])
  simp only [eval_append,noArgument,push,Semiring.one_mul,Semiring.zero_mul,AddCommMonoid.add_zero,AddCommMonoid.zero_add,ah,ph,ao,po] at h o
  simp only [mode,eval_sub,DeclarationMatrix.o,eval_constant values one,Ring.intCast_one] at chosen ordinal
  cases parameters <;> simp only [flag,Bool.false_eq_true,ite_false,ite_true] at chosen ordinal ⊢
  all_goals constructor <;> grind only

#print axioms flag_modes
#print axioms selectors
#print axioms input

theorem comparison {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (active : E values row.compare.active=1) :
    E values (f row.after 49)=E values (f row.after 7) ∧ E values (f row.after 50)=E values (f row.after 13) := by
  have m := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have enabled := (ControlTypeRowImages.interface matrix row checked values).compareActive.symm.trans active
  have h := m.multiply (f row.after 48) (f row.after 7) 49 (by simp [ControlTypeRowCheck.multiplies])
  have o := m.multiply (f row.after 48) (f row.after 13) 50 (by simp [ControlTypeRowCheck.multiplies])
  simpa only [enabled,Semiring.one_mul] using And.intro h o

theorem exclusive {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record)
    (kind : Kind) (code : Nat) (pending : Bool)
    (argument : E values (ControlTypeRowCheck.argument row)=flag (ControlTypeMasks.selected kind .pop code && !pending))
    (push : E values (f row.after 32)=flag (ControlTypeMasks.selected kind .push code)) :
    (E values (ControlTypeRowCheck.argument row)=1 → E values (f row.after 32)=0) ∧
    (E values (f row.after 32)=1 → E values (ControlTypeRowCheck.argument row)=0) := by
  cases kind <;> cases pending <;> cases h : ControlTypeModes.supported code <;>
    simp [ControlTypeMasks.selected,h,flag] at argument push ⊢ <;> grind only

def RowFacts {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record) (code token : Nat) : Prop :=
  (E values (ControlTypeRowCheck.parameterInput row)=flag (inputParams code (decide (token%4=1))) ∧
    E values (ControlTypeRowCheck.parameterOutput row)=flag (outputParams code (decide (token%4=1)))) ∧
  (E values (ControlTypeRowCheck.argument row)=1 →
    E values (f row.after 41)=(if inputParams code (decide (token%4=1)) then E values (f row.after 7) else E values (f row.after 8)) ∧
    E values (f row.after 42)=(if inputParams code (decide (token%4=1)) then E values (f row.after 13) else E values (f row.after 12)-1-E values (f row.after 13))) ∧
  (E values (f row.after 32)=1 →
    E values (f row.after 41)=(if outputParams code (decide (token%4=1)) then E values (f row.after 7) else E values (f row.after 8)) ∧
    E values (f row.after 42)=(if outputParams code (decide (token%4=1)) then E values (f row.after 11)-1-E values (f row.after 14) else E values (f row.after 14))) ∧
  (E values row.compare.active=1 →
    E values (f row.after 49)=E values (f row.after 7) ∧ E values (f row.after 50)=E values (f row.after 13))

def Complete {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ∃ token : Fin (2^36),
    FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
    RowFacts values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) (ops.getD i 0) token.val

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values splits r rows ops := by
  have state := ControlTypeTrace.sound matrix splits events r checked values one satisfied rows ops images schedule
  intro i ib
  have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
  have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
  have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
  obtain ⟨token,ti⟩ := FrameDescriptor.sound matrix _ rc.2.2.1 values one satisfied
  have frameImage := ControlFrameMetadata.image matrix _ _ rc.2.2.1 values one _ rc.2.1 token.val ti
  have modes := selectors matrix _ rc.1 values one satisfied _ masks.2.2 token.val frameImage
  have excludes := exclusive values _ _ _ _ (state i ib).2.2.2.2 masks.2.1.push
  exact ⟨token,ti,modes,
    fun active => input values one _ m _ modes.1 active (excludes.1 active),
    fun active => output values one _ m _ modes.2 (excludes.2 active) active,
    comparison matrix _ rc.1 values one satisfied⟩

#print axioms output
#print axioms comparison
#print axioms exclusive
#print axioms trace
end ZkBuild.ControlMemberRouting
