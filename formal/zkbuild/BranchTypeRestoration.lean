import BranchTypeSemanticSound
import BranchScratchTrace
set_option autoImplicit false
namespace ZkBuild.BranchTypeRestoration
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Trace (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) : Prop :=
  ∀ i, i < rows.length → BranchTypePending.selected (rows.getD i default).kind .push (ops.getD i 0) = true →
    let s := BranchTypeTrace.chosen rows ops data i
    s.pushes < s.length ∧
    ∃ j, j < i ∧ j = s.start+(s.length-1-s.pushes) ∧
      (rows.getD j default).kind = .pop ∧ ops.getD j 0 = 14 ∧
      (rows.getD i default).valueType = (rows.getD j default).valueType

theorem represented_at {F : Type} [Field F]
    (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (entries : List MemoryTrace.Entry)
    (related : ShaProgram.Related (MemoryPacking.Represents values) (r.scratch.inputs.map MemoryEvidence.AccessRef.fields) entries)
    (i : Nat) (ib : i < r.scratch.inputs.length) :
    MemoryPacking.Represents values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).scratch
      (entries.getD i MemoryPriorWrite.zero) := by
  have point := OperandMemorySound.related_at _ _ _ related default MemoryPriorWrite.zero i (by simpa using ib)
  have same : (r.scratch.inputs.map MemoryEvidence.AccessRef.fields).getD i default =
      (r.scratch.inputs.getD i default).fields := by
    rw [← List.getElem_eq_getD (h := by simpa using ib) default]
    rw [← List.getElem_eq_getD (h := ib) default]
    simp only [List.getElem_map]
  rw [same] at point
  exact point

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → BranchTypeData.Data) (facts : BranchTypeTrace.Facts values splits r rows ops data) :
    Trace rows ops data := by
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1.2).1).1
  have size : rows.length = (StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  have bound : rows.length < 2^32 := by rw [size]; exact shape.2.1
  have memorySize : r.scratch.inputs.length = rows.length := shape.2.2.2.2.1.trans size.symm
  have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  obtain ⟨entries,length,related,scratch⟩ := BranchScratchTrace.sound matrix splits r.scratch (StructuredMatrix.stage r 5)
    parts.1.1.2 values one satisfied (fun i => (rows.getD i default).valueType) (fun i ib => (row i (by omega)).2.2.1)
  have el : entries.length = rows.length := length.trans size.symm
  intro i ib active
  dsimp only
  let s := BranchTypeTrace.chosen rows ops data i
  let typed := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
  have cb := (BranchTypeTrace.chosen_bounds rows ops data i).1
  have si := (facts i ib).2.2.2.1
  simp only [BranchTypeState.Image,BranchTypeState.chosen,List.map_cons,List.map_nil,
    BranchTypeState.field_zero,BranchTypeState.field_succ] at si
  have kindCode : (rows.getD i default).kind = .push ∧ ops.getD i 0 = 14 := by
    simpa only [BranchTypePending.selected,decide_eq_true_eq] using active
  have noArgument : E values (BranchTypeRowCheck.argument typed) = 0 := by
    simpa only [BranchTypePending.selected,kindCode.1,reduceCtorEq,false_and,decide_false,Bool.false_and,flag,Bool.false_eq_true,ite_false] using (masks i ib).argument
  have push : E values (f typed.after 34) = 1 := by simpa only [active,flag,ite_true] using (masks i ib).push
  unfold BranchTypeTrace.Bounded at cb
  have loaded := BranchTypeScratch.loaded matrix typed (row i ib).1 values one satisfied
    (rows.getD i default).valueType (row i ib).2.2.1
    ⟨s.start,by dsimp [s]; omega⟩ ⟨s.length,cb.1⟩ ⟨s.pushes,by dsimp [s]; omega⟩
    si.2.2.2.2.2.2.2 si.1 si.2.2.2.1 noArgument push
  have represented := represented_at values splits r entries related i (by omega)
  have ea : (entries.getD i MemoryPriorWrite.zero).active = true := by
    have a := represented.1.symm.trans loaded.2.1
    cases h : (entries.getD i MemoryPriorWrite.zero).active
    · have bad : (0 : F) = 1 := by simpa only [h,Bool.toNat_false,Bool.toNat_true,Semiring.natCast_zero,Semiring.natCast_one] using a
      exact False.elim (Field.zero_ne_one bad)
    · rfl
  have ew : (entries.getD i MemoryPriorWrite.zero).write = false := by
    have w := represented.2.1.symm.trans loaded.2.2.1
    cases h : (entries.getD i MemoryPriorWrite.zero).write
    · rfl
    · have bad : (1 : F) = 0 := by simpa only [h,Bool.toNat_false,Bool.toNat_true,Semiring.natCast_zero,Semiring.natCast_one] using w
      exact False.elim (Field.zero_ne_one bad.symm)
  obtain ⟨j,ji,address,ja,jw,tags⟩ := scratch.readOrigin i (by omega) ea ew
  have jb : j < rows.length := by omega
  have location : j = s.start+(s.length-1-s.pushes) := by
    apply DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by dsimp [s]; omega)
    have eq := represented.2.2.1.symm.trans loaded.2.2.2.1
    rw [address] at eq
    exact eq
  have writer := represented_at values splits r entries related j (by omega)
  have faces := BranchTypeRowImages.interface matrix _ (row j jb).1 values
  have argumentOne : E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) j)) = 1 := by
    have h := faces.scratchWrite.symm.trans writer.2.1
    simpa only [jw,Bool.toNat_true,Semiring.natCast_one] using h
  have writerMask := BranchTypeGuards.flag_one (F := F) _ ((masks j jb).argument.symm.trans argumentOne)
  have writerKind : (rows.getD j default).kind = .pop ∧ ops.getD j 0 = 14 := by
    have h := (Bool.and_eq_true_iff.mp writerMask).1
    simpa only [BranchTypePending.selected,decide_eq_true_eq] using h
  exact ⟨loaded.1,j,ji,location,writerKind.1,writerKind.2,Fin.ext tags⟩

#print axioms represented_at
#print axioms sound
end ZkBuild.BranchTypeRestoration
