import BranchFrameMetadata
set_option autoImplicit false
namespace ZkBuild.BranchSimpleHeads
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem metadata_inactive {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (image : BranchFrameMetadata.Image values r token)
    (mode : token/4%4=2 ∨ token/4%4=3) : E values r.metadata.active=0 := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have active := facts.multiply (f r.flags 9) (f r.frame 4++f r.frame 5) 14 (by simp [BranchTypeRowCheck.multiplies])
  have same := (BranchTypeRowImages.interface matrix r checked values).metadataActive
  rw [same,active]
  simp only [eval_append,image.typed,image.function]
  rcases mode with mode | mode <;> simp [mode,flag] <;> grind only

theorem zero_heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (zero : E values r.metadata.value=0) : E values r.heads.low=0 ∧ E values r.heads.high=0 := by
  obtain ⟨params,results,pi,ri,packed⟩ := BranchTypeRowImages.heads matrix r checked values one satisfied
  have sum := DeclarationLocations.natural_equal (F:=F) (params.val+2^32*results.val) 0
    (by have := params.isLt; have := results.isLt; omega) (by decide)
    (packed.symm.trans (by simpa only [Semiring.natCast_zero] using zero))
  have p : params.val=0 := by omega
  have r : results.val=0 := by omega
  simpa only [p,r,Semiring.natCast_zero] using And.intro pi ri

theorem singleton_query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (image : BranchFrameMetadata.Image values r token) (label : E values (f r.flags 9)=1) :
    E values r.singleton.active=flag (decide (token/4%4=3)) ∧
      E values r.singleton.address=if token/4%4=3 then ((token/16:Nat):F) else 0 := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have active := facts.multiply (f r.flags 9) (f r.frame 7) 16 (by simp [BranchTypeRowCheck.multiplies])
  have address := facts.multiply (f r.after 16) (f r.frame 3) 17 (by simp [BranchTypeRowCheck.multiplies])
  have same := BranchTypeRowImages.interface matrix r checked values
  constructor
  · rw [same.singletonActive,active,label,image.singleton]; grind only
  · rw [same.singletonAddress,address,active,label,image.singleton,image.index]
    by_cases mode : token/4%4=3 <;> simp [mode,flag] <;> grind only

theorem label_head {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (image : BranchFrameMetadata.Image values r token) (label : E values (f r.flags 9)=1)
    (low : E values r.heads.low=0) (high : E values r.heads.high=0) :
    E values r.size.address=if token%4=1 then 0 else E values r.singleton.value := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have loop := BranchTypeScalar.indicator values one r facts (f r.frame 1) (token%4) 1 19
    (by have := Nat.mod_lt token (by decide : 0<4); omega) (by decide) image.kind
    (by simp [BranchTypeRowCheck.zeros,n,o])
  have param := facts.multiply (f r.frame 4) r.heads.low 20 (by simp [BranchTypeRowCheck.multiplies])
  have chosen := facts.select (f r.after 19) (f r.after 20) (r.heads.high++r.singleton.value) 21 (by simp [BranchTypeRowCheck.selects])
  have address := facts.multiply (f r.flags 9) (f r.after 21) 22 (by simp [BranchTypeRowCheck.multiplies])
  have outer := (BranchTypeRowImages.interface matrix r checked values).sizeAddress
  simp only [E] at outer address chosen param loop low high label ⊢
  rw [outer,address,label,chosen,loop,param,low,eval_append,high]
  by_cases isLoop : token%4=1 <;> simp [isLoop,flag] <;> grind only

#print axioms metadata_inactive
#print axioms zero_heads
#print axioms singleton_query
#print axioms label_head
end ZkBuild.BranchSimpleHeads
