import ControlBodySignatures
import ControlValueLanguage
set_option autoImplicit false
namespace ZkBuild.ControlValueTypes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def orient (reverse : Bool) (tags : List Nat) := if reverse then tags.reverse else tags
def inputs (code token : Nat) (params results : List Nat) :=
  orient (!(ControlMemberSource.inputMode code token)) (ControlMemberSource.inputTypes code token params results)
def outputs (code token : Nat) (params results : List Nat) :=
  orient (ControlMemberSource.outputMode code token) (ControlMemberSource.outputTypes code token params results)

theorem length (reverse : Bool) (tags : List Nat) : (orient reverse tags).length=tags.length := by
  cases reverse <;> simp [orient]
theorem point (reverse : Bool) (tags : List Nat) (i : Nat) (bound : i<tags.length) :
    (orient reverse tags).getD i 0=tags.getD (ControlMemberPositions.index reverse tags.length i) 0 := by
  cases reverse
  · rfl
  · simp only [orient,ControlMemberPositions.index,ite_true,List.getD,List.getElem?_reverse bound]

theorem row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
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
    (i : Nat) (lo : first≤i) (hi : i≤last)
    (facts : ControlBodySignatures.RowFacts values splits tables indexed r trace ops first i start ph rh params results) :
    ControlValueLanguage.Types (inputs (ops.getD first 0) start.val params results) (outputs (ops.getD first 0) start.val params results)
      (ControlTypeTrace.ready trace ops i) (trace.getD i default).kind (trace.getD i default).valueType.val := by
  have ib : i<trace.length := by have := span.bounded; omega
  have code := InstructionSpanState.opcodes values events trace ops schedule first last span i lo hi
  have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied trace ops images schedule i ib
  have state := semantics.1 i ib
  have activeHere : ControlTypeModes.supported (ops.getD i 0)=true := by rw [code]; exact active
  have selected (kind : Kind) (eq : (trace.getD i default).kind=kind) : ControlTypeMasks.selected (trace.getD i default).kind kind (ops.getD i 0)=true := by
    simp only [ControlTypeMasks.selected,activeHere,eq,decide_true,Bool.and_self]
  constructor
  · intro kind
    have pop := selected .pop kind
    cases pending : (ControlTypeTrace.ready trace ops i).pending
    · have argumentOn : E values (ControlTypeRowCheck.argument (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1 := by
        simpa only [pop,pending,Bool.not_false,Bool.and_self,flag,ite_true] using state.2.2.2.2
      have typed := facts.2.2.1 argumentOn
      simp only [pending,Bool.false_eq_true,ite_false]
      refine ⟨by simpa only [inputs,length] using typed.1.1,?_⟩
      simpa only [inputs,point _ _ _ typed.1.1] using typed.2
    · obtain ⟨_,_,_,_,condition,_⟩ := semantics.2 i ib
      simpa only [pending,ite_true] using condition (by simp only [pop,pending,Bool.and_self])
  · intro kind
    have push := selected .push kind
    have pushOn : E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 32)=1 := by
      simpa only [push,flag,ite_true] using masks.2.1.push
    have typed := facts.2.2.2.1 pushOn
    exact ⟨by simpa only [outputs,length] using typed.1.1,by simpa only [outputs,point _ _ _ typed.1.1] using typed.2⟩

#print axioms length
#print axioms point
#print axioms row
end ZkBuild.ControlValueTypes
