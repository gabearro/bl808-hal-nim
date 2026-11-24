import FramePadTrace
set_option autoImplicit false
namespace ZkBuild.FrameWriteValue
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

def written (root : Bool) (fn code pad source : Nat) : Nat :=
  if root then 16*fn+4 else if code=5 then 4*(source/4)+3 else FrameBlockEncoding.token code pad

theorem bounded (root : Bool) (fn code pad source : Nat)
    (fb : fn<2^32) (sb : source<2^36) (valid : FrameBlockEncoding.Valid pad) :
    written root fn code pad source < 2^36 := by
  have := FrameBlockEncoding.bounded code pad valid
  unfold written
  split
  · omega
  · split <;> omega

theorem scalar {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (row : Row) (code : Nat) (cb : code<2^16) (image : FrameCertificate.Images values r row code)
    (pushed : row.kind=.controlPush) (root : Bool) (prior : E values (f r.before 1)=flag root)
    (pad source : Nat) (proposed : E values (f r.after 31)=(FrameBlockEncoding.token code pad:F))
    (descriptor : FrameDescriptor.Image values r source) :
    E values r.write.value=(written root row.functionIndex code pad source:F) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have tags := FrameSelectors.tags values one r row code image
  have push : E values (f r.flags 4)=1 := by
    simpa only [pushed,flag,decide_true,ite_true] using tags.controlPush
  have isElse := FrameOpcodes.selectors matrix r checked values one satisfied code cb image.opcode 3 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at isElse
  have pending := facts.multiply (f r.before 1) (f r.flags 4) 11 (by simp [multiplies])
  have alternative := facts.select (f r.after 3) (scale (f r.after 38) 4++n 3) (f r.after 31) 42 (by simp [selects])
  have picked := facts.select (f r.after 11) (rootToken r) (f r.after 42) 43 (by simp [selects])
  have value := facts.multiply (f r.flags 4) (f r.after 43) 45 (by simp [multiplies])
  have faces := FrameRowImages.interface matrix r checked values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
  have output := faces.2.2.2.2.2.2.2.1
  have rootImage : E values (rootToken r)=(16*row.functionIndex+4:F) := by
    simp only [rootToken,eval_append,eval_scale,image.functionIndex,n,eval_constant values one,
      Ring.intCast_ofNat 16]
    change (16:F)*(row.functionIndex:F)+((4:Int):F)=(16:F)*(row.functionIndex:F)+4
    rw [Ring.intCast_ofNat 4]
  simp only [prior,push,Semiring.mul_one] at pending
  simp only [eval_append,eval_scale,descriptor.key,n,eval_constant values one,Ring.intCast_ofNat 4,
    Ring.intCast_ofNat 3,proposed,isElse] at alternative
  simp only [pending,rootImage] at picked
  simp only [push,Semiring.one_mul] at value
  simp only [written]
  cases root <;> by_cases c : code=5 <;>
    simp only [Bool.false_eq_true,ite_false,ite_true,c,Semiring.natCast_add,
      Semiring.natCast_mul,Semiring.natCast_eq_ofNat 16,Semiring.natCast_eq_ofNat 4,Semiring.natCast_eq_ofNat 3] <;>
    simp only [flag,c,decide_true,decide_false,ite_true,ite_false,E] at pending alternative picked value output ⊢ <;>
    grind only

def rootAt (rows : List Row) (i : Nat) : Bool :=
  if i=0 then false else decide ((rows.getD (i-1) default).kind=.functionBegin)

theorem prior {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (ib : i<rows.length) :
    E values (f (record r.frames (StructuredMatrix.stage r 3) i).before 1)=flag (rootAt rows i) := by
  by_cases first : i=0
  · subst i
    change E values z = flag false
    simp only [z,eval_constant values one,Ring.intCast_zero,flag,ite_false,Bool.false_eq_true]
  · have row := FrameCertificate.row matrix events r checked values rows ops images schedule (i-1) (by omega)
    have tags := FrameSelectors.tags values one _ _ _ row.2
    simpa only [record,rootAt,first,ite_false,FrameDescriptor.field_succ,FrameDescriptor.field_zero] using tags.functionBegin

def Writes {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → (rows.getD i default).kind=.controlPush →
    ∃ pad : Fin (2^33), ∃ source : Fin (2^36),
      FrameBlockEncoding.Valid pad.val ∧
      E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 20)=(pad.val:F) ∧
      FrameDescriptor.Image values (record r.frames (StructuredMatrix.stage r 3) i) source.val ∧
      written (rootAt rows i) (rows.getD i default).functionIndex (ops.getD i 0) pad.val source.val < 2^36 ∧
      E values (record r.frames (StructuredMatrix.stage r 3) i).write.value=
        (written (rootAt rows i) (rows.getD i default).functionIndex (ops.getD i 0) pad.val source.val:F)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Writes values r rows ops := by
  intro i ib push
  obtain ⟨pad,pi,valid,_,encoded⟩ := FramePadTrace.encoded matrix events r checked values one satisfied rows ops images schedule i ib
  have row := FrameCertificate.row matrix events r checked values rows ops images schedule i ib
  obtain ⟨source,si⟩ := FrameDescriptor.sound matrix _ row.1 values one satisfied
  exact ⟨pad,source,valid,pi,si,bounded _ _ _ _ _ (images.2 i ib).2.1 source.isLt valid,
    scalar matrix _ row.1 values one satisfied _ _ (schedule.opcode i ib).1 row.2 push _
      (prior matrix events r checked values one rows ops images schedule i ib) _ _ encoded si⟩

/-- Each concrete RAM write has the derived natural token, not just an equal
    scalar-field image. This uses the same memory witness as the live stack. -/
def Entries {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) (entries : List MemoryTrace.Entry) : Prop :=
  ∀ i, i<rows.length → (rows.getD i default).kind=.controlPush →
    ∃ pad : Fin (2^33), ∃ source : Fin (2^36),
      FrameBlockEncoding.Valid pad.val ∧
      E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 20)=(pad.val:F) ∧
      FrameDescriptor.Image values (record r.frames (StructuredMatrix.stage r 3) i) source.val ∧
      (FrameTokenStack.entry entries (2*i+1)).value=
        written (rootAt rows i) (rows.getD i default).functionIndex (ops.getD i 0) pad.val source.val

theorem entries {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (es : List MemoryTrace.Entry) (memory : FrameTraceMemory.Facts values r rows es)
    (writes : Writes values r rows ops) : Entries values r rows ops es := by
  intro i ib push
  obtain ⟨pad,source,valid,pi,si,bounded,wi⟩ := writes i ib push
  have size := memory.length
  have ls := ShaProgram.related_length _ _ _ memory.represented
  simp only [List.length_map] at ls
  have rep := FrameMemorySound.represented_at values r.frames es memory.represented (2*i+1) (by omega)
  have vb := (memory.bounds (FrameTokenStack.entry es (2*i+1)) (by
    rw [FrameTokenStack.entry,← List.getElem_eq_getD (h:=by omega) MemoryPriorWrite.zero]
    exact List.getElem_mem (by omega))).2
  refine ⟨pad,source,valid,pi,si,?_⟩
  exact DeclarationLocations.natural_equal (F:=F) _ _ (Nat.lt_trans vb (by decide))
    (Nat.lt_trans bounded (by decide)) (rep.2.2.2.1.symm.trans wi)

def Complete {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∃ entries first, FrameTraceMemory.Facts values r rows entries ∧ FrameLifoSound.Live rows entries first ∧
    FrameLifoSound.Selected values r rows entries ∧ Entries values r rows ops entries

theorem complete {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (depthsChecked : FrameDepthCheck.checkStage matrix splits tables r=true)
    (controls : ControlCertificate.check matrix events=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values r rows ops := by
  obtain ⟨es,first,memory,live,selected⟩ := FrameLifoSound.sound matrix splits tables events r checked depthsChecked controls
    values one satisfied rows ops images schedule
  exact ⟨es,first,memory,live,selected,entries values r rows ops es memory
    (sound matrix events r checked values one satisfied rows ops images schedule)⟩

#print axioms bounded
#print axioms scalar
#print axioms prior
#print axioms sound
#print axioms entries
#print axioms complete
end ZkBuild.FrameWriteValue
