import InstructionInfoSound
set_option autoImplicit false
namespace ZkBuild.FrameInstructionSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem row_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (xs ys : List Fields) (same : DynamicTypingMatrix.same xs ys=true) (i k : Nat) :
    E values (f (rowAt xs i) k)=E values (f (rowAt ys i) k) := by
  have eq := _root_.of_decide_eq_true same
  have point := congrArg (fun xs : List Fields => xs.getD i []) eq
  simp only [ValidationEventMatrix.normalized] at point
  have mapPoint (rows : List Fields) : (rows.map (List.map normalizeLinear)).getD i []=(rowAt rows i).map normalizeLinear :=
    TokenInteger.map_getD (List.map normalizeLinear) rows [] i
  rw [mapPoint,mapPoint] at point
  exact VariableSelectorCheck.point values _ _ point k

theorem event_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (s : InstructionStreamMatrix.Record) (events : ValidationEventMatrix.Record)
    (linked : ValidationEventCheck.links events s=true) (i : Nat) (ib : i<events.rows.length) (k : Nat) :
    E values (f (rowAt s.events i) k)=
      E values (f [f (rowAt events.rows i) 0,f (rowAt events.rows i) 1,f (rowAt events.rows i) 9,
        f (rowAt events.rows i) 8,f (rowAt events.rows i) 10,f (rowAt events.rows i) 11,f (rowAt events.rows i) 12] k) := by
  have links := _root_.of_decide_eq_true linked
  have same : DynamicTypingMatrix.same s.events (ValidationSourceSound.projected events)=true :=
    by exact decide_eq_true links.2.2.2.2.1
  have point := row_field values _ _ same i k
  have row : rowAt (ValidationSourceSound.projected events) i =
      [f (rowAt events.rows i) 0,f (rowAt events.rows i) 1,f (rowAt events.rows i) 9,
       f (rowAt events.rows i) 8,f (rowAt events.rows i) 10,f (rowAt events.rows i) 11,f (rowAt events.rows i) 12] := by
    simp [ValidationSourceSound.projected,rowAt,List.getD,List.getElem?_map,ib]
  rw [row] at point
  exact point

theorem pad_input {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record)
    (declaration : DeclarationMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events s signature indexed declaration r=true)
    (i : Nat) (ib : i<events.rows.length) :
    E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).inputs 1)=E values (f (rowAt events.rows i) 12) := by
  have links := linked
  simp only [StructuredCheck.links,Bool.and_eq_true_iff] at links
  have same : DynamicTypingMatrix.same (StructuredMatrix.stage r 3).inputs
      ((List.range events.rows.length).map fun i => [f (rowAt events.rows i) 10,f (rowAt events.rows i) 12,
        f (rowAt (StructuredMatrix.stage r 2).outputs i) 0++f (rowAt (StructuredMatrix.stage r 0).outputs i) 1])=true := by grind only
  have point := row_field values _ _ same i 1
  have row : rowAt ((List.range events.rows.length).map fun i => [f (rowAt events.rows i) 10,f (rowAt events.rows i) 12,
      f (rowAt (StructuredMatrix.stage r 2).outputs i) 0++f (rowAt (StructuredMatrix.stage r 0).outputs i) 1]) i =
      [f (rowAt events.rows i) 10,f (rowAt events.rows i) 12,
       f (rowAt (StructuredMatrix.stage r 2).outputs i) 0++f (rowAt (StructuredMatrix.stage r 0).outputs i) 1] := by
    simp [rowAt,List.getD,List.getElem?_map,List.getElem?_range,ib]
  rw [row] at point
  simpa only [FrameRowCheck.record,FrameDescriptor.field_succ,FrameDescriptor.field_zero] using point

