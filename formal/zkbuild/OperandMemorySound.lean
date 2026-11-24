import OperandTraceSound
set_option autoImplicit false
namespace ZkBuild.OperandMemorySound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

-- The chronological RAM trace and the operand trace share the same field
-- expressions. Bounded representation uniqueness identifies their entries.
def entry (row : OperandEvents.Row) (time : Nat) : MemoryTrace.Entry :=
  let a := OperandEvents.project row
  ⟨a.active,a.write,a.address,a.value,time⟩
def projected (rows : List OperandEvents.Row) : List MemoryTrace.Entry :=
  rows.zipIdx.map (fun (row,time) => entry row time)
def access (outputs : List Fields) (i : Nat) : MemoryPacking.Access :=
  let row := outputs.getD i []
  ⟨f row 0,f row 1,f row 2,f row 3,n i⟩

theorem flag_nat {F : Type} [CommRing F] (b : Bool) : OperandEvents.flag (F := F) b = (b.toNat : F) := by
  cases b <;> simp [OperandEvents.flag,Semiring.natCast_zero,Semiring.natCast_one]

theorem related_at {α β : Type} (r : α → β → Prop) (xs : List α) (ys : List β)
    (rel : ShaProgram.Related r xs ys) (a : α) (b : β) (i : Nat) (bound : i < xs.length) :
    r (xs.getD i a) (ys.getD i b) := by
  induction rel generalizing i with
  | nil => simp at bound
  | cons head tail ih =>
    cases i with
    | zero => exact head
    | succ i => exact ih i (by simpa using bound)

theorem checked {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (memory : MemoryEmbedded.Record)
    (valid : ValidationEventCheck.memory matrix memory s.outputs 3 = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (images : OperandTraceSound.Represents values s rows)
    (length : s.outputs.length = rows.length)
    (projections : ∀ i, i < rows.length → OperandTraceSound.Projection values s rows i) :
    MemoryTrace.Reads (fun _ => none) (projected rows) := by
  obtain ⟨chronological,sorted,actual,_,_,reads,bounds,_,clocks⟩ :=
    MemoryEmbedded.checked_memory matrix memory (Bool.and_eq_true_iff.mp valid).2 values one satisfied
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp valid).1
  obtain ⟨addressBits,valueBits,inputLength,payloads⟩ := links
  have timeBound : rows.length ≤ 2^memory.timeBits := by
    have dimensions := (Bool.and_eq_true_iff.mp valid).2
    simp only [MemoryEmbedded.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at dimensions
    have size := dimensions.2.2.2.2.2.2.1
    omega
  have relations : ShaProgram.Related (BinaryReadMemory.Image values)
      ((List.range s.outputs.length).map (access s.outputs)) chronological := by
    apply BinaryReadMemory.payload_images values _ _ _ (by simpa only [List.map_map,Function.comp_def,access] using payloads) actual
  have traceLength : chronological.length = rows.length := by
    have h := ShaProgram.related_length _ _ _ relations
    simpa [length] using h.symm
  have same : chronological = projected rows := by
    apply List.ext_getElem
    · simp [projected,traceLength]
    · intro i cb pb
      have ib : i < rows.length := by omega
      let zero : MemoryTrace.Entry := ⟨false,false,0,0,0⟩
      let empty : MemoryPacking.Access := ⟨z,z,z,z,z⟩
      have rel := related_at _ _ _ relations empty zero i (by simp [length]; exact ib)
      have index : (((List.range s.outputs.length).map (access s.outputs)).getD i empty) = access s.outputs i := by
        rw [← List.getElem_eq_getD (h := by simp [length]; exact ib) empty]
        simp
      rw [index] at rel
      have bound := bounds (chronological.getD i zero) (by
        rw [← List.getElem_eq_getD (h := cb) zero]; exact List.getElem_mem cb)
      have projection := projections i ib
      have row := images.2 i ib
      let natural := entry (rows.getD i default) i
      have canonical : MemoryPacking.Represents values (access s.outputs i) natural := by
        refine ⟨?_,?_,projection.2.2.1,projection.2.2.2,?_⟩
        · simpa only [entry,natural,MemoryPacking.Access.active,access,rowAt,OperandTraceSound.Projection,
            OperandMemorySound.flag_nat] using projection.1
        · simpa only [entry,natural,MemoryPacking.Access.write,access,rowAt,OperandTraceSound.Projection,
            OperandMemorySound.flag_nat] using projection.2.1
        · simp [access,n,eval_constant values one,Int.ofNat_eq_natCast,Ring.intCast_natCast,natural,entry]
      have represented : MemoryPacking.Represents values (access s.outputs i) (chronological.getD i zero) := by
        refine ⟨rel.1,rel.2.1,rel.2.2.1,rel.2.2.2,?_⟩
        have time := congrArg (fun xs : List Nat => xs.getD i 0) clocks
        have clock : (chronological.getD i zero).time = i := by
          have left : (chronological.map MemoryTrace.Entry.time).getD i 0 = (chronological.getD i zero).time :=
            TokenInteger.map_getD MemoryTrace.Entry.time chronological zero i
          rw [left] at time
          simpa [List.getD,cb] using time
        change E values (n i) = ((chronological.getD i zero).time : F)
        rw [clock]
        simp [n,eval_constant values one,Int.ofNat_eq_natCast,Ring.intCast_natCast]
      have small : 3+2+memory.timeBits+64 ≤ 248 := by
        have mc := (Bool.and_eq_true_iff.mp valid).2
        simp only [MemoryEmbedded.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at mc
        simpa [addressBits,valueBits] using mc.2.2.2.2.2.1
      have naturalBound : MemoryConstraints.Bounded (2^64) (2^memory.timeBits) (2^3) natural := by
        refine ⟨?_,by dsimp [natural,entry]; omega,?_⟩
        · simpa only [natural,entry,OperandEvents.bound,Nat.pow_mul] using
            OperandEvents.projected_address_bound (rows.getD i default) row.2.1 row.2.2.1
        · dsimp [natural,entry,OperandEvents.project]
          split
          · exact (rows.getD i default).valueType.isLt
          · decide
      have equal := MemoryPacking.representation_unique values 64 memory.timeBits 3 small _ _ _
        (by simpa [addressBits,valueBits] using bound) naturalBound represented canonical
      rw [← List.getElem_eq_getD (h := cb) zero] at equal
      simpa [projected,natural,entry,List.getD,ib] using equal
  rwa [same] at reads

#print axioms checked
end ZkBuild.OperandMemorySound
