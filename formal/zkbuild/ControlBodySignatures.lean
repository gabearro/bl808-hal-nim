import ControlSignatureSpan
set_option autoImplicit false
namespace ZkBuild.ControlBodySignatures
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : ControlTypeRowCheck.Record) (ph rh qh sh : Fin (2^32)) (params results ps rs : List Nat)
    (left : ControlLengthLists.Image values tables indexed row ph rh params results)
    (right : ControlLengthLists.Image values tables indexed row qh sh ps rs) : params=ps ∧ results=rs := by
  exact ⟨(ControlSignatureLists.identify values _ _ ph qh params ps left.1 right.1
    left.2.2.2.2.2.2.1 right.2.2.2.2.2.2.1).2,
    (ControlSignatureLists.identify values _ _ rh sh results rs left.2.1 right.2.1
    left.2.2.2.2.2.2.2 right.2.2.2.2.2.2.2).2⟩

def RowFacts {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (first i : Nat) (start : Fin (2^36)) (ph rh : Fin (2^32)) (params results : List Nat) : Prop :=
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  let state := ControlTypeTrace.ready rows ops i
  ControlLengthLists.Image values tables indexed row ph rh params results ∧
  (∃ current : Fin (2^36), FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) current.val ∧
    ControlMemberSource.inputMode (ops.getD i 0) current.val=ControlMemberSource.inputMode (ops.getD first 0) start.val ∧
    ControlMemberSource.outputMode (ops.getD i 0) current.val=ControlMemberSource.outputMode (ops.getD first 0) start.val ∧
    ControlListArity.resultMode (ops.getD i 0) current.val=ControlListArity.resultMode (ops.getD first 0) start.val) ∧
  (E values (ControlTypeRowCheck.argument row)=1 →
    ControlMemberSource.Input values row (ops.getD first 0) start.val params results state.args (rows.getD i default).valueType.val) ∧
  (E values (f row.after 32)=1 →
    ControlMemberSource.Output values row (ops.getD first 0) start.val params results state.pushes (rows.getD i default).valueType.val) ∧
  (E values row.compare.active=1 → ControlMemberPositions.Image values row true false params state.args ∧
    E values row.comparison.low=E values row.payload.low)

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (trace : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) trace)
    (schedule : InstructionSemanticSound.Schedule values events trace ops)
    (members : ControlMemberSource.Complete values body splits tables declaration indexed signature r trace ops)
    (first last : Nat) (span : InstructionSpans.Span trace first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true)
    (start : Fin (2^36)) (ph rh : Fin (2^32)) (params results : List Nat)
    (frame : FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) first) start.val)
    (lists : ControlLengthLists.Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) first) ph rh params results)
    (i : Nat) (lo : first≤i) (hi : i≤last) :
    RowFacts values splits tables indexed r trace ops first i start ph rh params results := by
  have sameHeads := ControlSignatureSpan.heads matrix splits events r checked values one satisfied trace ops images schedule
    first last span (i-first) (by omega)
  rw [show first+(i-first)=i from by omega] at sameHeads
  have held := ControlHeldLists.transfer values tables indexed _ _ ph rh params results sameHeads lists
  obtain ⟨current,qh,sh,ps,rs,currentFrame,other,_,inputs,outputs,comparison⟩ := members i (by have := span.bounded; omega)
  have same := unique values tables indexed _ ph rh qh sh params results ps rs held other
  rcases same with ⟨rfl,rfl⟩
  have modes := ControlSignatureSpan.modes matrix splits events r checked values one satisfied trace ops images schedule
    first last span active i lo hi start current frame currentFrame
  refine ⟨held,⟨current,currentFrame,modes⟩,?_,?_,comparison⟩
  · intro on
    simpa only [ControlMemberSource.Input,ControlMemberSource.inputTypes,modes.1] using inputs on
  · intro on
    simpa only [ControlMemberSource.Output,ControlMemberSource.outputTypes,modes.2.1] using outputs on