theorem canonical_kind {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true) (values : Nat → F) (rows : List Row)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (i : Nat) (ib : i<rows.length) :
    E values (f (rowAt events.rows i) 0)=(kindCode (rows.getD i default).kind:F) := by
  have links := (Bool.and_eq_true_iff.mp checked).2
  simp only [FrameCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size := images.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have left := VariableSelectorCheck.point values _ _ matched.1 0
  have right := VariableSelectorCheck.point values _ _ matched.2.1 0
  simp only [f,DeclarationMatrix.get,List.getD,List.getElem?_take,show 0<10 from by decide,
    show 0<7 from by decide,ite_true] at left right
  exact (left.symm.trans right).trans (images.2 i ib).1.kind

def Complete {F : Type} [Field F] (values : Nat → F) (s : InstructionStreamMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → (rows.getD i default).kind=.instructionBegin →
    ∃ (d : InstructionEventSound.Data) (source : InstructionStreamMatrix.Row), source ∈ s.rows ∧
      d.functionIndex.val=(rows.getD i default).functionIndex ∧ d.opcode.val=ops.getD i 0 ∧
      InstructionInfoSound.Matches values source d ∧ FrameBlockEncoding.Valid d.pad.val ∧
      E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 20)=(d.pad.val:F) ∧
      E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 31)=
        (FrameBlockEncoding.token d.opcode.val d.pad.val:F)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (events : ValidationEventMatrix.Record) (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record)
    (declaration : DeclarationMatrix.Record) (r : StructuredMatrix.Record)
    (eventChecked : InstructionEventCheck.checkStage matrix tables s=true)
    (sourceChecked : InstructionInfoCheck.checkStage matrix tables catalog decoders s=true)
    (eventLinks : ValidationEventCheck.links events s=true)
    (links : StructuredCheck.links tables events s signature indexed declaration r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values s r rows ops := by
  intro i ib kind
  have size := schedule.length
  have eventSize : s.events.length=events.rows.length := by
    have h := congrArg List.length (_root_.of_decide_eq_true eventLinks).2.2.2.2.1
    simpa only [normalized,List.length_map] using h
  have ei : i<s.events.length := by omega
  have row := FrameCertificate.row matrix events r frames values rows ops images schedule i ib
  have ec := List.all_eq_true.mp (Bool.and_eq_true_iff.mp eventChecked).2 i (List.mem_range.mpr ei)
  obtain ⟨d,di⟩ := InstructionEventSound.decoded matrix _ ec values one satisfied
  have canonical := canonical_kind matrix events r frames values rows images i ib
  have k := event_field values s events eventLinks i (by omega) 0
  have begin : E values (f (rowAt s.events i) 0)=1 := by
    simp only [FrameDescriptor.field_zero] at k
    simpa only [kind,kindCode,Semiring.natCast_one] using k.trans canonical
  obtain ⟨source,sm,matched⟩ := InstructionInfoSound.selected matrix tables s catalog decoders eventChecked sourceChecked values one satisfied i ei d di begin
  have fn := event_field values s events eventLinks i (by omega) 1
  have op := event_field values s events eventLinks i (by omega) 3
  have pad := event_field values s events eventLinks i (by omega) 6
  simp only [FrameDescriptor.field_succ,FrameDescriptor.field_zero] at fn op pad
  have frameFn := row.2.functionIndex
  -- The frame rows share canonical function indices with the source events.
  have frameLinks := (Bool.and_eq_true_iff.mp frames).2
  simp only [FrameCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at frameLinks
  have frameSize := images.1
  have link := _root_.of_decide_eq_true (List.all_eq_true.mp frameLinks.2 i (List.mem_range.mpr (by omega)))
  have fni := VariableSelectorCheck.point values _ _ link.1 1
  simp only [f,DeclarationMatrix.get,List.getD,List.getElem?_take,show 1<10 from by decide,ite_true] at fni
  have fnSame := DeclarationLocations.natural_equal (F:=F) d.functionIndex.val (rows.getD i default).functionIndex
    (Nat.lt_trans d.functionIndex.isLt (by decide)) (Nat.lt_trans (images.2 i ib).2.1 (by decide))
    (di.1.symm.trans (fn.trans (fni.symm.trans frameFn)))
  have opSame := DeclarationLocations.natural_equal (F:=F) d.opcode.val (ops.getD i 0)
    (Nat.lt_trans d.opcode.isLt (by decide)) (Nat.lt_trans (schedule.opcode i ib).1 (by decide))
    (di.2.2.1.symm.trans (op.trans (schedule.opcode i ib).2.1))
  have input := pad_input values tables s events signature indexed declaration r links i (by omega)
  have pi : E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).inputs 1)=(d.pad.val:F) :=
    input.trans (pad.symm.trans di.2.2.2.2.2)
  have tags := FrameSelectors.tags values one _ _ _ row.2
  have held := (FrameRowSound.meaning matrix _ row.1 values one satisfied).select
    (FrameRowCheck.reset (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)) (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).inputs 1)
    (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).before 2) 20 (by simp [FrameRowCheck.selects])
  simp only [FrameRowCheck.reset,eval_append,tags.functionBegin,tags.instructionBegin,kind,reduceCtorEq,flag,decide_false,decide_true,ite_false,ite_true,pi] at held
  have heldImage : E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 20)=(d.pad.val:F) := by grind only
  have encoded := FrameBlockEncoding.scalar matrix _ row.1 values one satisfied d.pad heldImage _ (schedule.opcode i ib).1 row.2.opcode
  exact ⟨d,source,sm,fnSame,opSame,matched,encoded.1,heldImage,by simpa only [opSame] using encoded.2⟩

#print axioms row_field
#print axioms event_field
#print axioms pad_input
#print axioms canonical_kind
#print axioms sound
end ZkBuild.FrameInstructionSource
