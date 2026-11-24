import DeclarationSound
namespace ZkBuild.DeclarationStreams
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def UnsignedValue {F : Type} [Field F] (values : Nat → F) (value : Linear) (message : List Sha256.Byte) (position length : Nat) : Prop :=
  0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
    E values value = (TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) : F)

theorem function_item {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : FunctionRow) (index : Nat) (first cursor previous count : Linear)
    (accepted : checkFunction matrix tokens r index first cursor previous count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.active = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ position length, position < 2^32 ∧ UnsignedValue values r.query.value message position length ∧
      E values cursor = (position : F) ∧ E values r.cursor = ((position+length : Nat) : F) ∧
      E values r.query.address = 2*(E values first+(index : F)) ∧ E values r.count = E values count+1 := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1
  have tm := shape.2.2
  have member : token tokens r.byteToken ∈ tokens := by rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.1
  obtain ⟨position,length,pb,positive,short,inside,pi,li,vi⟩ := TokenApplications.active_value matrix _
    (EnvelopeChain.token_checked matrix tokens checks _ shape.1) values oneValue satisfied 1 (by decide) tm.1 (by rw [tm.2.1]; exact active) message (decoded _ member)
  have image : E values cursor = (position : F) := by simpa only [tm.2.2.1] using pi
  have holds := MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp accepted).2 values satisfied
  have qg := multiply_sound values r.active (scale (first++n index) 2) r.query.address (holds _ (by simp only [functionGates,queryGate,List.mem_append,List.mem_cons,List.mem_singleton]; grind))
  have cg := equality_sound values oneValue r.cursor (cursor++(token tokens r.byteToken).length) (holds _ (List.mem_append_right _ (by simp)))
  have countg := equality_sound values oneValue r.count (count++r.active) (holds _ (List.mem_append_right _ (by simp)))
  have cimage : E values r.cursor = ((position+length : Nat) : F) := by
    rw [cg]
    have add := FullMatrix.eval_append values cursor (token tokens r.byteToken).length
    change E values (cursor++(token tokens r.byteToken).length) = E values cursor+E values (token tokens r.byteToken).length at add
    rw [add,image,li,Semiring.natCast_add]
  have key : E values r.query.address = 2*(E values first+(index : F)) := by
    rw [qg,active]
    have scaled := FullMatrix.eval_scale values (first++n index) 2
    change E values (scale (first++n index) 2) = ((2 : Int) : F)*E values (first++n index) at scaled
    have add := FullMatrix.eval_append values first (n index)
    change E values (first++n index) = E values first+E values (n index) at add
    have ni : E values (n index) = (index : F) := (eval_constant values oneValue (Int.ofNat index)).trans (Ring.intCast_natCast index)
    rw [scaled,add,ni]
    have two : ((2 : Int) : F) = (2 : F) := (Ring.intCast_natCast 2).trans (Semiring.natCast_eq_ofNat 2)
    change (1 : F)*(((2 : Int) : F)*(E values first+(index : F))) = 2*(E values first+(index : F))
    rw [two,Semiring.one_mul]
  have ci : E values r.count = E values count+1 := by
    rw [countg]
    have add := FullMatrix.eval_append values count r.active
    change E values (count++r.active) = E values count+E values r.active at add
    rw [add,active]
  exact ⟨position,length,pb,⟨positive,by simpa [BinaryTokenMatrix.capacity] using short,inside,by simpa [tm.2.2.2] using vi⟩,image,cimage,key,ci⟩

theorem tag_item {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : TagRow) (cursor : Linear) (accepted : checkTag matrix tokens r cursor = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.active = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ position length, position < message.length ∧ (message.getD position 0).toNat = 0 ∧
      UnsignedValue values r.typeIndex message (position+1) length ∧
      E values cursor = (position : F) ∧ E values r.cursor = ((position+1+length : Nat) : F) := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1
  have attr := shape.2.2.1
  have index := shape.2.2.2
  have am : token tokens r.attributeToken ∈ tokens := by rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.1
  have im : token tokens r.indexToken ∈ tokens := by rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.1
  obtain ⟨position,attrLength,result⟩ := decoded _ am
  have posImage : E values cursor = (position : F) := by simpa only [attr.2.2.1] using result.2.2.1
  have attrValue : E values (token tokens r.attributeToken).value = ((0 : Nat) : F) := by rw [attr.2.2.2]; simp [z,eval_constant values oneValue]
  have byte := TokenApplications.byte_value matrix _ (EnvelopeChain.token_checked matrix tokens checks _ shape.1) values oneValue satisfied attr.1
    (by rw [attr.2.1]; exact active) message position 0 result.1 (by decide) result.2.2.1 attrValue ⟨position,attrLength,result⟩
  obtain ⟨pos,length,pb,positive,short,inside,pi,li,vi⟩ := TokenApplications.active_value matrix _
    (EnvelopeChain.token_checked matrix tokens checks _ shape.2.1) values oneValue satisfied 1 (by decide) index.1 (by rw [index.2.1]; exact active) message (decoded _ im)
  have holds := MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp accepted).2 values satisfied
  have pg := multiply_sound values r.active (cursor++o) r.position (holds _ (by simp only [tagGates,List.mem_append,List.mem_cons,List.mem_singleton]; grind))
  have indexImage : E values r.position = (pos : F) := by simpa [index.2.2.1] using pi
  have add := FullMatrix.eval_append values cursor o
  change E values (cursor++o) = E values cursor+E values o at add
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [active,add,posImage,one,indexImage] at pg
  have natImage : (pos : F) = ((position+1 : Nat) : F) := by simp only [Semiring.natCast_add,Semiring.natCast_one]; grind
  have successorSmall : position+1 < scalarModulus := by
    have b := result.1
    have big : 2^33 < scalarModulus := by decide
    omega
  have same : pos = position+1 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans pb (by decide))
    successorSmall).mp natImage
  have cg := equality_sound values oneValue r.cursor (cursor++r.active++(token tokens r.indexToken).length) (holds _ (List.mem_append_right _ (by simp)))
  have ci : E values r.cursor = ((position+1+length : Nat) : F) := by
    rw [cg]
    have add1 := FullMatrix.eval_append values (cursor++r.active) (token tokens r.indexToken).length
    have add2 := FullMatrix.eval_append values cursor r.active
    change E values (cursor++r.active++(token tokens r.indexToken).length) = E values (cursor++r.active)+E values (token tokens r.indexToken).length at add1
    change E values (cursor++r.active) = E values cursor+E values r.active at add2
    rw [add1,add2,posImage,active,li]
    simp only [Semiring.natCast_add,Semiring.natCast_one]
  exact ⟨position,length,byte.1,byte.2,⟨positive,by simpa [BinaryTokenMatrix.capacity] using short,by simpa [same] using inside,by simpa [same,index.2.2.2] using vi⟩,posImage,ci⟩

#print axioms function_item
#print axioms tag_item
end ZkBuild.DeclarationStreams
