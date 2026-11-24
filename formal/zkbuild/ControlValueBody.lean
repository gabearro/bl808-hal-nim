import ControlValueTypes
set_option autoImplicit false
namespace ZkBuild.ControlValueBody
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def actions (trace : List Row) (start count : Nat) : List ControlPlans.Action :=
  (List.range count).flatMap (fun k => ControlValueLanguage.token (trace.getD (start+k) default).kind (trace.getD (start+k) default).valueType.val)
theorem snoc (trace : List Row) (start count : Nat) :
    actions trace start (count+1)=actions trace start count++ControlValueLanguage.token (trace.getD (start+count) default).kind (trace.getD (start+count) default).valueType.val := by
  simp only [actions,List.range_succ,List.flatMap_append,List.flatMap_cons,List.flatMap_nil,List.append_nil]

def layout (code token : Nat) (params results : List Nat) : ControlPlans.Layout :=
  ⟨List.replicate (ControlTypeMasks.condition code).toNat 0++ControlValueTypes.inputs code token params results,
   List.replicate (FrameOpcodes.closes code).toNat false++List.replicate (ControlTypeGuards.opening code).toNat true,
   (ControlValueTypes.outputs code token params results).take (ControlListArity.outputCount code token params results),
   ControlTypeGuards.clearing code⟩

theorem terminal_history (code token : Nat) (params results : List Nat) (s : ControlTypeState.State)
    (args : s.args=(ControlMemberSource.inputTypes code token params results).length)
    (pushes : s.pushes=ControlListArity.outputCount code token params results)
    (opened : s.opened=(ControlTypeGuards.opening code).toNat) (closed : s.closed=(FrameOpcodes.closes code).toNat)
    (cleared : s.cleared=(ControlTypeGuards.clearing code).toNat) (pending : s.pending=false) :
    ControlValueLanguage.history (ControlTypeMasks.condition code) (ControlValueTypes.inputs code token params results)
      (ControlValueTypes.outputs code token params results) s=
    ControlPlans.plan (layout code token params results).inputs (layout code token params results).frames
      (layout code token params results).outputs (layout code token params results).clears := by
  have inputLength : s.args=(ControlValueTypes.inputs code token params results).length := by
    simpa only [ControlValueTypes.inputs,ControlValueTypes.length] using args
  simp only [ControlValueLanguage.history,inputLength,pushes,opened,closed,cleared,pending,Bool.toNat_false,Nat.sub_zero,
    List.take_length,layout,ControlPlans.plan,List.map_append,List.map_replicate,ControlPlans.frameAction,Bool.false_eq_true,ite_false,ite_true,List.append_assoc]
  have rep (b : Bool) : List.replicate b.toNat ControlPlans.Action.clear=(if b then [.clear] else []) := by
    cases b <;> rfl
  rw [rep]
  rfl

theorem segment {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
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
    (facts : ∀ i, first≤i → i≤last → ControlBodySignatures.RowFacts values splits tables indexed r trace ops first i start ph rh params results)
    (count : Nat) (bound : first+1+count≤last) :
    ControlPlans.Matches
      (ControlValueLanguage.history (ControlTypeMasks.condition (ops.getD first 0))
        (ControlValueTypes.inputs (ops.getD first 0) start.val params results)
        (ControlValueTypes.outputs (ops.getD first 0) start.val params results) (ControlTypeTrace.state trace ops (first+1+count)))
      (actions trace (first+1) count) := by
  induction count with
  | zero =>
    simpa only [Nat.add_zero,ControlActionSequence.initial trace ops first span.beginKind,ControlValueLanguage.history,
      Nat.sub_self,List.replicate_zero,List.take_zero,List.map_nil,List.nil_append,actions,List.range_zero,List.flatMap_nil]
      using ControlPlans.Matches.nil
  | succ count ih =>
    have prior := ih (by omega)
    let i := first+1+count
    have lo : first<i := by dsimp [i]; omega
    have hi : i<last := by dsimp [i]; omega
    have ib : i<trace.length := by have := span.bounded; omega
    have code := InstructionSpanState.opcodes values events trace ops schedule first last span i (by omega) (by omega)
    have ready := ControlActionSequence.ready_interior trace ops first last span i lo (by omega)
    have guards := ControlActionGuards.trace values splits r trace ops semantics
    have g := guards i ib (by rw [code]; exact active)
    rw [ready,code] at g
    have types := ControlValueTypes.row matrix splits tables indexed events r checked values one satisfied trace ops images schedule semantics
      first last span active start ph rh params results i (by omega) (by omega) (facts i (by omega) (by omega))
    rw [ready] at types
    have order := ControlActionSequence.segment values events trace ops schedule guards first last span active count (by omega)
    have step := ControlValueLanguage.step _ _ _ _ _ _ _ _ active
      (ControlActionGuards.alphabet values events trace ops schedule first last span active i lo hi) order.1 g types prior
    rw [snoc,show first+1+(count+1)=i+1 from by dsimp [i]; omega]
    change ControlPlans.Matches (ControlValueLanguage.history _ _ _ (ControlTypeState.advance (ControlTypeTrace.ready trace ops i) _ _)) _
    rw [ready,code]
    exact step

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (r : StructuredMatrix.Record) (trace : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span trace first last → ControlTypeModes.supported (ops.getD first 0)=true →
    ∃ start : Fin (2^36), ∃ params results : List Nat,
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) first) start.val ∧
      ControlSignatureLists.Origin values body tables declaration indexed signature start params results ∧
      ControlPlans.Body (layout (ops.getD first 0) start.val params results).inputs
        (layout (ops.getD first 0) start.val params results).frames
        (layout (ops.getD first 0) start.val params results).outputs
        (layout (ops.getD first 0) start.val params results).clears (actions trace (first+1) (last-first-1)) ∧
      (∀ i, first<i → i<last → ControlActionGuards.Allowed (trace.getD i default).kind (ops.getD first 0))

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
    (bodies : ControlBodySignatures.Complete values body splits tables declaration indexed signature r trace ops) :
    Complete values body tables declaration indexed signature r trace ops := by
  intro first last span active
  obtain ⟨start,ph,rh,params,results,frame,origin,facts,args,pushes,_⟩ := bodies first last span active
  have matched := segment matrix splits tables indexed events r checked values one satisfied trace ops images schedule semantics
    first last span active start ph rh params results facts (last-first-1) (by have := span.ordered; omega)
  rw [show first+1+(last-first-1)=last from by have := span.ordered; omega] at matched
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,finish,_⟩ := semantics.2 last span.bounded
  have code := InstructionSpanState.opcodes values events trace ops schedule first last span last (by have := span.ordered; omega) (by omega)
  have ending := finish (by simp only [ControlTypeMasks.selected,span.endKind,code,active,decide_true,Bool.and_self])
  rw [ControlActionSequence.after_end trace ops first last span,code] at ending
  rw [terminal_history _ _ _ _ _ args pushes ending.2.2.1 ending.2.2.2.1 ending.2.2.2.2.1 ending.2.2.2.2.2] at matched
  exact ⟨start,params,results,frame,origin,ControlPlans.body_complete _ _ _ _ _ matched,
    ControlActionGuards.alphabet values events trace ops schedule first last span active⟩

#print axioms snoc
#print axioms terminal_history
#print axioms segment
#print axioms sound
end ZkBuild.ControlValueBody
