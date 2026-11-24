import ControlTypeCertificate
set_option autoImplicit false
namespace ZkBuild.ControlTypeModes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def supported (code : Nat) := FrameOpcodes.opens code || FrameOpcodes.branches code || FrameOpcodes.closes code

theorem frame_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (frame : FrameRowCheck.Record)
    (checked : FrameRowCheck.check matrix frame=true) (values : Nat → F) (one : values 0=1)
    (row : Row) (image : ControlTypeCertificate.Images values r frame row) (j : Nat) :
    E values (f r.frame j)=E values (f (FrameRowCheck.descriptor frame++frame.after.take 9++
      [FrameRowCheck.opening frame,FrameRowCheck.branching frame,FrameRowCheck.closing frame,
       FrameRowCheck.opening frame++FrameRowCheck.branching frame++FrameRowCheck.closing frame,f frame.after 11]) j) := by
  have same := image.frame.trans (FrameRowImages.outputs matrix frame checked values)
  have zero : E values z=0 := by simpa only [z,Ring.intCast_zero] using eval_constant values one 0
  have point := congrArg (fun xs : List F => xs.getD j (E values z)) same
  simpa only [TokenInteger.map_getD,f,DeclarationMatrix.get] using point

structure Flags {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (code : Nat) : Prop where
  opcode : ∀ k, k<9 → E values (f r.frame (8+k))=flag (decide (code=FrameRowCheck.codes.getD k 0))
  opening : E values (f r.frame 17)=flag (FrameOpcodes.opens code)
  branching : E values (f r.frame 18)=flag (FrameOpcodes.branches code)
  closing : E values (f r.frame 19)=flag (FrameOpcodes.closes code)
  supported : E values (f r.frame 20)=flag (supported code)

theorem flags {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (frame : FrameRowCheck.Record)
    (checked : FrameRowCheck.check matrix frame=true) (values : Nat → F) (one : values 0=1)
    (satisfied : Satisfied matrix values) (row : Row) (code : Nat) (cb : code<2^16)
    (image : ControlTypeCertificate.Images values r frame row) (opcode : E values (f frame.row 8)=(code:F)) :
    Flags values r code := by
  have fields := frame_field matrix r frame checked values one row image
  have afterLength : frame.after.length=46 := (FrameRowImages.links matrix frame checked).2.2.2.2.1
  have selectors := FrameOpcodes.selectors matrix frame checked values one satisfied code cb opcode
  have categories := FrameOpcodes.categories matrix frame checked values one satisfied code cb opcode
  constructor
  · intro k kb
    rw [fields (8+k)]
    have split : f (FrameRowCheck.descriptor frame++frame.after.take 9++
        [FrameRowCheck.opening frame,FrameRowCheck.branching frame,FrameRowCheck.closing frame,
         FrameRowCheck.opening frame++FrameRowCheck.branching frame++FrameRowCheck.closing frame,f frame.after 11]) (8+k)=f frame.after k := by
      have choices : k=0 ∨ k=1 ∨ k=2 ∨ k=3 ∨ k=4 ∨ k=5 ∨ k=6 ∨ k=7 ∨ k=8 := by omega
      rcases choices with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
        simp [f,DeclarationMatrix.get,List.getD,FrameRowCheck.descriptor,List.getElem?_append,List.getElem?_take,afterLength]
    rw [split]
    exact selectors k kb
  all_goals
    first | rw [fields 17] | rw [fields 18] | rw [fields 19] | rw [fields 20]
    simp only [f,DeclarationMatrix.get,List.getD,FrameRowCheck.descriptor,List.getElem?_append,
      List.length_append,List.length_cons,List.length_nil,List.length_take,afterLength,
      Nat.min_eq_left (by decide : 9≤46)]
    first | exact categories.isOpening | exact categories.isBranching | exact categories.isClosing | exact categories.combined

#print axioms flags
end ZkBuild.ControlTypeModes
