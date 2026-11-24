import SegmentPayloadRead
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadConstants
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SegmentPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem legacy_member (cs : List ConstantSourceMatrix.Record) (r : Row) (ids : List Nat) (cursor : Linear)
    (linked : legacyLinks cs r ids cursor) (i : Nat) (member : i ∈ ids) :
    ∃ start, constLink cs r i o (bit r 2) start := by
  induction ids generalizing cursor with
  | nil => simp at member
  | cons h rest ih =>
    rcases List.mem_cons.mp member with same | later
    · subst i; exact ⟨cursor,linked.1⟩
    · exact ih (constEnd cs r h) linked.2 later

theorem row_constant (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record)
    (flat : Bool) (kind : Nat) (r : Row) (start finish : Linear)
    (checked : SegmentPayloadRead.rowCheck matrix tokens splits cs flat kind r start finish = true)
    (i : Nat) (inside : i < r.constants.length) : constAt cs r i ∈ cs := by
  have sh := SegmentPayloadRead.shape matrix tokens splits cs flat kind r start finish checked
  have bound : r.constants.getD i 0 < cs.length := by
    by_cases k : kind = 0
    · have e : elementShape tokens splits cs flat r start := by simpa only [k,ite_true] using sh
      have first : constLink cs r 0 (sub (f r 0) (bit r 0)) o (readAt r 1).cursor := by unfold elementShape at e; grind only
      by_cases firstIndex : i = 0
      · subst i; exact first.2.1
      · cases fl : flat with
        | true => have size : r.constants.length = 1 := by unfold elementShape at e; simp only [fl,ite_true] at e; grind only
                  omega
        | false =>
          have ll : legacyLinks cs r ((List.range r.constants.length).drop 1) (readAt r 3).cursor := by unfold elementShape at e; grind only
          have mem : i ∈ (List.range r.constants.length).drop 1 := by simp; omega
          obtain ⟨s,link⟩ := legacy_member cs r _ _ ll i mem
          exact link.2.1
    · have d : dataShape tokens cs r start := by simpa only [k,ite_false] using sh
      have size : r.constants.length = 1 := by unfold dataShape at d; grind only
      have first : constLink cs r 0 (sub (f r 0) (f r 2)) o (readAt r 1).cursor := by unfold dataShape at d; grind only
      have same : i = 0 := by omega
      subst i; exact first.2.1
  unfold constAt
  rw [← List.getElem_eq_getD default]
  exact List.getElem_mem bound

theorem item_constant (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (r : Row)
    (checked : checkItem matrix tokens splits cs r = true) : constAt cs r 0 ∈ cs := by
  have sh := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have link : constLink cs r 0 (f r 0) (f r 5) (f r 3) := by unfold itemShape at sh; grind only
  unfold constAt
  rw [← List.getElem_eq_getD default]
  exact List.getElem_mem link.2.1

#print axioms row_constant
#print axioms item_constant
end ZkBuild.SegmentPayloadConstants
