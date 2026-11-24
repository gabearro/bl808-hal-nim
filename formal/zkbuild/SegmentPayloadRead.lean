import SegmentPayloadSound
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SegmentPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def rowCheck (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record)
    (flat : Bool) (kind : Nat) (r : Row) (start finish : Linear) :=
  if kind = 0 then checkElement matrix tokens splits cs flat r start else checkData matrix tokens splits cs r start finish

def layouts (cs : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (start : Linear) : List (Nat × Linear × Linear × Linear) :=
  if kind = 0 then [(1,f r 0,f r 1,start),(1,f r 2,f r 4,(readAt r 0).cursor),
    (0,sub (bit r 0 ++ bit r 1) (f r 6),f r 9,constEnd cs r 0),(1,f r 0,f r 10,(readAt r 2).cursor)]
  else [(1,f r 0,f r 1,start),(1,f r 3,f r 5,(readAt r 0).cursor),(1,f r 0,f r 6,constEnd cs r 0)]
def layout (cs : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (start : Linear) (i : Nat) := (layouts cs kind r start).getD i default
def count (kind : Nat) := if kind = 0 then 4 else 3

theorem row_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool)
    (kind : Nat) (r : Row) (start finish : Linear) (checked : rowCheck matrix tokens splits cs flat kind r start finish = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    AllHold values (if kind = 0 then elementGates tokens splits cs flat r start else dataGates tokens splits cs r start finish) := by
  unfold rowCheck at checked
  split at checked <;> rename_i k <;> simp only [k,ite_true,ite_false]
  · exact MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  · exact MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem shape (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool)
    (kind : Nat) (r : Row) (start finish : Linear) (checked : rowCheck matrix tokens splits cs flat kind r start finish = true) :
    if kind = 0 then elementShape tokens splits cs flat r start else dataShape tokens cs r start := by
  unfold rowCheck at checked
  split at checked <;> rename_i k <;> simp only [k,ite_true,ite_false]
  · exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1
  · exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1

theorem read_shape (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool)
    (kind : Nat) (r : Row) (start finish : Linear) (checked : rowCheck matrix tokens splits cs flat kind r start finish = true)
    (i : Nat) (ib : i < count kind) : SegmentPayloadMatrix.readMatches tokens (readAt r i) (layout cs kind r start i).1
      (layout cs kind r start i).2.1 (layout cs kind r start i).2.2.2 := by
  have sh := shape matrix tokens splits cs flat kind r start finish checked
  by_cases k : kind = 0
  · subst kind
    have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [count] at ib; omega
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp only [layout,layouts,ite_true,List.getD_cons_zero,List.getD_cons_succ] <;>
      simp only [ite_true,elementShape] at sh <;> grind only
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [count,k] at ib; omega
    rcases cases with rfl | rfl | rfl <;>
      simp only [layout,layouts,k,ite_false,List.getD_cons_zero,List.getD_cons_succ] <;>
      simp only [k,ite_false,dataShape] at sh <;> grind only

theorem read_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (cs : List ConstantSourceMatrix.Record) (flat : Bool) (kind : Nat) (r : Row) (start finish : Linear)
    (all : AllHold values (if kind = 0 then elementGates tokens splits cs flat r start else dataGates tokens splits cs r start finish))
    (i : Nat) (ib : i < count kind) : AllHold values (ImportMatrix.readGates tokens (readAt r i)
      (layout cs kind r start i).2.1 (layout cs kind r start i).2.2.1 (layout cs kind r start i).2.2.2) := by
  intro g gm
  apply all g
  by_cases k : kind = 0
  · subst kind
    have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [count] at ib; omega
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp only [layout,layouts,ite_true,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [ite_true,elementGates,List.mem_append] <;> grind only
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [count,k] at ib; omega
    rcases cases with rfl | rfl | rfl <;>
      simp only [layout,layouts,k,ite_false,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [k,ite_false,dataGates,List.mem_append] <;> grind only

def Decoded {F : Type} [Field F] (values : Nat → F) (cs : List ConstantSourceMatrix.Record) (kind : Nat)
    (r : Row) (start : Linear) (message : List Sha256.Byte) (i p len : Nat) : Prop :=
  p < 2^32 ∧ 0 < len ∧ len ≤ BinaryTokenMatrix.capacity (layout cs kind r start i).1 ∧ p+len ≤ message.length ∧
    E values (layout cs kind r start i).2.2.2 = (p : F) ∧ E values (readAt r i).cursor = ((p+len : Nat) : F) ∧
    E values (layout cs kind r start i).2.2.1 =
      (TokenInteger.decode (layout cs kind r start i).1 len (fun j => (message.getD (p+j) 0).toNat) : F)

theorem active_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (kind : Nat) (r : Row) (start finish : Linear)
    (checked : rowCheck matrix tokens splits cs flat kind r start finish = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p len, BinaryTokenSound.Result values t message p len)
    (i : Nat) (ib : i < count kind) (enabled : E values (layout cs kind r start i).2.1 = 1) :
    ∃ p len, Decoded values cs kind r start message i p len := by
  have kb : (layout cs kind r start i).1 < 7 := by
    by_cases k : kind = 0
    · subst kind
      have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [count] at ib; omega
      rcases cases with rfl | rfl | rfl | rfl <;> simp [layout,layouts]
    · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [count,k] at ib; omega
      rcases cases with rfl | rfl | rfl <;> simp [layout,layouts,k]
  have sh := read_shape matrix tokens splits cs flat kind r start finish checked i ib
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  have ae := NameGraphRoots.normalized_eval values _ _ sh.2.2.1
  have pe := NameGraphRoots.normalized_eval values _ _ sh.2.2.2
  obtain ⟨p,len,pb,lp,lb,inside,pi,li,vi⟩ := TokenApplications.active_value matrix t
    (List.all_eq_true.mp tokenChecks t tm) values oneValue satisfied _ kb sh.2.1 (ae.trans enabled) message (decoded t tm)
  have all := read_holds values tokens splits cs flat kind r start finish
    (row_holds matrix tokens splits cs flat kind r start finish checked values satisfied) i ib
  have product := multiply_sound values (layout cs kind r start i).2.1 (layout cs kind r start i).2.2.1 t.value
    (all _ (by simp [ImportMatrix.readGates,t]))
  have advance := equality_sound values oneValue (readAt r i).cursor ((layout cs kind r start i).2.2.2 ++ t.length)
    (all _ (by simp [ImportMatrix.readGates,t]))
  have cursorImage := pe.symm.trans pi
  have add : E values ((layout cs kind r start i).2.2.2 ++ t.length) = E values (layout cs kind r start i).2.2.2 + E values t.length := eval_append values _ _
  refine ⟨p,len,pb,lp,lb,inside,cursorImage,?_,?_⟩
  · rw [advance,add,cursorImage,li,Semiring.natCast_add]
  · rw [enabled,Semiring.one_mul] at product
    exact product.symm.trans vi

theorem active_boolean {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (kind : Nat) (r : Row) (start finish : Linear)
    (checked : rowCheck matrix tokens splits cs flat kind r start finish = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) : E values (f r 0) = 0 ∨ E values (f r 0) = 1 := by
  have first := read_shape matrix tokens splits cs flat kind r start finish checked 0 (by unfold count; split <;> decide)
  have format : (layout cs kind r start 0).1 = 1 := by unfold layout layouts; split <;> rfl
  have activity : (layout cs kind r start 0).2.1 = f r 0 := by unfold layout layouts; split <;> rfl
  have tc := EnvelopeChain.token_checked matrix tokens tokenChecks (readAt r 0).token first.1
  have all := BinaryTokenMatrix.checked_holds matrix _ tc values satisfied
  have fmt := first.2.1.trans format
  have flag := boolean_sound values oneValue (EnvelopeMatrix.token tokens (readAt r 0).token).activeMode (all _ (by simp [BinaryTokenMatrix.gates,BinaryTokenMatrix.prologue,fmt]))
  have same : E values (EnvelopeMatrix.token tokens (readAt r 0).token).activeMode = E values (f r 0) :=
    (NameGraphRoots.normalized_eval values _ _ first.2.2.1).trans (by rw [activity])
  rw [same] at flag
  exact flag

theorem range_bound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : RangeUse.Record) (value : Linear) (width : Nat)
    (checked : checkRange matrix r value width = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) := by
  have parts := Bool.and_eq_true_iff.mp checked
  obtain ⟨n,bound,image⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r _ width parts.1 values oneValue satisfied)
  have same := NameGraphRoots.normalized_eval values _ _ (_root_.of_decide_eq_true parts.2)
  exact ⟨n,bound,same.symm.trans image⟩

theorem flags {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool)
    (kind : Nat) (r : Row) (start finish : Linear) (checked : rowCheck matrix tokens splits cs flat kind r start finish = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < (if kind = 0 then 8 else 3) ∧ E values (f r 1) = (n : F) := by
  have rc : checkRange matrix (rangeAt r 0) (f r 1) (if kind = 0 then 3 else 2) = true := by
    unfold rowCheck at checked
    split at checked <;> rename_i k <;> simp only [k,ite_true,ite_false]
    · exact (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
    · exact (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).2
  obtain ⟨n,nb,ni⟩ := range_bound matrix _ _ _ rc values oneValue satisfied
  by_cases k : kind = 0
  · exact ⟨n,by simpa only [k,ite_true] using nb,ni⟩
  · have bound : n < 4 := by simpa only [k,ite_false] using nb
    have all := row_holds matrix tokens splits cs flat kind r start finish checked values satisfied
    have zholds : AllHold values (zeroG r 0 (sub (f r 1) (DeclarationMatrix.n 3))) := by
      intro g gm; exact all g (by simp only [k,ite_false,dataGates,List.mem_append]; grind only)
    have zs := zero_sound values oneValue (sub (f r 1) (DeclarationMatrix.n 3)) (zero r 0) (wire (r.zeros.getD 0 0+1)) zholds
    have ze := equality_sound values oneValue (zero r 0) z (all _ (by simp [k,dataGates]))
    have no : n ≠ 3 := by
      intro eq
      have diff : E values (sub (f r 1) (DeclarationMatrix.n 3)) = 0 := by
        rw [eval_sub,ni,eq]
        have n3 : E values (DeclarationMatrix.n 3) = ((3 : Nat) : F) := by
          change E values (constant (Int.ofNat 3)) = _
          rw [eval_constant values oneValue]
          exact Ring.intCast_natCast 3
        rw [n3]; grind
      rw [zs,ite_eq_left diff] at ze
      have zz : E values z = 0 := by simp [z,eval_constant values oneValue]
      exact Field.zero_ne_one (zz.symm.trans ze.symm)
    exact ⟨n,by simp only [k,ite_false]; omega,ni⟩

#print axioms active_read
#print axioms active_boolean
#print axioms flags
end ZkBuild.SegmentPayloadRead
