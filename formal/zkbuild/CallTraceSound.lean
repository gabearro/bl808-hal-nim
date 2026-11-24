import CallCertificate
set_option autoImplicit false
namespace ZkBuild.CallTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Inputs where
  params : Fin (2^32) := ⟨0,by decide⟩
  results : Fin (2^32) := ⟨0,by decide⟩
  tag : Fin 8 := ⟨0,by decide⟩
  next : Fin (2^32) := ⟨0,by decide⟩
  deriving Inhabited

def DataImage {F : Type} [Field F] (values : Nat → F) (r : CallRowCheck.Record) (data : Inputs) : Prop :=
  E values r.heads.low = (data.params.val : F) ∧ E values r.heads.high = (data.results.val : F) ∧
  E values r.payload.low = (data.tag.val : F) ∧ E values r.payload.high = (data.next.val : F) ∧
  E values r.metadata.value = ((data.params.val+2^32*data.results.val : Nat) : F) ∧
  E values r.node.value = ((data.tag.val+8*data.next.val : Nat) : F)

def state (rows : List Row) (ops : List Nat) (data : Nat → Inputs) : Nat → CallState.State
  | 0 => {}
  | i+1 => CallState.advance
      (CallState.prepare (state rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i).params (data i).results)
      (rows.getD i default).kind (ops.getD i 0) (data i).next

def ready (rows : List Row) (ops : List Nat) (data : Nat → Inputs) (i : Nat) :=
  CallState.prepare (state rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i).params (data i).results

def Trace {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → Inputs, ∀ i, i < rows.length →
    let r := CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i
    DataImage values r (data i) ∧ CallState.Image values r.before (state rows ops data i) ∧
    CallState.Image values (CallState.ready r) (ready rows ops data i) ∧
    CallState.Image values (CallState.after r) (state rows ops data (i+1)) ∧
    CallState.Masks values r (ready rows ops data i) (rows.getD i default).kind (ops.getD i 0)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Trace values splits tables signature typing rows ops := by
  classical
  have facts := CallCertificate.row matrix splits tables signature statics events typing accepted values one rows images
  have decoded : ∀ i : Fin rows.length, ∃ data : Inputs,
      DataImage values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i.val) data := by
    intro i
    have ck := (facts i i.isLt).1
    obtain ⟨p,q,pi,qi,mi⟩ := CallRowSound.heads matrix _ ck values one satisfied
    obtain ⟨tag,next,ti,ni,vi⟩ := CallRowSound.payload matrix _ ck values one satisfied
    exact ⟨⟨p,q,tag,next⟩,pi,qi,ti,ni,mi,vi⟩
  let entries := fun i : Fin rows.length => Classical.choose (decoded i)
  have entryImages (i : Fin rows.length) : DataImage values
      (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i.val) (entries i) :=
    Classical.choose_spec (decoded i)
  let data : Nat → Inputs := fun i => if h : i < rows.length then entries ⟨i,h⟩ else default
  have di (i : Nat) (ib : i < rows.length) :
      DataImage values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i) (data i) := by
    simpa only [data,dite_eq_left ib] using entryImages ⟨i,ib⟩
  have step : ∀ i, i < rows.length →
      let r := CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i
      CallState.Image values r.before (state rows ops data i) ∧
      CallState.Image values (CallState.ready r) (ready rows ops data i) ∧
      CallState.Image values (CallState.after r) (state rows ops data (i+1)) ∧
      CallState.Masks values r (ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) := by
    intro i
    induction i with
    | zero =>
      intro ib
      have before : CallState.Image values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) 0).before (state rows ops data 0) := by
        change CallState.Image values [z,z,z,z,z,z] ({} : CallState.State)
        simp [CallState.Image,f,DeclarationMatrix.get,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero,flag]
      have rf := facts 0 ib
      have ci : E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) 0).row 8) = (ops.getD 0 0 : F) := rf.2.2.2.trans (schedule.opcode 0 ib).2.1
      have init := CallState.initial_image matrix _ rf.1 values one satisfied _ rf.2.1 _ (schedule.opcode 0 ib).1 ci _ before _ _ (di 0 ib).1 (di 0 ib).2.1
      have masks := CallState.masks matrix _ rf.1 values one satisfied _ rf.2.1 _ (schedule.opcode 0 ib).1 ci _ init
      exact ⟨before,init,CallTransition.image matrix _ rf.1 values one satisfied _ _ _ init masks _ (di 0 ib).2.2.2.1,masks⟩
    | succ i ih =>
      intro ib
      have prior := ih (by omega)
      have before : CallState.Image values (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) (i+1)).before (state rows ops data (i+1)) := by
        simp only [CallRowCheck.record,Nat.add_one_ne_zero,ite_false,Nat.add_sub_cancel]
        change CallState.Image values (CallState.after (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i)) (state rows ops data (i+1))
        exact prior.2.2.1
      have rf := facts (i+1) ib
      have ci : E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) (i+1)).row 8) = (ops.getD (i+1) 0 : F) := rf.2.2.2.trans (schedule.opcode (i+1) ib).2.1
      have init := CallState.initial_image matrix _ rf.1 values one satisfied _ rf.2.1 _ (schedule.opcode (i+1) ib).1 ci _ before _ _ (di (i+1) ib).1 (di (i+1) ib).2.1
      have masks := CallState.masks matrix _ rf.1 values one satisfied _ rf.2.1 _ (schedule.opcode (i+1) ib).1 ci _ init
      exact ⟨before,init,CallTransition.image matrix _ rf.1 values one satisfied _ _ _ init masks _ (di (i+1) ib).2.2.2.1,masks⟩
  exact ⟨data,fun i ib => ⟨di i ib,step i ib⟩⟩

#print axioms sound
end ZkBuild.CallTraceSound
