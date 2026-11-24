import NameSourceHeaders
set_option autoImplicit false
namespace ZkBuild.NameSourceFlatFacts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def FrameImage {F : Type} [Field F] (values : Nat → F) (f : NameFrameMatrix.ByteRow) (d : ChildValue) : Prop :=
  E values (NameFrameMatrix.bget f 0) = (d.active.toNat : F) ∧ E values (NameFrameMatrix.bget f 1) = (d.owner : F) ∧
  E values (NameFrameMatrix.bget f 2) = (d.ordinal : F) ∧ E values (NameFrameMatrix.bget f 3) = (d.start : F) ∧
  E values (NameFrameMatrix.bget f 4) = (d.finish : F)

def RowMeaning {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (b : ByteRow) (d : ChildValue) : Prop :=
  ∃ bytes, RepWire values bank b.rootQuery.value bytes ∧ Utf8Suffix.Valid bytes ∧
    RepWire values bank b.nodeQuery.address (bytes.drop d.ordinal) ∧
    RepWire values bank (field b 1) (bytes.drop (d.ordinal+1)) ∧
    E values (field b 0) = (bytes.getD d.ordinal 0 : F) ∧ d.ordinal < bytes.length

theorem root_bank (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true) :
    ReadOnlyMatrix.check matrix (NameSourceMatrix.table tables source 2) = true ∧
    (NameSourceMatrix.table tables source 2).entries = (frame.headers.zip source.headers).zipIdx.map (fun ((f,h),i) => rootEntry f h i) ∧
    (NameSourceMatrix.table tables source 2).queries = source.bytes.map ByteRow.rootQuery := by
  have facts := metadata matrix tokens tables frame graph source checked
  have size : source.tables.length = 3 := by have t := facts.2.2.2.1; simpa [flat] using t
  have im : source.tables.getD 2 0 ∈ source.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by omega)
  have member : NameSourceMatrix.table tables source 2 ∈ tables := by
    unfold NameSourceMatrix.table; rw [← List.getElem_eq_getD default]; exact List.getElem_mem (facts.2.2.2.2.1 _ im)
  have data := facts.2.2.2.2.2.2.2.2
  simp only [flat,↓reduceIte] at data
  exact ⟨List.all_eq_true.mp tableChecks _ member,data.2.2.1,data.2.2.2⟩

theorem query_root {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (b : ByteRow) (member : b ∈ source.bytes) (active : E values b.rootQuery.active = 1) :
    ∃ bytes, RepWire values (NameGraphMatrix.table tables graph 0) b.rootQuery.value bytes ∧ Utf8Suffix.Valid bytes := by
  obtain ⟨checked,entries,queries⟩ := root_bank matrix tokens tables tableChecks frame flat graph source sourceCheck
  have qm : b.rootQuery ∈ (NameSourceMatrix.table tables source 2).queries := by rw [queries]; exact List.mem_map.mpr ⟨b,member,rfl⟩
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ checked values oneValue satisfied
  obtain ⟨entry,em,_,_,value⟩ := lookup b.rootQuery qm active
  rw [entries] at em
  obtain ⟨pair,pm,same⟩ := List.mem_map.mp em
  have pairMem : pair.1 ∈ frame.headers.zip source.headers := by
    have z := List.mem_zipIdx pm
    rw [z.2.2]
    exact List.getElem_mem _
  have hm := (zip_members frame.headers source.headers pair.1.1 pair.1.2 pairMem).2
  obtain ⟨bytes,rep,valid⟩ := root_rep matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied _ hm
  have equal : E values b.rootQuery.value = E values pair.1.2.head := by simpa only [← same,rootEntry] using value.symm
  exact ⟨bytes,rep_transfer values _ pair.1.2.head b.rootQuery.value bytes equal.symm rep,valid⟩

theorem same_flag {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) (po pt : Linear)
    (checked : checkByte matrix tokens true f b i po pt = true) (positive : 0 < i)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (owner prior : Nat) (ob : owner < 2^32) (pb : prior < 2^32)
    (active : E values (NameFrameMatrix.bget f 0) = 1)
    (oi : E values (NameFrameMatrix.bget f 1) = (owner : F)) (pi : E values po = (prior : F)) :
    E values (field b 2) = (if owner = prior then 1 else 0) := by
  have all := byte_holds matrix tokens true f b i po pt checked values satisfied
  have ne : i ≠ 0 := by omega
  have zs := zero_sound values oneValue (sub (NameFrameMatrix.bget f 1) po) (wire b.zeroStart) (wire (b.zeroStart+1)) (by
    intro g gm
    apply all g
    simp only [byteGates,↓reduceIte,ne,List.mem_append]
    exact Or.inr (Or.inl (Or.inr (Or.inl gm))))
  have zeroIff : E values (sub (NameFrameMatrix.bget f 1) po) = 0 ↔ owner = prior := by
    rw [eval_sub,oi,pi]
    constructor
    · intro h; apply DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega); grind
    · intro h; rw [h]; grind
  simp only [zeroIff] at zs
  have mul := multiply_sound values (NameFrameMatrix.bget f 0) (wire b.zeroStart) (field b 2) (all _ (by simp [byteGates,ne]))
  rw [mul,active,zs]
  simp only [Semiring.one_mul]

theorem head_first {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) (po pt : Linear)
    (checked : checkByte matrix tokens true f b i po pt = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (NameFrameMatrix.bget f 0) = 1) (first : E values (field b 2) = 0) :
    E values b.nodeQuery.address = E values b.rootQuery.value := by
  have all := byte_holds matrix tokens true f b i po pt checked values satisfied
  have gate := all (gate (sub (NameFrameMatrix.bget f 0) (field b 2)) (sub b.nodeQuery.address b.rootQuery.value)) (by simp [byteGates])
  change E values (sub (NameFrameMatrix.bget f 0) (field b 2))*E values (sub b.nodeQuery.address b.rootQuery.value) = E values z at gate
  rw [eval_sub,active,first,eval_sub,z,eval_constant values oneValue] at gate
  grind

theorem head_next {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) (po pt : Linear)
    (checked : checkByte matrix tokens true f b i po pt = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (same : E values (field b 2) = 1) : E values b.nodeQuery.address = E values pt := by
  have all := byte_holds matrix tokens true f b i po pt checked values satisfied
  have gate := all (gate (field b 2) (sub b.nodeQuery.address pt)) (by simp [byteGates])
  change E values (field b 2)*E values (sub b.nodeQuery.address pt) = E values z at gate
  rw [same,eval_sub,z,eval_constant values oneValue] at gate
  grind

#print axioms query_root
#print axioms same_flag
end ZkBuild.NameSourceFlatFacts
