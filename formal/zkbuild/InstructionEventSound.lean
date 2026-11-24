import InstructionEventCheck
set_option autoImplicit false
namespace ZkBuild.InstructionEventSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix InstructionEventCheck
attribute [local instance] Ring.intCast Semiring.natCast

structure Data where
  functionIndex : Fin (2^32)
  pc : Fin (2^32)
  opcode : Fin (2^16)
  primary : Fin (2^32)
  secondary : Fin (2^32)
  pad : Fin (2^33)

def Image {F : Type} [Field F] (values : Nat → F) (r : InstructionEventCheck.Record) (d : Data) : Prop :=
  E values (f r.row 1)=(d.functionIndex.val:F) ∧ E values (f r.row 2)=(d.pc.val:F) ∧
  E values (f r.row 3)=(d.opcode.val:F) ∧ E values (f r.row 4)=(d.primary.val:F) ∧
  E values (f r.row 5)=(d.secondary.val:F) ∧ E values (f r.row 6)=(d.pad.val:F)

theorem natural {F : Type} [Field F] (values : Nat → F) (one : values 0=1) (k : Nat) :
    E values (n k)=(k:F) := (eval_constant values one (Int.ofNat k)).trans (Ring.intCast_natCast k)

theorem bounded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionEventCheck.Record) (checked : InstructionEventCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i<6) : ∃ v : Nat, v<2^(widths.getD i 0) ∧ E values (f r.row (i+1))=(v:F) := by
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)
  obtain ⟨v,vb,vi,_⟩ := TokenInteger.certificate_nat values one _ _ _ (RangeUse.checked_certificate matrix _ _ _ rc values one satisfied)
  exact ⟨v,vb,vi⟩

theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionEventCheck.Record) (checked : InstructionEventCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) : ∃ d, Image values r d := by
  obtain ⟨fn,fb,fi⟩ := bounded matrix r checked values one satisfied 0 (by decide)
  obtain ⟨pc,pb,pi⟩ := bounded matrix r checked values one satisfied 1 (by decide)
  obtain ⟨op,ob,oi⟩ := bounded matrix r checked values one satisfied 2 (by decide)
  obtain ⟨a,ab,ai⟩ := bounded matrix r checked values one satisfied 3 (by decide)
  obtain ⟨b,bb,bi⟩ := bounded matrix r checked values one satisfied 4 (by decide)
  obtain ⟨pad,vb,vi⟩ := bounded matrix r checked values one satisfied 5 (by decide)
  exact ⟨⟨⟨fn,fb⟩,⟨pc,pb⟩,⟨op,ob⟩,⟨a,ab⟩,⟨b,bb⟩,⟨pad,vb⟩⟩,fi,pi,oi,ai,bi,vi⟩

structure Begin {F : Type} [Field F] (values : Nat → F) (r : InstructionEventCheck.Record) (d : Data) : Prop where
  infoActive : E values r.info.active=1
  immediateActive : E values r.immediate.active=1
  infoAddress : E values r.info.address=((d.functionIndex.val*2^32+d.pc.val:Nat):F)
  immediateAddress : E values r.immediate.address=((d.functionIndex.val*2^32+d.pc.val:Nat):F)
  infoValue : E values r.info.value=((d.opcode.val+2^16*d.pad.val:Nat):F)
  immediateValue : E values r.immediate.value=((d.primary.val+2^32*d.secondary.val:Nat):F)

theorem begin_row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : InstructionEventCheck.Record) (checked : InstructionEventCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (d : Data) (image : Image values r d) (kind : E values (f r.row 0)=1) : Begin values r d := by
  have parts := checked
  simp only [InstructionEventCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have holds := OperandRowSound.includes_sound matrix r.first r.last (gates r) parts.1.2 values satisfied
  have begin := zero_sound values one (sub (f r.row 0) (n 1)) r.begin r.beginInverse
    (fun g gm => holds g (by simp only [gates,List.mem_append]; exact Or.inl (Or.inl gm)))
  have active : E values r.begin=1 := by
    have zero : E values (sub (f r.row 0) (n 1))=0 := by
      rw [eval_sub,kind,natural values one,Semiring.natCast_one]; grind only
    simpa only [zero,ite_true] using begin
  have fields := SourceProgramSound.normalized_inputs values _ _ parts.1.1.2.2
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true,active] at fields
  have address (which : Linear) (member : mulGate r.begin (key r) which ∈ gates r) :
      E values which=((d.functionIndex.val*2^32+d.pc.val:Nat):F) := by
    have eq := (holds _ member).symm
    change E values which=E values r.begin*E values (key r) at eq
    simp only [active,Semiring.one_mul,key,eval_append,eval_scale,image.1,image.2.1] at eq
    simp only [Int.ofNat_eq_natCast,Ring.intCast_natCast] at eq
    simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_pow]
    grind only
  have info := holds (gate r.begin (sub (sub r.info.value (f r.row 3)) (scale (f r.row 6) 65536))) (by simp [gates])
  have immediate := holds (gate r.begin (sub (sub r.immediate.value (f r.row 4)) (scale (f r.row 5) (Int.ofNat (2^32))))) (by simp [gates])
  change E values r.begin*E values (sub (sub r.info.value (f r.row 3)) (scale (f r.row 6) 65536))=E values z at info
  change E values r.begin*E values (sub (sub r.immediate.value (f r.row 4)) (scale (f r.row 5) (Int.ofNat (2^32))))=E values z at immediate
  have zero : E values z=0 := by simpa only [z,Ring.intCast_zero] using eval_constant values one 0
  simp only [active,Semiring.one_mul,eval_sub,eval_scale,image.2.2.1,image.2.2.2.1,image.2.2.2.2.1,image.2.2.2.2.2,zero,
    Int.ofNat_eq_natCast,Ring.intCast_natCast,Ring.intCast_ofNat 65536] at info immediate
  refine ⟨fields.1,fields.2.1,address _ (by simp [gates]),address _ (by simp [gates]),?_,?_⟩
  all_goals simp only [Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_pow,Semiring.natCast_eq_ofNat 2]
  · grind only
  · grind only

