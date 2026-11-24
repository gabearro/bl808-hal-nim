import SegmentPayloadConstants
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadSpans
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SegmentPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem data_span {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record)
    (r : Row) (start finish : Linear) (checked : checkData matrix tokens splits cs r start finish = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (f r 7) = E values (readAt r 2).cursor + E values (f r 6) ∧
      ∃ gap : Nat, gap < 2^32 ∧ E values finish = E values (f r 7)+(gap : F) := by
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have next := equality_sound values oneValue (f r 7) ((readAt r 2).cursor ++ f r 6) (all _ (by simp [dataGates]))
  have add : E values ((readAt r 2).cursor ++ f r 6) = E values (readAt r 2).cursor + E values (f r 6) := eval_append values _ _
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  obtain ⟨gap,bound,image⟩ := SegmentPayloadRead.range_bound matrix _ _ 32 rangeCheck values oneValue satisfied
  refine ⟨next.trans add,gap,bound,?_⟩
  rw [eval_sub] at image
  grind

/-- The actual custom-section query and packed span consume exactly the same
    UTF-8 name as a name reader, without adding a selector gate to the circuit. -/
theorem custom_name {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record) (graph : NameGraphMatrix.Record)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (tableCheck : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (r : Row) (sectionRow : EnvelopeMatrix.Row) (base previous : Linear)
    (checked : checkCustom matrix splits r sectionRow base previous = true)
    (member : queryAt r 0 ∈ (ImportMatrix.table tables imports 0).queries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte)
    (names : ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      NameSourceShared.BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message)
    (active : E values (f r 0) = 1) :
    ∃ p q bytes, p < 2^32 ∧ q < 2^32 ∧ NameSourceConsumers.Encoded message p q bytes ∧
      E values sectionRow.entry.body = (p : F) ∧ E values (split splits r.heads).high = (q : F) ∧
      ∃ gap : Nat, gap < 2^32 ∧ E values sectionRow.entry.finish = ((q+gap : Nat) : F) := by
  have sh := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  let use : ImportMatrix.NameUse := ⟨r.heads,queryAt r 0,(split splits r.heads).high⟩
  have useShape : ImportMatrix.nameMatches splits use (f r 0) := by
    unfold customShape at sh
    exact ⟨sh.2.2.2.2.2.2.1,sh.2.2.2.2.2.2.2.1,sh.2.2.2.2.2.2.2.2⟩
  have holds : AllHold values (ImportMatrix.nameGates splits use (f r 0) (base++previous) sectionRow.entry.body) := by
    intro g gm
    simp only [ImportMatrix.nameGates,List.mem_append,List.mem_cons,List.not_mem_nil,or_false] at gm
    rcases gm with (query | fields) | first | last
    · have eq : g = queryGate (f r 0) (base++previous) (queryAt r 0) := query
      subst g
      exact all _ (by simp [customGates,use])
    · have mem : g ∈ splitGates (split splits r.heads) := fields
      exact all g (by simp only [customGates,List.mem_append]; grind only)
    · subst g
      have h := all (gate (f r 0) (sub (split splits r.heads).low sectionRow.entry.body)) (by simp [customGates])
      change E values (f r 0)*E values (sub (split splits r.heads).low sectionRow.entry.body) = E values z at h
      change E values (f r 0)*E values (sub sectionRow.entry.body (split splits r.heads).low) = E values z
      have z0 : E values z = 0 := by simp [z,eval_constant values oneValue]
      rw [active,eval_sub,z0] at h ⊢
      grind
    · subst g
      change E values (f r 0) * E values (sub (split splits r.heads).high sectionRow.entry.body) = E values (sub (split splits r.heads).high sectionRow.entry.body)
      rw [active,Semiring.one_mul]
  obtain ⟨p,q,bytes,pb,qb,encoded,pi,qi⟩ := NameSourceConsumers.consume_name matrix tokens tables splits splitChecks imports owned frame source graph frameCheck tableCheck values oneValue satisfied message names use (f r 0) (base++previous) sectionRow.entry.body useShape member active holds
  have multiply := multiply_sound values (f r 0) (sub sectionRow.entry.finish (split splits r.heads).high) (f r 1)
    (all _ (by simp [customGates]))
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  obtain ⟨gap,bound,image⟩ := SegmentPayloadRead.range_bound matrix _ _ 32 rangeCheck values oneValue satisfied
  have high : E values (split splits r.heads).high = (q : F) := qi
  refine ⟨p,q,bytes,pb,qb,encoded,pi,high,gap,bound,?_⟩
  rw [active,Semiring.one_mul,eval_sub,high,image] at multiply
  rw [Semiring.natCast_add]
  grind

#print axioms data_span
#print axioms custom_name
end ZkBuild.SegmentPayloadSpans
