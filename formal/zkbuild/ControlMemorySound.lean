import ControlTraceSound
import ControlAddressBounds
set_option autoImplicit false
namespace ZkBuild.ControlMemorySound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def entry (access : OperandEvents.Access) (time : Nat) : MemoryTrace.Entry :=
  ⟨access.active,access.write,access.address,access.value,time⟩
def rowAt (rows : List OperandEvents.Row) (ds : List Nat) (i : Nat) : MemoryTrace.Entry :=
  let j := i/2
  let row := rows.getD j default
  let before := if j = 0 then 0 else ds.getD (j-1) 0
  let height := if j = 0 then 0 else (rows.getD (j-1) default).height
  entry (if i%2 = 0 then ControlEvents.readProject before row else ControlEvents.writeProject before height row) i

def projected (rows : List OperandEvents.Row) (ds : List Nat) : List MemoryTrace.Entry :=
  (List.range (2*rows.length)).map (rowAt rows ds)

def Linked {F : Type} [Field F] (values : Nat → F) (s : Stage) (rows : List OperandEvents.Row) (ds : List Nat) : Prop :=
  ∀ i, i < 2*rows.length →
    BinaryReadMemory.Image values (OperandMemorySound.access s.outputs i) (rowAt rows ds i)

theorem linked {F : Type} [Field F]
    (values : Nat → F) (s : Stage) (rows : List OperandEvents.Row) (ds : List Nat)
    (projections : ∀ i, i < rows.length → ControlTraceSound.Projection values s (rows.getD i default)
      (if i = 0 then 0 else ds.getD (i-1) 0)
      (if i = 0 then 0 else (rows.getD (i-1) default).height) i) :
    Linked values s rows ds := by
  intro i ib
  have jb : i/2 < rows.length := by omega
  have p := projections (i/2) jb
  have evenOrOdd : i = 2*(i/2) ∨ i = 2*(i/2)+1 := by omega
  rcases evenOrOdd with even | odd
  · have rem : i%2 = 0 := by omega
    have rw : (ControlEvents.readProject (if i/2 = 0 then 0 else ds.getD (i/2-1) 0) (rows.getD (i/2) default)).write = false := by
      generalize (if i/2 = 0 then 0 else ds.getD (i/2-1) 0) = before
      unfold ControlEvents.readProject
      split <;> rfl
    simp only [BinaryReadMemory.Image,OperandMemorySound.access,rowAt,rem,ite_true,entry]
    refine ⟨?_,?_,?_,?_⟩
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← even,OperandMemorySound.flag_nat] using p.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← even,rw,Bool.toNat_false,Semiring.natCast_zero] using p.2.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← even] using p.2.2.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← even] using p.2.2.2.1
  · have rem : i%2 ≠ 0 := by omega
    simp only [BinaryReadMemory.Image,OperandMemorySound.access,rowAt,rem,ite_false,entry]
    refine ⟨?_,?_,?_,?_⟩
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← odd,OperandMemorySound.flag_nat] using p.2.2.2.2.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← odd,OperandMemorySound.flag_nat] using p.2.2.2.2.2.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← odd] using p.2.2.2.2.2.2.1
    · simpa only [ControlTraceSound.Projection,ControlRowCheck.record,ValidationEventMatrix.rowAt,← odd] using p.2.2.2.2.2.2.2

theorem bounds (rows : List OperandEvents.Row) (ds : List Nat)
    (fields : ∀ i, i < rows.length → (rows.getD i default).functionIndex < OperandEvents.bound ∧
      (rows.getD i default).height < OperandEvents.bound ∧ (rows.getD i default).floor < OperandEvents.bound)
    (depths : ∀ d ∈ ds, d < OperandEvents.bound) (length : ds.length = rows.length)
    (i : Nat) (ib : i < 2*rows.length) :
    (rowAt rows ds i).address < 2^64 ∧ (rowAt rows ds i).value < 2^33 := by
  have jb : i/2 < rows.length := by omega
  have f := fields (i/2) jb
  have before : (if i/2 = 0 then 0 else ds.getD (i/2-1) 0) < OperandEvents.bound := by
    split
    · decide
    · have db : i/2-1 < ds.length := by omega
      rw [← List.getElem_eq_getD (h := db) 0]
      exact depths _ (List.getElem_mem db)
  have height : (if i/2 = 0 then 0 else (rows.getD (i/2-1) default).height) < OperandEvents.bound := by
    split
    · decide
    · exact (fields (i/2-1) (by omega)).2.1
  unfold rowAt
  split
  · exact ControlAddressBounds.read_bounds _ _ before f.1 f.2.2
  · exact ControlAddressBounds.write_bounds _ _ _ before height f.1 f.2.2

