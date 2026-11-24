import NameSourceSelect
set_option autoImplicit false
namespace ZkBuild.NameSourceFlat
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceFlatFacts NameSourceLineage NameSourceCoverage NameSourceEnd NameSourceSelect ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem bound_names {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (ownChecks : owned.all (OwnedMatrix.check matrix tables splits) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (graph : NameGraphMatrix.Record) (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (source : NameSourceMatrix.Record) (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message := by
  obtain ⟨ps,ds,parentImages,parentBounds,certified,childBounds,positions,complete⟩ := checked_rows matrix tokens tokenChecks tables tableChecks splits splitChecks imports owned ownChecks frame flat frameCheck graph graphCheck source sourceCheck values oneValue satisfied
  have fp := NameFrameFlat.parts matrix tokens tables imports owned frame frameCheck flat
  have facts := metadata matrix tokens tables frame graph source sourceCheck
  have sc := (Bool.and_eq_true_iff.mp sourceCheck).2
  simp only [flat,↓reduceIte,Bool.and_eq_true_iff] at sc
  have frameByteChecks : frame.bytes.all (NameFrameMatrix.checkByte matrix tokens true) = true := by
    have checks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp frameCheck).1).2
    simpa only [flat] using checks
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  intro i ib active
  let f := frame.headers.getD i default
  let h := source.headers.getD i default
  have active : E values (NameFrameMatrix.hget f 0) = 1 := active
  have sourceLength : frame.headers.length = source.headers.length := facts.1.symm
  have members := indexed_pair frame.headers source.headers sourceLength i ib
  have pairMember : ((f,h),i) ∈ (frame.headers.zip source.headers).zipIdx := members.1
  have headerMember : (f,i) ∈ frame.headers.zipIdx := members.2
  have plainPair : (f,h) ∈ frame.headers.zip source.headers := by
    have m := List.mem_zipIdx pairMember
    rw [m.2.2]
    exact List.getElem_mem _
  have hm : h ∈ source.headers := (zip_members frame.headers source.headers f h plainPair).2
  have headerCheck := List.all_eq_true.mp sc.1 (f,h) plainPair
  have images := header_images values _ ps frame.headers parentImages fp.2.2.2.1 i ib
  have pInside := images.1
  let parent := ps.getD i default
  have pm : parent ∈ ps := by
    change ps.getD i default ∈ ps
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem pInside
  have pBound := parentBounds parent pm
  obtain ⟨p,l,count,finish,pb,cb,fb,positive,lb,headerInside,pi,bi,ci,fi,endEq,decode⟩ := NameFrameSource.flat_headers matrix tokens tokenChecks tables tableChecks splits splitChecks imports owned ownChecks frame frameCheck flat values oneValue satisfied message decoded i ib active
  change E values (NameFrameMatrix.hget f 2) = (p : F) at pi
  change E values (NameFrameMatrix.hget f 3) = ((p+l : Nat) : F) at bi
  change E values (NameFrameMatrix.hget f 1) = (count : F) at ci
  change E values (NameFrameMatrix.hget f 4) = (finish : F) at fi
  have countEq : count = parent.count := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := pBound.1; omega) (ci.symm.trans images.2.2.1)
  have startEq : parent.start = p+l := DeclarationLocations.natural_equal (F := F) _ _ (by have b := pBound.2.1; omega) (by omega) (images.2.2.2.1.symm.trans bi)
  obtain ⟨bytes,represented,valid⟩ := root_rep matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied h hm
  have size : bytes.length = count := by
    by_cases empty : count = 0
    · have zeroCount : E values (NameFrameMatrix.hget f 1) = 0 := by simpa [empty] using ci
      have zeroHead := empty_head matrix f h headerCheck values oneValue satisfied zeroCount
      have nil := rep_zero values _ h.head bytes zeroHead represented
      simp [nil,empty]
    · obtain ⟨pair,pairMem,d,cert,on,owner,ordinal,location⟩ := selected values matrix tokens _ _ ps ds childBounds certified positions complete i (count-1) pInside (by rw [← countEq]; omega)
      have meaning := meaning_at matrix tokens tables tableChecks frame flat graph source sourceCheck values oneValue satisfied f h i pairMember active bytes represented pair pairMem d cert on owner
      obtain ⟨e,em,ec⟩ := ending_member matrix frame.bytes source.bytes source.ends sc.2 pair.1 pair.2 pairMem
      have endShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ec).1).1
      have byteActive : E values (NameFrameMatrix.bget pair.1 0) = 1 := by simpa [on] using cert.1.1
      have qa : E values e.countQuery.active = 1 := by rw [endShape.1]; exact byteActive
      have qi : E values e.countQuery.address = (i : F) := by rw [endShape.2,cert.1.2.1,owner]
      have countValue := count_query_at matrix tokens tables tableChecks frame flat graph source sourceCheck values oneValue satisfied f i headerMember active e em qa qi
      have last : E values (NameFrameMatrix.bget pair.1 2 ++ o) = E values e.countQuery.value := by
        rw [add,cert.1.2.2.1,one,countValue,ci,ordinal]
        have natural : count-1+1 = count := by omega
        simpa only [Semiring.natCast_add,Semiring.natCast_one] using congrArg (fun n : Nat => (n : F)) natural
      obtain ⟨j,po,pt,bc⟩ := cert.2.2.1
      have zero := terminal matrix tokens pair.1 pair.2 e j po pt bc ec values oneValue satisfied byteActive last
      have nil := rep_zero values _ (field pair.2 1) (bytes.drop (d.ordinal+1)) zero meaning.2.2
      have upper : bytes.length ≤ count := by
        have h := List.drop_eq_nil_iff.mp nil
        omega
      have lower : count ≤ bytes.length := by have h := meaning.2.1; omega
      omega
  have matching : Matches message (p+l) bytes := by
    intro j jb
    obtain ⟨pair,pairMem,d,cert,on,owner,ordinal,location⟩ := selected values matrix tokens _ _ ps ds childBounds certified positions complete i j pInside (by rw [← countEq,← size]; exact jb)
    have meaning := meaning_at matrix tokens tables tableChecks frame flat graph source sourceCheck values oneValue satisfied f h i pairMember active bytes represented pair pairMem d cert on owner
    have pairMembers := zip_members frame.bytes source.bytes pair.1 pair.2 pairMem
    have byteCheck := List.all_eq_true.mp frameByteChecks pair.1 pairMembers.1
    have byteActive : E values (NameFrameMatrix.bget pair.1 0) = 1 := by simpa [on] using cert.1.1
    obtain ⟨position,pbound,inside,positionImage,_,value⟩ := NameFrameRules.byte_read matrix tokens tokenChecks true pair.1 byteCheck values oneValue satisfied byteActive message decoded
    have positionEq : position = d.start := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := cert.2.1.2.2.1; omega) (positionImage.symm.trans cert.1.2.2.2.1)
    have actualPosition : position = p+l+j := by rw [positionEq,location,startEq]
    obtain ⟨index,po,pt,sourceByteCheck⟩ := cert.2.2.1
    have shape := byte_shape matrix tokens true pair.1 pair.2 index po pt sourceByteCheck
    have byteImage : E values (EnvelopeMatrix.token tokens pair.1.token).value = (bytes.getD j 0 : F) := by rw [shape.2.2.1,meaning.1,ordinal]
    have bound : bytes.getD j 0 < 256 := by
      obtain ⟨head,_,_,rep⟩ := represented
      apply rep_values_bound _ head bytes rep
      rw [← List.getElem_eq_getD 0]
      exact List.getElem_mem jb
    have same : (message.getD position 0).toNat = bytes.getD j 0 := DeclarationLocations.natural_equal (F := F) _ _
      (by have b := (message.getD position 0).isLt; omega) (by omega) (value.symm.trans byteImage)
    exact ⟨by simpa [actualPosition] using inside,by simpa [actualPosition] using same⟩
  refine ⟨p,l,bytes,pb,positive,lb,headerInside,by omega,pi,bi,?_,?_,?_,represented,valid,matching⟩
  · simpa only [size] using ci
  · rw [fi,endEq,size]
  · simpa only [size] using decode

#print axioms bound_names
end ZkBuild.NameSourceFlat
