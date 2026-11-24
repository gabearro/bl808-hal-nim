import NameFrameRules
set_option autoImplicit false
namespace ZkBuild.NameFrameFlat
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem parts (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (r : NameFrameMatrix.Record)
    (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = true) :
    r.bytes.all (checkByte matrix tokens true) = true ∧ r.headers.all (checkHeader matrix tokens true) = true ∧
      r.owned < owned.length ∧ (stream owned r).parents.map OwnedMatrix.Parent.fields = r.headers.map parentFields ∧
      (stream owned r).children.map OwnedMatrix.Child.fields = r.bytes.map ByteRow.fields := by
  have checks := Bool.and_eq_true_iff.mp checked
  have bytes := (Bool.and_eq_true_iff.mp checks.1).2
  have more := checks.2
  simp only [flat,↓reduceIte,Bool.and_eq_true_iff,decide_eq_true_eq] at more
  exact ⟨by simpa [flat] using bytes,more.1,more.2⟩

theorem unit_width {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (r : NameFrameMatrix.Record)
    (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    OwnedUnit.UnitWidth values (stream owned r).children := by
  have p := parts matrix tokens tables imports owned r checked flat
  intro child member enabled
  have included : child.fields ∈ r.bytes.map ByteRow.fields := by
    rw [← p.2.2.2.2]
    exact List.mem_map.mpr ⟨child,member,rfl⟩
  obtain ⟨b,bm,equal⟩ := List.mem_map.mp included
  have fields (i : Nat) : bget b i = OwnedMatrix.cget child i := by
    simp only [bget,OwnedMatrix.cget]; rw [equal]
  have step := NameFrameRules.byte_step matrix tokens tokenChecks true b (List.all_eq_true.mp p.1 b bm)
    values oneValue satisfied (by rw [fields]; exact enabled)
  simpa only [fields] using step

theorem parent_spans {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (ownChecks : owned.all (OwnedMatrix.check matrix tables splits) = true)
    (r : NameFrameMatrix.Record) (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ ps : List ParentValue, Related (ParentImage values) (stream owned r).parents ps ∧ (∀ p ∈ ps, ParentBound p) ∧
      ∀ i, i < ps.length → (ps.getD i default).finish = (ps.getD i default).start+(ps.getD i default).count := by
  have p := parts matrix tokens tables imports owned r checked flat
  have member : stream owned r ∈ owned := by
    unfold stream; rw [← List.getElem_eq_getD default]; exact List.getElem_mem p.2.2.1
  exact OwnedUnit.checked_parent_spans matrix tables tableChecks splits splitChecks (stream owned r)
    (List.all_eq_true.mp ownChecks _ member) values oneValue satisfied
    (unit_width matrix tokens tokenChecks tables imports owned r checked flat values oneValue satisfied)

/-- The physical header and complete byte stream share the very same count and
    span fields. The length is decoded from committed bytes, not host metadata. -/
theorem header_framed {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (h : Header) (checked : checkHeader matrix tokens true h = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ParentValue) (bound : ParentBound d) (enabled : d.active = true)
    (activity : E values (hget h 0) = if d.active then 1 else 0)
    (count : E values (hget h 1) = (d.count : F)) (bodyStart : E values (hget h 3) = (d.start : F))
    (span : d.finish = d.start+d.count) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∃ p length, p < 2^32 ∧ 0 < length ∧ length ≤ 5 ∧ p+length ≤ message.length ∧
      E values (hget h 2) = (p : F) ∧ d.start = p+length ∧ d.finish = p+length+d.count ∧
      TokenInteger.decode 1 length (fun i => (message.getD (p+i) 0).toNat) = d.count := by
  obtain ⟨p,l,pb,positive,lb,inside,pi,bi,ci⟩ := NameFrameRules.header_read matrix tokens tokenChecks true h checked
    values oneValue satisfied (by simpa [enabled] using activity) message decoded
  have start : d.start = p+l := DeclarationLocations.natural_equal (F := F) _ _
    (by have b := bound.2.1; omega) (by omega) (bodyStart.symm.trans bi)
  have decodeBound : TokenInteger.decode 1 l (fun i => (message.getD (p+i) 0).toNat) < 2^32 := by
    simpa [TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded
      ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 l (fun i => (message.getD (p+i) 0).toNat)))
  have val : TokenInteger.decode 1 l (fun i => (message.getD (p+i) 0).toNat) = d.count :=
    DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := bound.1; omega) (ci.symm.trans count)
  exact ⟨p,l,pb,positive,lb,inside,pi,start,by omega,val⟩

#print axioms unit_width
#print axioms parent_spans
#print axioms header_framed
end ZkBuild.NameFrameFlat