theorem reads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (memory : MemoryEmbedded.Record)
    (valid : ValidationEventCheck.memory matrix memory s.outputs 33 = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (ds : List Nat)
    (outputs : s.outputs.length = 2*rows.length) (length : ds.length = rows.length)
    (fields : ∀ i, i < rows.length → (rows.getD i default).functionIndex < OperandEvents.bound ∧
      (rows.getD i default).height < OperandEvents.bound ∧ (rows.getD i default).floor < OperandEvents.bound)
    (depths : ∀ d ∈ ds, d < OperandEvents.bound) (images : Linked values s rows ds) :
    MemoryTrace.Reads (fun _ => none) (projected rows ds) := by
  obtain ⟨chronological,sorted,actual,_,_,reads,nb,_,clocks⟩ :=
    MemoryEmbedded.checked_memory matrix memory (Bool.and_eq_true_iff.mp valid).2 values one satisfied
  have parts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp valid).1
  obtain ⟨addressBits,valueBits,inputLength,payloads⟩ := parts
  have rel : ShaProgram.Related (BinaryReadMemory.Image values)
      ((List.range s.outputs.length).map (OperandMemorySound.access s.outputs)) chronological := by
    apply BinaryReadMemory.payload_images values _ _ _ (by
      simpa only [List.map_map,Function.comp_def,OperandMemorySound.access] using payloads) actual
  have size : chronological.length = 2*rows.length := by
    have same := ShaProgram.related_length _ _ _ rel
    simpa [outputs] using same.symm
  have timeBound : 2*rows.length ≤ 2^memory.timeBits := by
    have mc := (Bool.and_eq_true_iff.mp valid).2
    simp only [MemoryEmbedded.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at mc
    have eq := mc.2.2.2.2.2.2.1
    omega
  have small : 33+2+memory.timeBits+64 ≤ 248 := by
    have mc := (Bool.and_eq_true_iff.mp valid).2
    simp only [MemoryEmbedded.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at mc
    simpa [addressBits,valueBits] using mc.2.2.2.2.2.1
  have same : chronological = projected rows ds := by
    apply List.ext_getElem
    · simp [projected,size]
    · intro i cb pb
      have ib : i < 2*rows.length := by omega
      let zero : MemoryTrace.Entry := ⟨false,false,0,0,0⟩
      let empty : MemoryPacking.Access := ⟨z,z,z,z,z⟩
      have actualImage := OperandMemorySound.related_at _ _ _ rel empty zero i (by simp [outputs]; exact ib)
      have index : (((List.range s.outputs.length).map (OperandMemorySound.access s.outputs)).getD i empty) = OperandMemorySound.access s.outputs i := by
        rw [← List.getElem_eq_getD (h := by simp [outputs]; exact ib) empty]
        simp
      rw [index] at actualImage
      have bound := nb (chronological.getD i zero) (by rw [← List.getElem_eq_getD (h := cb) zero]; exact List.getElem_mem cb)
      have clock : (chronological.getD i zero).time = i := by
        have time := congrArg (fun xs : List Nat => xs.getD i 0) clocks
        have left : (chronological.map MemoryTrace.Entry.time).getD i 0 = (chronological.getD i zero).time :=
          TokenInteger.map_getD MemoryTrace.Entry.time chronological zero i
        rw [left] at time
        simpa [List.getD,cb] using time
      have canonical := images i ib
      have naturalBound := bounds rows ds fields depths length i ib
      have clockValue : E values (OperandMemorySound.access s.outputs i).clock = (i : F) := by
        simp [OperandMemorySound.access,n,eval_constant values one,Int.ofNat_eq_natCast,Ring.intCast_natCast]
      have time : (rowAt rows ds i).time = i := by unfold rowAt; split <;> rfl
      have equal := MemoryPacking.representation_unique values 64 memory.timeBits 33 small (OperandMemorySound.access s.outputs i)
        (chronological.getD i zero) (rowAt rows ds i)
        (by simpa [addressBits,valueBits] using bound)
        ⟨naturalBound.1,by rw [time]; omega,naturalBound.2⟩
        ⟨actualImage.1,actualImage.2.1,actualImage.2.2.1,actualImage.2.2.2,by rw [clock]; exact clockValue⟩
        ⟨canonical.1,canonical.2.1,canonical.2.2.1,canonical.2.2.2,by rw [time]; exact clockValue⟩
      rw [← List.getElem_eq_getD (h := cb) zero] at equal
      simpa [projected] using equal
  rwa [same] at reads

#print axioms bounds
#print axioms reads

#print axioms linked
end ZkBuild.ControlMemorySound
