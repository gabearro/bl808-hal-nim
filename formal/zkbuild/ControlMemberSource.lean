import ControlRoutedMembers
set_option autoImplicit false
namespace ZkBuild.ControlMemberSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Origin {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) (i : Nat) (params results : List Nat) : Prop :=
  (params=[] ∧ results=[]) ∨ ∃ j, j≤i ∧
    ControlLookupMask.active (rows.getD j default).kind (ops.getD j 0)=true ∧
    ∃ token : Fin (2^36),
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) token.val ∧
      ControlSignatureLists.Origin values body tables declaration indexed signature token params results ∧
      ∀ k, j<k → k≤i → ControlTypeMasks.reset (rows.getD k default).kind=false

def inputMode (code token : Nat) := ControlMemberRouting.inputParams code (decide (token%4=1))
def outputMode (code token : Nat) := ControlMemberRouting.outputParams code (decide (token%4=1))
def inputTypes (code token : Nat) (params results : List Nat) := if inputMode code token then params else results
def outputTypes (code token : Nat) (params results : List Nat) := if outputMode code token then params else results

def Input {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record)
    (code token : Nat) (params results : List Nat) (offset actual : Nat) : Prop :=
  ControlMemberPositions.Image values row false (!(inputMode code token)) (inputTypes code token params results) offset ∧
    CallEvents.InputOk ((inputTypes code token params results).getD
      (ControlMemberPositions.index (!(inputMode code token)) (inputTypes code token params results).length offset) 0) actual

def Output {F : Type} [Field F] (values : Nat → F) (row : ControlTypeRowCheck.Record)
    (code token : Nat) (params results : List Nat) (offset actual : Nat) : Prop :=
  ControlMemberPositions.Image values row false (outputMode code token) (outputTypes code token params results) offset ∧
    actual=(outputTypes code token params results).getD
      (ControlMemberPositions.index (outputMode code token) (outputTypes code token params results).length offset) 0

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ∃ token : Fin (2^36), ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
    let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
    let state := ControlTypeTrace.ready rows ops i
    FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
    ControlLengthLists.Image values tables indexed row ph rh params results ∧
    Origin values body tables declaration indexed signature r rows ops i params results ∧
    (E values (ControlTypeRowCheck.argument row)=1 → Input values row (ops.getD i 0) token.val params results state.args (rows.getD i default).valueType.val) ∧
    (E values (f row.after 32)=1 → Output values row (ops.getD i 0) token.val params results state.pushes (rows.getD i default).valueType.val) ∧
    (E values row.compare.active=1 → ControlMemberPositions.Image values row true false params state.args ∧
      E values row.comparison.low=E values row.payload.low)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (held : ControlHeldLists.Complete values body splits tables declaration indexed signature r rows ops)
    (members : ControlSignatureSemanticSound.Members values splits tables indexed r rows)
    (routing : ControlMemberRouting.Complete values splits r rows ops) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  have states := ControlTypeTrace.sound matrix splits events r checked values one satisfied rows ops images schedule
  have parts := checked
  simp only [ControlTypeCertificate.check,ControlTypeRowCheck.checkStage,ControlTypeCertificate.linked,
    Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size := images.1.trans parts.2.1.1
  have lengthBound : rows.length<2^32 := by rw [size]; exact parts.1.1.1.2.1
  intro i ib
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
  have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
  have face := ControlTypeRowImages.interface matrix row rc.1 values
  have state := (states i ib).2.1
  have bounded := ControlTypeTrace.prepare_bounds _ (rows.getD i default).kind (ops.getD i 0) i (ControlTypeTrace.bounds rows ops i)
  change ControlTypeTrace.Bounded (ControlTypeTrace.ready rows ops i) i at bounded
  have argBound : (ControlTypeTrace.ready rows ops i).args<2^32 := by have := bounded.1; omega
  have pushBound : (ControlTypeTrace.ready rows ops i).pushes<2^32 := by have := bounded.2.1; omega
  have excludes := ControlMemberRouting.exclusive values row _ _ _ (states i ib).2.2.2.2 masks.2.1.push
  obtain ⟨token,frame,routes⟩ := routing i ib
  have available : ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      ControlLengthLists.Image values tables indexed row ph rh params results ∧
      Origin values body tables declaration indexed signature r rows ops i params results := by
    rcases held i ib with empty | ⟨j,ji,active,originToken,ph,rh,params,results,originFrame,list,origin,between⟩
    · exact ⟨0,0,[],[],ControlMemberPositions.empty_lists values tables indexed row empty,Or.inl ⟨rfl,rfl⟩⟩
    · exact ⟨ph,rh,params,results,list,Or.inr ⟨j,ji,active,originToken,originFrame,origin,between⟩⟩
  obtain ⟨ph,rh,params,results,lists,origin⟩ := available
  refine ⟨token,ph,rh,params,results,frame,lists,origin,?_,?_,?_⟩
  · intro active
    have queryActive : E values (ControlLookupCheck.control r i (ControlMemberLists.family false)).active=1 := by
      change E values row.member.active=1
      simpa only [face.memberActive,eval_append,excludes.1 active,AddCommMonoid.add_zero] using active
    obtain ⟨head,found,tags,member⟩ := members i ib false queryActive
    have position := ControlRoutedMembers.input values tables indexed row _ ph rh head found params results tags lists member
      _ state argBound (routes.2.1 active)
    exact ⟨position,ControlRoutedMembers.input_type matrix row rc.1 values one satisfied _ rc.2.1.actual _ _ _ position active⟩
  · intro active
    have queryActive : E values (ControlLookupCheck.control r i (ControlMemberLists.family false)).active=1 := by
      change E values row.member.active=1
      simpa only [face.memberActive,eval_append,excludes.2 active,AddCommMonoid.zero_add] using active
    obtain ⟨head,found,tags,member⟩ := members i ib false queryActive
    have position := ControlRoutedMembers.output values tables indexed row _ ph rh head found params results tags lists member
      _ state pushBound (routes.2.2.1 active)
    exact ⟨position,ControlRoutedMembers.output_type matrix row rc.1 values one satisfied _ rc.2.1.actual _ _ _ position active⟩
  · intro active
    obtain ⟨head,found,tags,member⟩ := members i ib true active
    exact ⟨ControlRoutedMembers.comparison values tables indexed row ph rh head found params results tags lists member
      _ state argBound (routes.2.2.2 active),ControlTypeScalar.implicit_else_member matrix row rc.1 values one satisfied active⟩

#print axioms sound
end ZkBuild.ControlMemberSource