theorem terminal {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (trace : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) trace)
    (schedule : InstructionSemanticSound.Schedule values events trace ops)
    (semantics : ControlTypeSemanticSound.Complete values splits r trace ops)
    (first last : Nat) (span : InstructionSpans.Span trace first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true)
    (start : Fin (2^36)) (ph rh : Fin (2^32)) (params results : List Nat)
    (facts : RowFacts values splits tables indexed r trace ops first last start ph rh params results) :
    (ControlTypeTrace.state trace ops last).args=(ControlMemberSource.inputTypes (ops.getD first 0) start.val params results).length ∧
    (ControlTypeTrace.state trace ops last).pushes=ControlListArity.outputCount (ops.getD first 0) start.val params results := by
  have code := InstructionSpanState.opcodes values events trace ops schedule first last span last (by have := span.ordered; omega) (by omega)
  have rc := ControlTypeCertificate.row matrix splits events r checked values trace ops images schedule last span.bounded
  have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied trace ops images schedule last span.bounded
  obtain ⟨current,frame,modeIn,modeOut,modeResult⟩ := facts.2.1
  have frameImage := ControlFrameMetadata.image matrix _ _ rc.2.2.1 values one _ rc.2.1 _ frame
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,finish,_⟩ := semantics.2 last span.bounded
  have endOn : ControlTypeMasks.selected (trace.getD last default).kind .instructionEnd (ops.getD last 0)=true := by
    simp only [ControlTypeMasks.selected,code,active,span.endKind,decide_true,Bool.and_self]
  have ending := finish endOn
  rw [ControlActionSequence.after_end trace ops first last span] at ending
  have parts := checked
  simp only [ControlTypeCertificate.check,ControlTypeRowCheck.checkStage,ControlTypeCertificate.linked,
    Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size := images.1.trans parts.2.1.1
  have lengthBound : trace.length<2^32 := by rw [size]; exact parts.1.1.1.2.1
  have bounded : ControlTypeGuards.Bounded (ControlTypeTrace.state trace ops last) := by
    have b := ControlTypeTrace.bounds trace ops last
    have lb := span.bounded
    unfold ControlTypeTrace.Bounded at b
    unfold ControlTypeGuards.Bounded
    omega
  have counts := ControlListArity.finish matrix _ rc.1 values one satisfied tables indexed ph rh params results facts.1
    _ _ masks.2.2 frameImage _ bounded ending
  simpa only [ControlMemberSource.inputTypes,ControlListArity.outputCount,modeIn,modeOut,modeResult] using counts

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (r : StructuredMatrix.Record)
    (trace : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span trace first last → ControlTypeModes.supported (ops.getD first 0)=true →
    ∃ start : Fin (2^36), ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) first) start.val ∧
      ControlSignatureLists.Origin values body tables declaration indexed signature start params results ∧
      (∀ i, first≤i → i≤last → RowFacts values splits tables indexed r trace ops first i start ph rh params results) ∧
      (ControlTypeTrace.state trace ops last).args=(ControlMemberSource.inputTypes (ops.getD first 0) start.val params results).length ∧
      (ControlTypeTrace.state trace ops last).pushes=ControlListArity.outputCount (ops.getD first 0) start.val params results ∧
      ControlActionSequence.actions trace (first+1) (last-first-1)=ControlActionSequence.plan (ops.getD first 0)
        (ControlMemberSource.inputTypes (ops.getD first 0) start.val params results).length
        (ControlListArity.outputCount (ops.getD first 0) start.val params results)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (trace : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) trace)
    (schedule : InstructionSemanticSound.Schedule values events trace ops)
    (semantics : ControlTypeSemanticSound.Complete values splits r trace ops)
    (lists : ControlSignatureSemanticSound.Lists values body splits tables declaration indexed signature r trace ops)
    (members : ControlMemberSource.Complete values body splits tables declaration indexed signature r trace ops) :
    Complete values body splits tables declaration indexed signature r trace ops := by
  intro first last span active
  have lookup : ControlLookupMask.active (trace.getD first default).kind (ops.getD first 0)=true := by
    simp only [ControlLookupMask.active,span.beginKind,active,reduceCtorEq,decide_false,decide_true,Bool.true_and,Bool.false_or]
  obtain ⟨start,ph,rh,params,results,frame,firstLists,origin⟩ := lists first (by have := span.ordered; have := span.bounded; omega) lookup
  have allRows := rows matrix body splits tables declaration indexed signature events r checked values one satisfied trace ops images schedule members
    first last span active start ph rh params results frame firstLists
  have counts := terminal matrix splits tables indexed events r checked values one satisfied trace ops images schedule semantics
    first last span active start ph rh params results (allRows last (by have := span.ordered; omega) (by omega))
  have sequence := (ControlActionSequence.sound values splits events r trace ops schedule semantics first last span active).1
  exact ⟨start,ph,rh,params,results,frame,origin,allRows,counts.1,counts.2,by simpa only [counts.1,counts.2] using sequence⟩

#print axioms unique
#print axioms rows
#print axioms terminal
#print axioms sound
end ZkBuild.ControlBodySignatures
