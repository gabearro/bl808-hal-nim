import BranchTypeCertificate
import FrameDescriptor
import BranchTypeScalar
set_option autoImplicit false
namespace ZkBuild.BranchFrameMetadata
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

/-- Branch typing consumes the descriptor of the same checked frame row. -/
theorem descriptor {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (linked : BranchTypeCertificate.linked events r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : FrameRowCheck.check matrix (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)=true)
    (values : Nat → F) (k : Nat) (kb : k<8) :
    E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).frame k)=
      E values (f (FrameRowCheck.descriptor (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)) k) := by
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp linked).2 i (List.mem_range.mpr ib))
  have same := VariableSelectorCheck.point values _ _ matched.2.2.2.2.2 k
  have out := congrArg (fun xs : List F => xs.getD k (E values z)) (FrameRowImages.outputs matrix _ checked values)
  rw [TokenInteger.map_getD,TokenInteger.map_getD] at out
  have short : k < (FrameRowCheck.descriptor (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)).length := by
    simpa only [FrameRowCheck.descriptor,List.length_cons,List.length_nil] using kb
  have pick : f (FrameRowCheck.descriptor (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) ++
      (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after.take 9 ++
      [FrameRowCheck.opening (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i),
       FrameRowCheck.branching (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i),
       FrameRowCheck.closing (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i),
       FrameRowCheck.opening (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) ++
         FrameRowCheck.branching (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) ++
         FrameRowCheck.closing (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i),
       f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 11]) k =
      f (FrameRowCheck.descriptor (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)) k := by
    simp only [List.append_assoc,f,DeclarationMatrix.get,List.getD,List.getElem?_append,short,ite_true]
  simp only [f,DeclarationMatrix.get] at pick out
  rw [pick] at out
  exact same.trans out

structure Image {F : Type} [Field F] (values : Nat → F) (r : BranchTypeRowCheck.Record) (token : Nat) : Prop where
  kind : E values (f r.frame 1)=((token%4:Nat):F)
  index : E values (f r.frame 3)=((token/16:Nat):F)
  typed : E values (f r.frame 4)=flag (decide (token/4%4=0))
  function : E values (f r.frame 5)=flag (decide (token/4%4=1))
  empty : E values (f r.frame 6)=flag (decide (token/4%4=2))
  singleton : E values (f r.frame 7)=flag (decide (token/4%4=3))

theorem image {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (linked : BranchTypeCertificate.linked events r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : FrameRowCheck.check matrix (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)=true)
    (values : Nat → F) (token : Nat)
    (src : FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token) :
    Image values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) token := by
  have point := descriptor matrix splits events r linked i ib checked values
  exact ⟨(point 1 (by decide)).trans src.kind,(point 3 (by decide)).trans src.index,
    (point 4 (by decide)).trans src.typed,(point 5 (by decide)).trans src.function,
    (point 6 (by decide)).trans src.empty,(point 7 (by decide)).trans src.singleton⟩

/-- Typed blocks and function roots select the source signature namespace.
    Empty and singleton blocks use the other descriptor modes. -/
theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (src : Image values r token)
    (label : E values (f r.flags 9)=1) (mode : token/4%4=0 ∨ token/4%4=1) :
    E values r.metadata.active=1 ∧
    E values r.metadata.address=((2*(token/16)+(decide (token/4%4=0)).toNat:Nat):F) := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have active := facts.multiply (f r.flags 9) (f r.frame 4++f r.frame 5) 14 (by simp [BranchTypeRowCheck.multiplies])
  have address := facts.multiply (f r.after 14) (scale (f r.frame 3) 2++f r.frame 4) 15 (by simp [BranchTypeRowCheck.multiplies])
  have interface := BranchTypeRowImages.interface matrix r checked values
  have ma := interface.metadataActive
  have mk := interface.metadataAddress
  simp only [E] at ma mk
  simp only [E] at active address label src interface
  simp only [eval_append,eval_scale,src.typed,src.function,src.index,label] at active address
  rcases mode with mode | mode
  all_goals
    simp only [E] at ⊢
    simp [mode,flag] at active address ⊢
    constructor
    · exact ma.trans (by grind only)
    · rw [mk,address,active]
      simp only [Semiring.natCast_add,Semiring.natCast_mul,
        Semiring.natCast_one,Semiring.natCast_eq_ofNat 2]
      grind only

def head (token params results : Nat) : Nat :=
  if token%4=1 then (if token/4%4=0 then params else 0) else results

/-- A loop label uses the type's parameter list; other labels use results. -/
theorem label_head {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token params results : Nat) (src : Image values r token)
    (label : E values (f r.flags 9)=1) (mode : token/4%4=0 ∨ token/4%4=1)
    (pi : E values r.heads.low=(params:F)) (ri : E values r.heads.high=(results:F))
    (singletonZero : E values r.singleton.value=0) :
    E values r.size.address=(head token params results:F) := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have loop := BranchTypeScalar.indicator values one r facts (f r.frame 1) (token%4) 1 19
    (by have := Nat.mod_lt token (by decide : 0<4); omega) (by decide) src.kind
    (by simp [BranchTypeRowCheck.zeros,n,o])
  have param := facts.multiply (f r.frame 4) r.heads.low 20 (by simp [BranchTypeRowCheck.multiplies])
  have chosen := facts.select (f r.after 19) (f r.after 20) (r.heads.high++r.singleton.value) 21 (by simp [BranchTypeRowCheck.selects])
  have address := facts.multiply (f r.flags 9) (f r.after 21) 22 (by simp [BranchTypeRowCheck.multiplies])
  have outer := (BranchTypeRowImages.interface matrix r checked values).sizeAddress
  simp only [E] at outer address chosen param loop pi ri singletonZero label ⊢
  have typed := src.typed
  simp only [E] at typed
  rw [outer,address,label,chosen,loop,param,typed,pi,eval_append,ri,singletonZero]
  rcases mode with mode | mode
  all_goals
    by_cases isLoop : token%4=1
    all_goals
      simp only [head,isLoop,mode,flag,decide_true,ite_true,ite_false]
      try simp
      try grind only

#print axioms label_head
#print axioms descriptor
#print axioms image
#print axioms query
end ZkBuild.BranchFrameMetadata