theorem function_end {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : InstructionEventCheck.Record) (checked : InstructionEventCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (d : Data) (image : Image values r d) (kind : E values (f r.row 0)=((8:Nat):F)) :
    E values r.finish.active=1 ∧ E values r.finish.address=(d.functionIndex.val:F) ∧
      E values r.finish.value=(d.pc.val:F) := by
  have parts := checked
  simp only [InstructionEventCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have holds := OperandRowSound.includes_sound matrix r.first r.last (gates r) parts.1.2 values satisfied
  have ending := zero_sound values one (sub (f r.row 0) (n 8)) r.ending r.endInverse
    (fun g gm => holds g (by simp only [gates,List.mem_append]; exact Or.inl (Or.inr gm)))
  have active : E values r.ending=1 := by
    have zero : E values (sub (f r.row 0) (n 8))=0 := by
      rw [eval_sub,kind,natural values one]; grind only
    simpa only [zero,ite_true] using ending
  have fields := SourceProgramSound.normalized_inputs values _ _ parts.1.1.2.2
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true,active] at fields
  have address := (holds (mulGate r.ending (f r.row 1) r.finish.address) (by simp [gates])).symm
  change E values r.finish.address=E values r.ending*E values (f r.row 1) at address
  have finish := holds (gate r.ending (sub r.finish.value (f r.row 2))) (by simp [gates])
  change E values r.ending*E values (sub r.finish.value (f r.row 2))=E values z at finish
  simp only [active,image.1,Semiring.one_mul] at address
  simp only [active,eval_sub,image.2.1,z,eval_constant values one,Ring.intCast_zero] at finish
  exact ⟨fields.2.2,address,by grind only⟩

theorem query_member (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (checked : checkStage matrix tables s=true) (family : Nat) (fm : family ∈ [11,12,1])
    (i : Nat) (ib : i<s.events.length) :
    ReadOnlyMatrix.check matrix (InstructionStreamMatrix.bank tables s family)=true ∧
    tailQuery tables s family i ∈ (InstructionStreamMatrix.bank tables s family).queries := by
  have ck := Bool.and_eq_true_iff.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2 family fm)
  have size := _root_.of_decide_eq_true ck.1
  refine ⟨ck.2,?_⟩
  unfold tailQuery
  rw [← List.getElem_eq_getD (h:=by omega) default]
  exact List.getElem_mem (by omega)

def Ends {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (s : InstructionStreamMatrix.Record) : Prop :=
  ∀ i, i<s.events.length → E values (f (rowAt s.events i) 0)=((8:Nat):F) →
    ∃ d : Data, Image values (record tables s i) d ∧
      ∃ entry ∈ (InstructionStreamMatrix.bank tables s 1).entries,
        E values entry.active=1 ∧ E values entry.address=(d.functionIndex.val:F) ∧ E values entry.value=(d.pc.val:F)

/-- Every function-end event reads the recorded endpoint of its own function. -/
theorem ends {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (checked : checkStage matrix tables s=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) : Ends values tables s := by
  intro i ib kind
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)
  obtain ⟨d,di⟩ := decoded matrix _ rc values one satisfied
  have finish := function_end matrix _ rc values one satisfied d di kind
  have query := query_member matrix tables s checked 1 (by simp) i ib
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _ query.1 values one satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership _ query.2 finish.1
  exact ⟨d,di,entry,em,ea,ek.trans finish.2.1,ev.trans finish.2.2⟩

#print axioms function_end
#print axioms ends
#print axioms bounded
#print axioms decoded
#print axioms begin_row
#print axioms query_member
end ZkBuild.InstructionEventSound
