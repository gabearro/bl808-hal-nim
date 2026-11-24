import InstructionInfoCheck
set_option autoImplicit false
namespace ZkBuild.InstructionInfoSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Data where
  opcode : Fin (2^16)
  primary : Fin (2^32)
  secondary : Fin (2^32)
  pad : Fin (2^33)
def Image {F : Type} [Field F] (values : Nat → F) (fields : Fields) (d : Data) : Prop :=
  E values (f fields 3)=(d.opcode.val:F) ∧ E values (f fields 4)=(d.primary.val:F) ∧
  E values (f fields 5)=(d.secondary.val:F) ∧ E values (f fields 6)=(d.pad.val:F)

theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionInfoCheck.Record) (checked : InstructionInfoCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) : ∃ d, Image values r.fields d := by
  have ck := checked
  simp only [InstructionInfoCheck.check,Bool.and_eq_true_iff] at ck
  obtain ⟨op,ob,oi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ ck.1.1.1.2 values one satisfied)
  obtain ⟨a,ab,ai,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ ck.1.1.2 values one satisfied)
  obtain ⟨b,bb,bi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ ck.1.2 values one satisfied)
  obtain ⟨pad,pb,pi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix _ _ _ ck.2 values one satisfied)
  exact ⟨⟨⟨op,ob⟩,⟨a,ab⟩,⟨b,bb⟩,⟨pad,pb⟩⟩,oi,ai,bi,pi⟩

theorem packed {F : Type} [Field F] [IsCharP F scalarModulus]
    (low high otherLow otherHigh : Nat) (bits : Nat) (bitsBound : bits≤32)
    (lb : low<2^bits) (ob : otherLow<2^bits) (hb : high<2^33) (ohb : otherHigh<2^33)
    (same : ((low+2^bits*high:Nat):F)=((otherLow+2^bits*otherHigh:Nat):F)) :
    low=otherLow ∧ high=otherHigh := by
  have power : 2^bits≤2^32 := Nat.pow_le_pow_right (by decide) bitsBound
  have small (a b : Nat) (ab : a<2^bits) (bb : b<2^33) : a+2^bits*b<scalarModulus := by
    have first : 2^bits*b≤2^32*b := Nat.mul_le_mul_right b power
    have second : 2^32*b<2^32*2^33 := Nat.mul_lt_mul_of_pos_left bb (by decide)
    unfold scalarModulus; omega
  have total := small low high lb hb
  have other := small otherLow otherHigh ob ohb
  have eq := (IsCharP.natCast_eq_iff_of_lt (α:=F) scalarModulus total other).mp same
  have lo := congrArg (fun n => n % 2^bits) eq
  have hi := congrArg (fun n => n / 2^bits) eq
  have pos : 0<2^bits := Nat.two_pow_pos _
  simp [Nat.add_mod,Nat.mod_eq_of_lt lb,Nat.mod_eq_of_lt ob] at lo
  simp [Nat.add_mul_div_left,Nat.div_eq_of_lt lb,Nat.div_eq_of_lt ob,pos] at hi
  exact ⟨lo,hi⟩

