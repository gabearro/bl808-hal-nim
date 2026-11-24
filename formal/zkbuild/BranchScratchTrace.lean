import BranchTypeScratch
import MemoryPriorWrite
set_option autoImplicit false
namespace ZkBuild.BranchScratchTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem row_facts {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record)
    (checked : BranchTypeRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4) = (actual.val : F))
    (entry : MemoryTrace.Entry) (represented : MemoryPacking.Represents values r.scratch entry)
    (ab : entry.address < 2^32) (vb : entry.value < 8) (ib : r.index < 2^32)
    (active : entry.active = true) :
    entry.value = actual.val ∧ (entry.write = true → entry.address = r.index) := by
  have faces := BranchTypeRowImages.interface matrix r checked values
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have sum : E values r.scratch.active =
      E values (BranchTypeRowCheck.argument r)+E values (f r.after 34) := by
    simpa only [E,eval_append] using faces.scratchActive
  have selected : E values r.scratch.active = 1 := by
    simpa only [active,Bool.toNat_true,Semiring.natCast_one] using represented.1
  have mv := m.multiply (BranchTypeRowCheck.argument r++f r.after 34) (f r.row 4) 47
    (by simp [BranchTypeRowCheck.multiplies])
  have vi : (entry.value : F) = (actual.val : F) := by
    calc
      (entry.value : F) = E values r.scratch.value := represented.2.2.2.1.symm
      _ = E values (f r.after 47) := faces.scratchValue
      _ = (E values (BranchTypeRowCheck.argument r)+E values (f r.after 34))*E values (f r.row 4) := by
        simpa only [E,eval_append] using mv
      _ = (actual.val : F) := by rw [← sum,selected,image]; grind only
  refine ⟨DeclarationLocations.natural_equal (F := F) _ _ (by omega)
    (by have := actual.isLt; omega) vi,?_⟩
  intro write
  have arg : E values (BranchTypeRowCheck.argument r) = 1 := by
    have wi := faces.scratchWrite.symm.trans represented.2.1
    simpa only [write,Bool.toNat_true,Semiring.natCast_one] using wi
  have push : E values (f r.after 34) = 0 := by rw [selected,arg] at sum; grind only
  have stored := BranchTypeScratch.stored matrix r checked values one satisfied actual image arg push
  exact DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega)
    (represented.2.2.1.symm.trans stored.2.2.1)

structure Facts (entries : List MemoryTrace.Entry) (actual : Nat → Fin 8) : Prop where
  reads : MemoryTrace.Reads (fun _ => none) entries
  value : ∀ i, i < entries.length → (entries.getD i MemoryPriorWrite.zero).active = true →
    (entries.getD i MemoryPriorWrite.zero).value = (actual i).val
  writeAddress : ∀ i, i < entries.length → (entries.getD i MemoryPriorWrite.zero).active = true →
    (entries.getD i MemoryPriorWrite.zero).write = true →
    (entries.getD i MemoryPriorWrite.zero).address = i
  readOrigin : ∀ i, i < entries.length → (entries.getD i MemoryPriorWrite.zero).active = true →
    (entries.getD i MemoryPriorWrite.zero).write = false →
    ∃ j, j < i ∧ (entries.getD i MemoryPriorWrite.zero).address = j ∧
      (entries.getD j MemoryPriorWrite.zero).active = true ∧
      (entries.getD j MemoryPriorWrite.zero).write = true ∧ (actual i).val = (actual j).val

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (memory : MemoryEmbedded.Record)
    (stage : DynamicTypingMatrix.Stage)
    (checked : BranchTypeRowCheck.checkStage matrix splits memory stage = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Nat → Fin 8)
    (images : ∀ i, i < stage.rows.length → E values (f (rowAt stage.rows i) 4) = ((actual i).val : F)) :
    ∃ entries, entries.length = stage.rows.length ∧
      ShaProgram.Related (MemoryPacking.Represents values) (memory.inputs.map MemoryEvidence.AccessRef.fields) entries ∧
      Facts entries actual := by
  have parts := checked
  simp only [BranchTypeRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  obtain ⟨entries,_,related,_,_,reads,bounds,_,_⟩ :=
    MemoryEmbedded.checked_memory matrix memory parts.1.2 values one satisfied
  have size : entries.length = stage.rows.length := by
    have h := ShaProgram.related_length _ _ _ related
    simp only [List.length_map] at h
    exact h.symm.trans parts.1.1.2.2.2.2.1
  have facts (i : Nat) (ib : i < entries.length)
      (active : (entries.getD i MemoryPriorWrite.zero).active = true) :
      (entries.getD i MemoryPriorWrite.zero).value = (actual i).val ∧
      ((entries.getD i MemoryPriorWrite.zero).write = true →
        (entries.getD i MemoryPriorWrite.zero).address = i) := by
    have sb : i < stage.rows.length := by omega
    have rc := List.all_eq_true.mp parts.2 i (List.mem_range.mpr sb)
    have mb : i < memory.inputs.length := by omega
    have represented := OperandMemorySound.related_at _ _ _ related default MemoryPriorWrite.zero i (by simpa using mb)
    have atIndex : (memory.inputs.map MemoryEvidence.AccessRef.fields).getD i default =
        (memory.inputs.getD i default).fields := by
      rw [← List.getElem_eq_getD (h := by simpa using mb) default]
      rw [← List.getElem_eq_getD (h := mb) default]
      simp only [List.getElem_map]
    rw [atIndex] at represented
    have bounded := bounds (entries.getD i MemoryPriorWrite.zero) (by
      rw [← List.getElem_eq_getD (h := ib) MemoryPriorWrite.zero]; exact List.getElem_mem ib)
    have ab : (entries.getD i MemoryPriorWrite.zero).address < 2^32 := by
      simpa only [parts.1.1.2.2.2.2.2.1] using bounded.1
    have vb : (entries.getD i MemoryPriorWrite.zero).value < 8 := by
      simpa only [parts.1.1.2.2.2.2.2.2] using bounded.2.2
    exact row_facts matrix (BranchTypeRowCheck.record splits memory stage i) rc values one satisfied
      (actual i) (images i sb) _ represented ab vb (Nat.lt_trans sb parts.1.1.2.1) active
  refine ⟨entries,size,related,reads,?_,?_,?_⟩
  · intro i ib active; exact (facts i ib active).1
  · intro i ib active write; exact (facts i ib active).2 write
  · intro i ib active read
    obtain ⟨j,ji,ja,jw,address,value⟩ := MemoryPriorWrite.empty_origin entries reads i ib active read
    have jb : j < entries.length := by omega
    have writer := facts j jb ja
    have reader := facts i ib active
    exact ⟨j,ji,address.symm.trans (writer.2 jw),ja,jw,reader.1.symm.trans (value.symm.trans writer.1)⟩

#print axioms row_facts
#print axioms sound
end ZkBuild.BranchScratchTrace
