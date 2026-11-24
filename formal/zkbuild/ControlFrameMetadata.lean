import ControlTypeModes
import ControlTypeScalar
set_option autoImplicit false
namespace ZkBuild.ControlFrameMetadata
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Image {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (token : Nat) : Prop where
  kind : E values (f r.frame 1)=((token%4:Nat):F)
  index : E values (f r.frame 3)=((token/16:Nat):F)
  typed : E values (f r.frame 4)=flag (decide (token/4%4=0))
  function : E values (f r.frame 5)=flag (decide (token/4%4=1))
  empty : E values (f r.frame 6)=flag (decide (token/4%4=2))
  singleton : E values (f r.frame 7)=flag (decide (token/4%4=3))

theorem image {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (frame : FrameRowCheck.Record)
    (checked : FrameRowCheck.check matrix frame=true) (values : Nat → F) (one : values 0=1)
    (row : Row) (linked : ControlTypeCertificate.Images values r frame row) (token : Nat)
    (source : FrameDescriptor.Image values frame token) : Image values r token := by
  have point := ControlTypeModes.frame_field matrix r frame checked values one row linked
  constructor
  all_goals
    first | rw [point 1] | rw [point 3] | rw [point 4] | rw [point 5] | rw [point 6] | rw [point 7]
    simp only [FrameRowCheck.descriptor,List.cons_append,List.nil_append,f,DeclarationMatrix.get,
      List.getD_cons_succ,List.getD_cons_zero]
    first | exact source.kind | exact source.index | exact source.typed | exact source.function | exact source.empty | exact source.singleton

theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (source : Image values r token)
    (lookup : E values (ControlTypeRowCheck.lookup r)=1) (mode : token/4%4=0 ∨ token/4%4=1) :
    E values r.metadata.active=1 ∧
      E values r.metadata.address=((2*(token/16)+(decide (token/4%4=0)).toNat:Nat):F) := by
  have facts := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have active := facts.multiply (ControlTypeRowCheck.lookup r) (f r.frame 4++f r.frame 5) 1 (by simp [ControlTypeRowCheck.multiplies])
  have address := facts.multiply (f r.after 1) (scale (f r.frame 3) 2++f r.frame 4) 2 (by simp [ControlTypeRowCheck.multiplies])
  have interface := ControlTypeRowImages.interface matrix r checked values
  simp only [eval_append,eval_scale,source.typed,source.function,source.index,lookup] at active address
  rcases mode with mode | mode
  all_goals
    simp [mode,flag] at active address ⊢
    constructor
    · exact interface.metadataActive.trans (by grind only)
    · rw [interface.metadataAddress,address,active]
      simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2]
      grind only

theorem simple {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (source : Image values r token)
    (lookup : E values (ControlTypeRowCheck.lookup r)=1) :
    E values r.singleton.active=flag (decide (token/4%4=3)) ∧
      E values r.singleton.address=(if token/4%4=3 then ((token/16:Nat):F) else 0) ∧
      (token/4%4=2 ∨ token/4%4=3 → E values r.metadata.active=0) := by
  have facts := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have active := facts.multiply (ControlTypeRowCheck.lookup r) (f r.frame 7) 3 (by simp [ControlTypeRowCheck.multiplies])
  have address := facts.multiply (f r.after 3) (f r.frame 3) 4 (by simp [ControlTypeRowCheck.multiplies])
  have metadata :=  facts.multiply (ControlTypeRowCheck.lookup r) (f r.frame 4++f r.frame 5) 1 (by simp [ControlTypeRowCheck.multiplies])
  have face := ControlTypeRowImages.interface matrix r checked values
  refine ⟨?_,?_,?_⟩
  · rw [face.singletonActive,active,lookup,source.singleton]; grind only
  · rw [face.singletonAddress,address,active,lookup,source.singleton,source.index]
    by_cases h : token/4%4=3 <;> simp [h,flag] <;> grind only
  · intro mode
    simp only [face.metadataActive,metadata,lookup,eval_append,source.typed,source.function]
    rcases mode with mode | mode <;> simp [mode,flag] <;> grind only

theorem reset_heads {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (source : Image values r token) (reset : E values (ControlTypeRowCheck.reset r)=1) :
    E values (f r.after 7)=(if token/4%4=0 then E values r.heads.low else 0) ∧
      E values (f r.after 8)=E values r.heads.high+E values r.singleton.value := by
  have facts := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have p := facts.multiply (f r.frame 4) r.heads.low 6 (by simp [ControlTypeRowCheck.multiplies])
  have ph := facts.select (ControlTypeRowCheck.reset r) (f r.after 6) (f r.before 0) 7 (by simp [ControlTypeRowCheck.selects])
  have rh := facts.select (ControlTypeRowCheck.reset r) (r.heads.high++r.singleton.value) (f r.before 1) 8 (by simp [ControlTypeRowCheck.selects])
  simp only [reset,p,source.typed,eval_append] at ph rh
  constructor
  · by_cases typed : token/4%4=0 <;> simp [typed,flag] at ph ⊢ <;> grind only
  · grind only

theorem zero_heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (zero : E values r.metadata.value=0) : E values r.heads.low=0 ∧ E values r.heads.high=0 := by
  obtain ⟨params,results,pi,ri,packed⟩ := ControlTypeRowImages.heads matrix r checked values one satisfied
  have sum := DeclarationLocations.natural_equal (F:=F) (params.val+2^32*results.val) 0
    (by have := params.isLt; have := results.isLt; omega) (by decide)
    (packed.symm.trans (by simpa only [Semiring.natCast_zero] using zero))
  have p : params.val=0 := by omega
  have r : results.val=0 := by omega
  simpa only [p,r,Semiring.natCast_zero] using And.intro pi ri

#print axioms image
#print axioms query
#print axioms simple
#print axioms reset_heads
#print axioms zero_heads
end ZkBuild.ControlFrameMetadata
