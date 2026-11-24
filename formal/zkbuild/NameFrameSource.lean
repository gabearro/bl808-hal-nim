import NameFrameFlat
import NameFrameLegacy
set_option autoImplicit false
namespace ZkBuild.NameFrameSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Framed {F : Type} [Field F] (values : Nat → F) (h : Header) (message : List Sha256.Byte) : Prop :=
  ∃ start length count finish : Nat,
    start < 2^32 ∧ count < 2^32 ∧ finish < 2^32 ∧ 0 < length ∧ length ≤ 5 ∧ start+length ≤ message.length ∧
    E values (hget h 2) = (start : F) ∧ E values (hget h 3) = ((start+length : Nat) : F) ∧
    E values (hget h 1) = (count : F) ∧ E values (hget h 4) = (finish : F) ∧
    finish = start+length+count ∧ TokenInteger.decode 1 length (fun i => (message.getD (start+i) 0).toNat) = count

theorem flat_headers {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (ownChecks : owned.all (OwnedMatrix.check matrix tables splits) = true)
    (r : NameFrameMatrix.Record) (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∀ i, i < r.headers.length → E values (hget (r.headers.getD i default) 0) = 1 → Framed values (r.headers.getD i default) message := by
  have parts := NameFrameFlat.parts matrix tokens tables imports owned r checked flat
  obtain ⟨ps,images,bounds,spans⟩ := NameFrameFlat.parent_spans matrix tokens tokenChecks tables tableChecks splits splitChecks imports owned ownChecks r checked flat values oneValue satisfied
  have sizes : (stream owned r).parents.length = r.headers.length := by
    have lengths := congrArg List.length parts.2.2.2.1
    simpa only [List.length_map] using lengths
  have valueSizes := related_length _ _ _ images
  intro i ib active
  have pb : i < (stream owned r).parents.length := by omega
  have vb : i < ps.length := by omega
  have fieldLink := congrArg (fun xs : List (List Linear) => xs.getD i []) parts.2.2.2.1
  have same : ((stream owned r).parents.getD i default).fields = parentFields (r.headers.getD i default) := by
    simpa only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem pb,
      List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some] using fieldLink
  have image := DeclarationLocations.related_at (ParentImage values) _ _ images i pb
  have fields : E values (hget (r.headers.getD i default) 0) = (if (ps.getD i default).active then 1 else 0) ∧
      E values (hget (r.headers.getD i default) 1) = ((ps.getD i default).count : F) ∧
      E values (hget (r.headers.getD i default) 3) = ((ps.getD i default).start : F) ∧
      E values (hget (r.headers.getD i default) 4) = ((ps.getD i default).finish : F) := by
    unfold ParentImage OwnedMatrix.pget at image
    rw [same] at image
    simp only [parentFields,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at image
    refine ⟨?_,image.2⟩
    have act := image.1
    cases state : (ps.getD i default).active <;> rw [state] at act <;> simpa using act
  have member : ps.getD i default ∈ ps := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem vb
  have hm : r.headers.getD i default ∈ r.headers := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have on : (ps.getD i default).active = true := by
    have f := fields.1
    rw [active] at f
    cases state : (ps.getD i default).active
    · have bad : (1 : F) = 0 := by rw [state] at f; exact f
      exact False.elim (Field.zero_ne_one bad.symm)
    · rfl
  obtain ⟨p,l,pbound,positive,lb,inside,pi,body,finish,decode⟩ := NameFrameFlat.header_framed matrix tokens tokenChecks _
    (List.all_eq_true.mp parts.2.1 _ hm) values oneValue satisfied _ (bounds _ member) on fields.1 fields.2.1 fields.2.2.1
    (spans i vb) message decoded
  exact ⟨p,l,(ps.getD i default).count,(ps.getD i default).finish,pbound,(bounds _ member).1,(bounds _ member).2.2,
    positive,lb,inside,pi,by rw [fields.2.2.1,body],fields.2.1,fields.2.2.2,finish,decode⟩

theorem legacy_headers {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (r : NameFrameMatrix.Record) (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = false)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∀ h ∈ r.headers, Framed values h message := by
  have checks := Bool.and_eq_true_iff.mp checked
  have bc : r.bytes.all (checkByte matrix tokens false) = true := by simpa only [flat] using (Bool.and_eq_true_iff.mp checks.1).2
  have lc : legacyHeaders matrix tokens r.bytes r.headers 0 0 = true := by
    have branch : r.owned = 0 ∧ legacyHeaders matrix tokens r.bytes r.headers 0 0 = true := by
      simpa only [flat,Bool.false_eq_true,↓reduceIte,Bool.and_eq_true_iff,decide_eq_true_eq] using checks.2
    exact branch.2
  intro h hm
  obtain ⟨hc,span⟩ := NameFrameLegacy.spans matrix tokens tokenChecks values oneValue satisfied r.bytes bc r.headers 0 0 lc h hm
  have sh := NameFrameRules.header_shape matrix tokens false h hc
  have ranges := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp hc).1).2
  simp only [Bool.false_eq_true,↓reduceIte,Bool.and_eq_true_iff] at ranges
  obtain ⟨finish,fb,fi,_⟩ := TokenInteger.certificate_nat values oneValue _ _ 32 (RangeUse.checked_certificate matrix (h.ranges.getD 1 default) (hget h 4) 32 ranges.2 values oneValue satisfied)
  obtain ⟨p,l,pb,positive,lb,inside,pi,bi,ci⟩ := NameFrameRules.header_read matrix tokens tokenChecks false h hc
    values oneValue satisfied (by rw [sh.2.2.2.2.2.2.2.1]; simp [o,eval_constant values oneValue]) message decoded
  let count := TokenInteger.decode 1 l (fun i => (message.getD (p+i) 0).toNat)
  have cb : count < 2^32 := by
    simpa [count,TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded
      ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 l (fun i => (message.getD (p+i) 0).toNat)))
  have fin : finish = p+l+count := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (by
    rw [← fi,span,bi,ci]
    simp only [count,Semiring.natCast_add])
  exact ⟨p,l,count,finish,pb,cb,fb,positive,lb,inside,pi,bi,ci,fi,fin,rfl⟩

#print axioms flat_headers
#print axioms legacy_headers
end ZkBuild.NameFrameSource
