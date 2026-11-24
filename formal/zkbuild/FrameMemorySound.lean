import FrameCertificate
import MemoryPriorWrite
set_option autoImplicit false
namespace ZkBuild.FrameMemorySound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem represented_at {F : Type} [Field F]
    (values : Nat → F) (memory : MemoryEmbedded.Record) (entries : List MemoryTrace.Entry)
    (related : ShaProgram.Related (MemoryPacking.Represents values) (memory.inputs.map MemoryEvidence.AccessRef.fields) entries)
    (i : Nat) (ib : i < memory.inputs.length) :
    MemoryPacking.Represents values (memory.inputs.getD i default).fields (entries.getD i MemoryPriorWrite.zero) := by
  have rep := OperandMemorySound.related_at _ _ _ related default MemoryPriorWrite.zero i (by simpa using ib)
  have point : (memory.inputs.map MemoryEvidence.AccessRef.fields).getD i default = (memory.inputs.getD i default).fields := by
    rw [← List.getElem_eq_getD (h := by simpa using ib) default,← List.getElem_eq_getD (h := ib) default]
    simp only [List.getElem_map]
  simpa only [point] using rep

theorem origin {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (memory : MemoryEmbedded.Record) (stage : DynamicTypingMatrix.Stage)
    (checked : checkStage matrix memory stage = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < stage.rows.length)
    (active : E values (readActive (record memory stage i)) = 1) :
    ∃ j, j < i ∧ E values (f (record memory stage j).flags 4) = 1 ∧
      E values (record memory stage i).read.address = E values (record memory stage j).write.address ∧
      E values (record memory stage i).read.value = E values (f (record memory stage j).after 43) := by
  have parts := checked
  simp only [checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size := parts.1.1.1.2.2.2.2.2.2.1
  obtain ⟨entries,_,related,_,_,reads,_,_,_⟩ := MemoryEmbedded.checked_memory matrix memory parts.1.1.2 values one satisfied
  have length : entries.length = 2*stage.rows.length := by
    have h := ShaProgram.related_length _ _ _ related
    simp only [List.length_map] at h
    exact h.symm.trans size
  have rc (j : Nat) (jb : j<stage.rows.length) := List.all_eq_true.mp parts.2 j (List.mem_range.mpr jb)
  have atRead := represented_at values memory entries related (2*i) (by omega)
  have faces := FrameRowImages.interface matrix _ (rc i ib) values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
  have ai : (entries.getD (2*i) MemoryPriorWrite.zero).active = true := by
    have h := (faces.1.trans active).symm.trans atRead.1
    cases b : (entries.getD (2*i) MemoryPriorWrite.zero).active
    · simp only [b,Bool.toNat_false,Semiring.natCast_zero] at h
      exact False.elim (Field.zero_ne_one h.symm)
    · rfl
  have ri : (entries.getD (2*i) MemoryPriorWrite.zero).write = false := by
    have zero : E values (record memory stage i).read.write = 0 := by
      simpa only [z,eval_constant values one,Ring.intCast_zero] using faces.2.1
    have h := zero.symm.trans atRead.2.1
    cases b : (entries.getD (2*i) MemoryPriorWrite.zero).write
    · rfl
    · simp only [b,Bool.toNat_true,Semiring.natCast_one] at h
      exact False.elim (Field.zero_ne_one h)
  obtain ⟨k,ki,ka,kw,address,value⟩ := MemoryPriorWrite.empty_origin entries reads (2*i) (by omega) ai ri
  have kb : k/2 < stage.rows.length := by omega
  have writer := represented_at values memory entries related k (by omega)
  have wf := FrameRowImages.interface matrix _ (rc (k/2) kb) values
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at wf
  have odd : k%2=1 := by
    by_cases even : k%2=0
    · have eq : k=2*(k/2) := by omega
      have zero : E values (record memory stage (k/2)).read.write = 0 := by
        simpa only [z,eval_constant values one,Ring.intCast_zero] using wf.2.1
      have wi : E values (record memory stage (k/2)).read.write = 1 := by
        have h := writer.2.1
        simp only [kw,Bool.toNat_true,Semiring.natCast_one] at h
        simpa only [record,← eq] using h
      exact False.elim (Field.zero_ne_one (zero.symm.trans wi))
    · omega
  have eq : k=2*(k/2)+1 := by omega
  have writeRep : MemoryPacking.Represents values (record memory stage (k/2)).write (entries.getD k MemoryPriorWrite.zero) := by
    simpa only [record,← eq] using writer
  have pushed : E values (f (record memory stage (k/2)).flags 4) = 1 := by
    have h := wf.2.2.2.2.2.1.symm.trans writeRep.2.1
    simpa only [kw,Bool.toNat_true,Semiring.natCast_one] using h
  have facts := FrameRowSound.meaning matrix _ (rc (k/2) kb) values one satisfied
  have val := facts.multiply (f (record memory stage (k/2)).flags 4) (f (record memory stage (k/2)).after 43) 45 (by simp [multiplies])
  rw [pushed,Semiring.one_mul] at val
  refine ⟨k/2,by omega,pushed,?_,?_⟩
  · exact atRead.2.2.1.trans ((congrArg (fun n : Nat => (n:F)) address.symm).trans writeRep.2.2.1.symm)
  · exact atRead.2.2.2.1.trans ((congrArg (fun n : Nat => (n:F)) value.symm).trans
      (writeRep.2.2.2.1.symm.trans (wf.2.2.2.2.2.2.2.1.trans val)))

#print axioms represented_at
#print axioms origin
end ZkBuild.FrameMemorySound
