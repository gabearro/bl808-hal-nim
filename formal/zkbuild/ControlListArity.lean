import ControlMemberSource
import ControlActionSequence
set_option autoImplicit false
namespace ZkBuild.ControlListArity
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def resultMode (code token : Nat) :=
  (decide (code=11) && !(decide (token/4%4=1))) || (decide (code=13) && !(decide (token%4=1)))
def outputCount (code token : Nat) (params results : List Nat) :=
  (ControlMemberSource.outputMode code token).toNat*params.length+(resultMode code token).toNat*results.length

theorem flag_not {F : Type} [Field F] (b : Bool) : 1-flag (F:=F) b=flag (!b) := by
  cases b <;> simp [flag] <;> grind only

theorem result_flags {F : Type} [Field F] (code token : Nat) :
    flag (F:=F) (decide (code=11))*flag (!(decide (token/4%4=1)))+
      flag (F:=F) (decide (code=13))*flag (!(decide (token%4=1)))=flag (resultMode code token) := by
  by_cases a : code=11
  · subst code; simp [resultMode,flag,Semiring.one_mul,Semiring.zero_mul,AddCommMonoid.add_zero]
  by_cases b : code=13
  · subst code; simp [resultMode,flag,Semiring.one_mul,Semiring.zero_mul,AddCommMonoid.zero_add]
  simp [resultMode,a,b,flag,Semiring.zero_mul,AddCommMonoid.zero_add]

theorem lengths {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (ph rh : Fin (2^32)) (params results : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (code token : Nat) (modes : ControlTypeModes.Flags values row code)
    (image : ControlFrameMetadata.Image values row token) :
    E values (f row.after 23)=((ControlMemberSource.inputTypes code token params results).length:F) ∧
    E values (ControlTypeRowCheck.outputLength row)=(outputCount code token params results:F) := by
  have m := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have selected := ControlMemberRouting.selectors matrix row checked values one satisfied code modes token image
  have loop := ControlTypeScalar.indicator values one row m _ (token%4) 1 19
    (by have := Nat.mod_lt token (by decide : 0<4); omega) (by decide) image.kind (by simp [ControlTypeRowCheck.zeros,n,o])
  have ending := modes.opcode 4 (by decide)
  have branch := modes.opcode 7 (by decide)
  change E values (f row.frame 12)=flag (decide (code=11)) at ending
  change E values (f row.frame 15)=flag (decide (code=13)) at branch
  have endOut := m.multiply (f row.frame 12) (sub o (f row.frame 5)) 25 (by simp [ControlTypeRowCheck.multiplies])
  have branchOut := m.multiply (f row.frame 15) (sub o (f row.after 19)) 26 (by simp [ControlTypeRowCheck.multiplies])
  have paramOut := m.multiply (ControlTypeRowCheck.parameterOutput row) (f row.after 11) 27 (by simp [ControlTypeRowCheck.multiplies])
  have resultOut := m.multiply (f row.after 25++f row.after 26) (f row.after 12) 28 (by simp [ControlTypeRowCheck.multiplies])
  have input := m.select (ControlTypeRowCheck.parameterInput row) (f row.after 11) (f row.after 12) 23 (by simp [ControlTypeRowCheck.selects])
  have pl := lists.2.2.1
  have rl := lists.2.2.2.1
  constructor
  · simp only [selected.1,pl,rl] at input
    unfold ControlMemberSource.inputTypes ControlMemberSource.inputMode
    cases h : ControlMemberRouting.inputParams code (decide (token%4=1)) <;>
      simp only [h,flag,Bool.false_eq_true,ite_false,ite_true] at input ⊢ <;> grind only
  · simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,ending,branch,image.function,loop,flag_not] at endOut branchOut
    have resultFlags : E values (f row.after 25++f row.after 26)=flag (resultMode code token) := by
      simpa only [eval_append,endOut,branchOut] using result_flags (F:=F) code token
    simp only [resultFlags,selected.2,pl,rl] at paramOut resultOut
    simp only [ControlTypeRowCheck.outputLength,eval_append,paramOut,resultOut,outputCount,
      Semiring.natCast_add,Semiring.natCast_mul,ControlPlans.flag_cast,ControlMemberSource.outputMode]
    rfl

theorem output_bound (code token : Nat) (params results : List Nat)
    (pb : params.length<2^32) (rb : results.length<2^32) : outputCount code token params results<2^64 := by
  unfold outputCount
  cases ControlMemberSource.outputMode code token <;> cases resultMode code token <;> simp only [Bool.toNat_false,Bool.toNat_true,Nat.zero_mul,Nat.one_mul] <;> omega

theorem finish {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (ph rh : Fin (2^32)) (params results : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (code token : Nat) (modes : ControlTypeModes.Flags values row code)
    (image : ControlFrameMetadata.Image values row token) (s : ControlTypeState.State)
    (bound : ControlTypeGuards.Bounded s) (terminal : ControlTypeGuards.Finish values row s code) :
    s.args=(ControlMemberSource.inputTypes code token params results).length ∧
    s.pushes=outputCount code token params results := by
  have sizes := lengths matrix row checked values one satisfied tables indexed ph rh params results lists code token modes image
  have ib : (ControlMemberSource.inputTypes code token params results).length<2^64 := by
    have p := lists.2.2.2.2.1
    have r := lists.2.2.2.2.2.1
    unfold ControlMemberSource.inputTypes
    split <;> omega
  exact ⟨DeclarationLocations.natural_equal (F:=F) _ _ bound.1 ib (terminal.1.symm.trans sizes.1),
    DeclarationLocations.natural_equal (F:=F) _ _ bound.2.1 (output_bound code token params results lists.2.2.2.2.1 lists.2.2.2.2.2.1)
      (terminal.2.1.symm.trans sizes.2)⟩

theorem implicit_else {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (ph rh : Fin (2^32)) (params results : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (active : E values (f row.after 47)=1) : params.length=results.length := by
  have eq := ControlTypeScalar.implicit_else_lengths matrix row checked values one satisfied active
  exact DeclarationLocations.natural_equal (F:=F) _ _ (by have := lists.2.2.2.2.1; omega)
    (by have := lists.2.2.2.2.2.1; omega) (lists.2.2.1.symm.trans (eq.trans lists.2.2.2.1))

#print axioms flag_not
#print axioms result_flags
#print axioms lengths
#print axioms output_bound
#print axioms finish
#print axioms implicit_else
end ZkBuild.ControlListArity
