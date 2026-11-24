import EnvelopeMatrix
import BinaryEnvelope
namespace ZkBuild.EnvelopeRanges
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Decoded where
  active : Bool
  id : Nat
  start : Nat
  body : Nat
  size : Nat
  finish : Nat
  firstWord : Nat
  deriving Inhabited

def Represents {F : Type} [CommRing F] (values : Nat → F) (r : Row) (d : Decoded) : Prop :=
  E values r.entry.active = (d.active.toNat : F) ∧ E values r.entry.id = (d.id : F) ∧
  E values r.entry.start = (d.start : F) ∧ E values r.entry.body = (d.body : F) ∧
  E values r.entry.size = (d.size : F) ∧ E values r.entry.finish = (d.finish : F) ∧
  E values r.entry.firstWord = (d.firstWord : F)

def Bounded (d : Decoded) : Prop :=
  d.id < 2^32 ∧ d.start < 2^32 ∧ d.body < 2^32 ∧ d.size < 2^32 ∧ d.finish < 2^32 ∧ d.firstWord < 2^32

theorem zip_at (as : List α) (bs : List β) (a : α) (b : β) (i : Nat)
    (same : as.length = bs.length) (inside : i < as.length) : (as.getD i a,bs.getD i b) ∈ as.zip bs := by
  induction as generalizing bs i with
  | nil => simp at inside
  | cons x xs ih =>
    cases bs with
    | nil => simp at same
    | cons y ys =>
      cases i with
      | zero => simp
      | succ i =>
        have found := ih ys i (by simpa using same) (by simpa using inside)
        simpa using List.mem_cons_of_mem (x,y) found

theorem field_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (r : Row) (accepted : checkRow matrix tokens r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (i : Nat) (inside : i < 6) :
    ∃ n : Nat, n < 2^32 ∧ E values ((fields r.entry).getD i []) = (n : F) := by
  have parts :
      (r.ranges.length = 6 ∧ r.idToken < tokens.length ∧ r.sizeToken < tokens.length ∧ r.wordToken < tokens.length ∧
        tokenMatches (token tokens r.idToken) 0 r.entry.active r.entry.start r.entry.id ∧
        tokenMatches (token tokens r.sizeToken) 1 r.entry.active r.sizePosition r.entry.size ∧
        tokenMatches (token tokens r.wordToken) 1 r.standard r.entry.body r.entry.firstWord ∧
        r.lookup.input = r.entry.id ∧ r.lookup.columns = 2) ∧
      ((fields r.entry).zip r.ranges).all (fun (value,range) => RangeUse.check matrix range value 32) = true ∧
      RangeUse.check matrix r.remainingRange r.remaining 32 = true ∧ RangeUse.check matrix r.rankGapRange r.rankGap 4 = true ∧
      RangeUse.check matrix r.wordGapRange r.wordGap 32 = true ∧ LookupEmbedded.check matrix r.lookup = true ∧
      LookupEmbedded.checkTable r.lookup 8 SectionPolicy.expected = true := by
    simpa only [checkRow,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  have member := zip_at (fields r.entry) r.ranges [] default i (by simpa [fields] using parts.1.1.symm) (by simpa [fields] using inside)
  have rangeCheck := List.all_eq_true.mp parts.2.1 _ member
  exact RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix _ _ 32 rangeCheck values oneValue satisfied)

theorem decode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (r : Row) (accepted : checkRow matrix tokens r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (boolean : Holds values (boolGate r.entry.active)) :
    ∃ d : Decoded, Represents values r d ∧ Bounded d := by
  obtain ⟨id,ib,ii⟩ := field_range matrix tokens r accepted values oneValue satisfied 0 (by decide)
  obtain ⟨start,sb,si⟩ := field_range matrix tokens r accepted values oneValue satisfied 1 (by decide)
  obtain ⟨body,bb,bi⟩ := field_range matrix tokens r accepted values oneValue satisfied 2 (by decide)
  obtain ⟨size,zb,zi⟩ := field_range matrix tokens r accepted values oneValue satisfied 3 (by decide)
  obtain ⟨finish,fb,fi⟩ := field_range matrix tokens r accepted values oneValue satisfied 4 (by decide)
  obtain ⟨word,wb,wi⟩ := field_range matrix tokens r accepted values oneValue satisfied 5 (by decide)
  have i : E values r.entry.id = (id : F) := by simpa [fields] using ii
  have s : E values r.entry.start = (start : F) := by simpa [fields] using si
  have b : E values r.entry.body = (body : F) := by simpa [fields] using bi
  have z : E values r.entry.size = (size : F) := by simpa [fields] using zi
  have f : E values r.entry.finish = (finish : F) := by simpa [fields] using fi
  have w : E values r.entry.firstWord = (word : F) := by simpa [fields] using wi
  rcases boolean_sound values oneValue r.entry.active boolean with inactive | active
  · exact ⟨⟨false,id,start,body,size,finish,word⟩,⟨by simpa using inactive,i,s,b,z,f,w⟩,ib,sb,bb,zb,fb,wb⟩
  · exact ⟨⟨true,id,start,body,size,finish,word⟩,⟨by simpa using active,i,s,b,z,f,w⟩,ib,sb,bb,zb,fb,wb⟩

def span (d : Decoded) : BinaryEnvelope.Section := ⟨d.start,d.body,d.size,d.finish⟩
def activeSpans (ds : List Decoded) : List BinaryEnvelope.Section := (ds.filter Decoded.active).map span

#print axioms decode
end ZkBuild.EnvelopeRanges
