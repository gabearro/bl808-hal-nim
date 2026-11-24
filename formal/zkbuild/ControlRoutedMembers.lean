import ControlMemberPositions
set_option autoImplicit false
namespace ZkBuild.ControlRoutedMembers
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem input {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : ControlTypeRowCheck.Record) (parameters : Bool)
    (ph rh head found : Fin (2^32)) (params results tags : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (member : ControlMemberLists.Image values tables indexed row false head found tags)
    (s : ControlTypeState.State) (state : ControlTypeState.Image values (ControlTypeState.ready row) s)
    (bound : s.args<2^32)
    (routing : E values (f row.after 41)=(if parameters then E values (f row.after 7) else E values (f row.after 8)) ∧
      E values (f row.after 42)=(if parameters then E values (f row.after 13) else E values (f row.after 12)-1-E values (f row.after 13))) :
    ControlMemberPositions.Image values row false (!parameters) (if parameters then params else results) s.args := by
  obtain ⟨pi,ri,pl,rl,pb,rb,pr,rr⟩ := lists
  have args := state.args
  change E values (f row.after 13)=(s.args:F) at args
  cases parameters
  case false =>
    simp only [Bool.false_eq_true,ite_false,args,rl] at routing
    exact ControlMemberPositions.selected values tables indexed row false true head found rh tags results s.args
      member rr rb bound (routing.1.trans ri) routing.2
  case true =>
    simp only [ite_true,args] at routing
    exact ControlMemberPositions.selected values tables indexed row false false head found ph tags params s.args
      member pr pb bound (routing.1.trans pi) routing.2

theorem output {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : ControlTypeRowCheck.Record) (parameters : Bool)
    (ph rh head found : Fin (2^32)) (params results tags : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (member : ControlMemberLists.Image values tables indexed row false head found tags)
    (s : ControlTypeState.State) (state : ControlTypeState.Image values (ControlTypeState.ready row) s)
    (bound : s.pushes<2^32)
    (routing : E values (f row.after 41)=(if parameters then E values (f row.after 7) else E values (f row.after 8)) ∧
      E values (f row.after 42)=(if parameters then E values (f row.after 11)-1-E values (f row.after 14) else E values (f row.after 14))) :
    ControlMemberPositions.Image values row false parameters (if parameters then params else results) s.pushes := by
  obtain ⟨pi,ri,pl,rl,pb,rb,pr,rr⟩ := lists
  have pushes := state.pushes
  change E values (f row.after 14)=(s.pushes:F) at pushes
  cases parameters
  case false =>
    simp only [Bool.false_eq_true,ite_false,pushes] at routing
    exact ControlMemberPositions.selected values tables indexed row false false head found rh tags results s.pushes
      member rr rb bound (routing.1.trans ri) routing.2
  case true =>
    simp only [ite_true,pushes,pl] at routing
    exact ControlMemberPositions.selected values tables indexed row false true head found ph tags params s.pushes
      member pr pb bound (routing.1.trans pi) routing.2

theorem comparison {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : ControlTypeRowCheck.Record) (ph rh head found : Fin (2^32)) (params results tags : List Nat)
    (lists : ControlLengthLists.Image values tables indexed row ph rh params results)
    (member : ControlMemberLists.Image values tables indexed row true head found tags)
    (s : ControlTypeState.State) (state : ControlTypeState.Image values (ControlTypeState.ready row) s)
    (bound : s.args<2^32)
    (routing : E values (f row.after 49)=E values (f row.after 7) ∧ E values (f row.after 50)=E values (f row.after 13)) :
    ControlMemberPositions.Image values row true false params s.args := by
  have args := state.args
  change E values (f row.after 13)=(s.args:F) at args
  exact ControlMemberPositions.selected values tables indexed row true false head found ph tags params s.args
    member lists.2.2.2.2.2.2.1 lists.2.2.2.2.1 bound (routing.1.trans lists.1) (routing.2.trans args)

theorem input_type {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (actualImage : E values (f row.row 4)=(actual.val:F))
    (tags : List Nat) (reverse : Bool) (offset : Nat)
    (selected : ControlMemberPositions.Image values row false reverse tags offset)
    (active : E values (ControlTypeRowCheck.argument row)=1) :
    CallEvents.InputOk (tags.getD (ControlMemberPositions.index reverse tags.length offset) 0) actual.val := by
  obtain ⟨expected,ei,_,guard⟩ := ControlTypeScalar.type_guards matrix row checked values one satisfied actual actualImage
  have same := DeclarationLocations.natural_equal (F:=F) expected.val (tags.getD (ControlMemberPositions.index reverse tags.length offset) 0)
    (by have := expected.isLt; omega) (by have := selected.2.1; omega) (ei.symm.trans selected.2.2)
  simpa only [same] using guard active

theorem output_type {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (row : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix row=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (actualImage : E values (f row.row 4)=(actual.val:F))
    (tags : List Nat) (reverse : Bool) (offset : Nat)
    (selected : ControlMemberPositions.Image values row false reverse tags offset)
    (active : E values (f row.after 32)=1) :
    actual.val=tags.getD (ControlMemberPositions.index reverse tags.length offset) 0 := by
  have ai := ControlTypeScalar.output_type matrix row checked values one satisfied actual actualImage active
  exact DeclarationLocations.natural_equal (F:=F) actual.val (tags.getD (ControlMemberPositions.index reverse tags.length offset) 0)
    (by have := actual.isLt; omega) (by have := selected.2.1; omega) (ai.symm.trans selected.2.2)

#print axioms input
#print axioms output
#print axioms comparison
#print axioms input_type
#print axioms output_type
end ZkBuild.ControlRoutedMembers