structure Matches {F : Type} [Field F] (values : Nat → F) (row : InstructionStreamMatrix.Row)
    (d : InstructionEventSound.Data) : Prop where
  active : E values (f row.fields 0)=1
  address : E values (InstructionInfoCheck.key row)=((d.functionIndex.val*2^32+d.pc.val:Nat):F)
  opcode : E values (f row.fields 3)=(d.opcode.val:F)
  primary : E values (f row.fields 4)=(d.primary.val:F)
  secondary : E values (f row.fields 5)=(d.secondary.val:F)
  pad : E values (f row.fields 6)=(d.pad.val:F)

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (checked : InstructionEventCheck.checkStage matrix tables s=true)
    (sourceChecked : InstructionInfoCheck.checkStage matrix tables catalog decoders s=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i<s.events.length) (d : InstructionEventSound.Data)
    (image : InstructionEventSound.Image values (InstructionEventCheck.record tables s i) d)
    (kind : E values (f (rowAt s.events i) 0)=1) :
    ∃ row ∈ s.rows, Matches values row d := by
  have ck := sourceChecked
  simp only [InstructionInfoCheck.checkStage,Bool.and_eq_true_iff] at ck
  have ec := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)
  have begin := InstructionEventSound.begin_row matrix _ ec values one satisfied d image kind
  have iq := InstructionEventSound.query_member matrix tables s checked 11 (by simp) i ib
  obtain ⟨entry,em,ea,ek,ev⟩ := DynamicTypingSource.query_origin matrix _ _ iq.1 ck.1.1 values one satisfied
    _ iq.2 begin.infoActive
  obtain ⟨row,rm,rfl⟩ := List.mem_map.mp em
  obtain ⟨j,jb,je⟩ := List.mem_iff_getElem.mp rm
  have rd : s.rows.getD j default=row := by rw [← List.getElem_eq_getD (h:=jb) default]; exact je
  have sc := List.all_eq_true.mp ck.2 j (List.mem_range.mpr jb)
  obtain ⟨src,si⟩ := decoded matrix _ sc values one satisfied
  change Image values (s.rows.getD j default).fields src at si
  rw [rd] at si
  have pq := InstructionEventSound.query_member matrix tables s checked 12 (by simp) i ib
  have reverse : DynamicTypingMatrix.same (DynamicTypingCheck.entries (s.rows.map (fun row => InstructionInfoCheck.entry row false)))
      (DynamicTypingCheck.entries (InstructionStreamMatrix.bank tables s 12).entries)=true := by
    simpa only [DynamicTypingMatrix.same,eq_comm] using ck.1.2
  obtain ⟨actual,am,aa,ak,av⟩ := DynamicTypingSource.origin_member values _ _ reverse
    (InstructionInfoCheck.entry row false) (List.mem_map.mpr ⟨row,rm,rfl⟩)
  have active : E values (f row.fields 0)=1 := ea
  have address : E values (InstructionInfoCheck.key row)=((d.functionIndex.val*2^32+d.pc.val:Nat):F) := ek.trans begin.infoAddress
  have matched := ReadOnlySound.checked_expected matrix _ pq.1 values one satisfied _ actual pq.2 am
    begin.immediateActive (aa.symm.trans active) (begin.immediateAddress.trans (address.symm.trans ak)).symm
  have infoEq : ((src.opcode.val+2^16*src.pad.val:Nat):F)=((d.opcode.val+2^16*d.pad.val:Nat):F) := by
    have h := ev.trans begin.infoValue
    simp only [InstructionInfoCheck.entry,ite_true,eval_append,eval_scale,si.1,si.2.2.2,Ring.intCast_ofNat 65536] at h
    simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_pow,Semiring.natCast_eq_ofNat 2]
    grind only
  have immediateEq : ((src.primary.val+2^32*src.secondary.val:Nat):F)=((d.primary.val+2^32*d.secondary.val:Nat):F) := by
    have h := av.trans (matched.symm.trans begin.immediateValue)
    simp only [InstructionInfoCheck.entry,Bool.false_eq_true,ite_false,eval_append,eval_scale,si.2.1,si.2.2.1,Int.ofNat_eq_natCast,Ring.intCast_natCast] at h
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using h
  have opPad := packed (F:=F) _ _ _ _ 16 (by decide) src.opcode.isLt d.opcode.isLt src.pad.isLt d.pad.isLt infoEq
  have args := packed (F:=F) _ _ _ _ 32 (by decide) src.primary.isLt d.primary.isLt
    (Nat.lt_trans src.secondary.isLt (by decide)) (Nat.lt_trans d.secondary.isLt (by decide)) immediateEq
  exact ⟨row,rm,active,address,by simpa only [opPad.1] using si.1,
    by simpa only [args.1] using si.2.1,by simpa only [args.2] using si.2.2.1,by simpa only [opPad.2] using si.2.2.2⟩

#print axioms decoded
#print axioms packed
#print axioms selected
end ZkBuild.InstructionInfoSound
