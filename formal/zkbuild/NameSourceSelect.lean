import NameSourceEnd
set_option autoImplicit false
namespace ZkBuild.NameSourceSelect
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceFlatFacts NameSourceLineage NameSourceCoverage ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem header_images {F : Type} [Field F]
    (values : Nat → F) (parents : List OwnedMatrix.Parent) (ps : List ParentValue) (headers : List NameFrameMatrix.Header)
    (images : Related (ParentImage values) parents ps) (fields : parents.map OwnedMatrix.Parent.fields = headers.map NameFrameMatrix.parentFields)
    (i : Nat) (inside : i < headers.length) : i < ps.length ∧
      E values (NameFrameMatrix.hget (headers.getD i default) 0) = ((ps.getD i default).active.toNat : F) ∧
      E values (NameFrameMatrix.hget (headers.getD i default) 1) = ((ps.getD i default).count : F) ∧
      E values (NameFrameMatrix.hget (headers.getD i default) 3) = ((ps.getD i default).start : F) ∧
      E values (NameFrameMatrix.hget (headers.getD i default) 4) = ((ps.getD i default).finish : F) := by
  have len1 : parents.length = headers.length := by simpa using congrArg List.length fields
  have len2 := related_length _ _ _ images
  have pb : i < parents.length := by omega
  have vb : i < ps.length := by omega
  have pairFields := congrArg (fun xs : List (List Linear) => xs.getD i []) fields
  have same : (parents.getD i default).fields = NameFrameMatrix.parentFields (headers.getD i default) := by
    simpa only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem pb,List.getElem?_eq_getElem inside,Option.map_some,Option.getD_some] using pairFields
  have image := DeclarationLocations.related_at (ParentImage values) parents ps images i pb
  unfold ParentImage OwnedMatrix.pget at image
  rw [same] at image
  simp only [NameFrameMatrix.parentFields,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at image
  exact ⟨vb,image⟩

theorem indexed_pair (fs : List NameFrameMatrix.Header) (hs : List Header) (equal : fs.length = hs.length)
    (i : Nat) (inside : i < fs.length) :
    (((fs.getD i default),(hs.getD i default)),i) ∈ (fs.zip hs).zipIdx ∧ (fs.getD i default,i) ∈ fs.zipIdx := by
  have hb : i < hs.length := by omega
  constructor
  · have bound : i < (fs.zip hs).zipIdx.length := by simp; omega
    have member := List.getElem_mem bound
    simpa only [List.getElem_zipIdx,List.getElem_zip,Nat.zero_add,List.getD_eq_getElem?_getD,List.getElem?_eq_getElem inside,List.getElem?_eq_getElem hb,Option.getD_some] using member
  · have bound : i < fs.zipIdx.length := by simpa using inside
    have member := List.getElem_mem bound
    simpa only [List.getElem_zipIdx,Nat.zero_add,List.getD_eq_getElem?_getD,List.getElem?_eq_getElem inside,Option.getD_some] using member

theorem empty_head {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (f : NameFrameMatrix.Header) (h : Header) (checked : NameSourceMatrix.checkHeader matrix f h = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (empty : E values (NameFrameMatrix.hget f 1) = 0) : E values h.head = 0 := by
  have all := MemoryEvidence.span_sound matrix h.firstGate h.lastGate (headerGates f h) (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have zs := zero_sound values oneValue (NameFrameMatrix.hget f 1) (wire h.zeroStart) (wire (h.zeroStart+1)) (by
    intro g gm
    exact all g (by simp only [headerGates,List.mem_append]; exact Or.inl (Or.inr gm)))
  have eqn := all (gate (wire h.zeroStart) h.head) (by simp [headerGates])
  change E values (wire h.zeroStart)*E values h.head = E values z at eqn
  rw [zs,empty,ite_eq_left rfl,z,eval_constant values oneValue] at eqn
  grind

theorem meaning_at {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (f : NameFrameMatrix.Header) (h : Header) (i : Nat) (member : ((f,h),i) ∈ (frame.headers.zip source.headers).zipIdx)
    (enabled : E values (NameFrameMatrix.hget f 0) = 1) (bytes : List Nat)
    (represented : RepWire values (NameGraphMatrix.table tables graph 0) h.head bytes)
    (pair : NameFrameMatrix.ByteRow × ByteRow) (pm : pair ∈ frame.bytes.zip source.bytes)
    (d : ChildValue) (certified : Certified values (NameGraphMatrix.table tables graph 0) matrix tokens pair d)
    (active : d.active = true) (owner : d.owner = i) :
    E values (field pair.2 0) = (bytes.getD d.ordinal 0 : F) ∧ d.ordinal < bytes.length ∧
      RepWire values (NameGraphMatrix.table tables graph 0) (field pair.2 1) (bytes.drop (d.ordinal+1)) := by
  obtain ⟨image,_,⟨j,po,pt,bc⟩,meaning⟩ := certified
  have sh := byte_shape matrix tokens true pair.1 pair.2 j po pt bc
  have qa : E values pair.2.rootQuery.active = 1 := by
    have link : pair.2.rootQuery.active = NameFrameMatrix.bget pair.1 0 := by unfold NameSourceMatrix.byteShape at sh; simp only [↓reduceIte] at sh; grind only
    rw [link,image.1,active]
    simp
  have qi : E values pair.2.rootQuery.address = (i : F) := by
    have link : pair.2.rootQuery.address = NameFrameMatrix.bget pair.1 1 := by unfold NameSourceMatrix.byteShape at sh; simp only [↓reduceIte] at sh; grind only
    rw [link,image.2.1,owner]
  have value := root_query_at matrix tokens tables tableChecks frame flat graph source checked values oneValue satisfied f h i member enabled pair.2
    (zip_members frame.bytes source.bytes pair.1 pair.2 pm).2 qa qi
  obtain ⟨other,root,_,_,tail,byte,inside⟩ := meaning active
  have same := rep_unique values _ pair.2.rootQuery.value h.head other bytes value root represented
  simpa only [same] using And.intro byte (And.intro inside tail)

#print axioms header_images
#print axioms meaning_at
end ZkBuild.NameSourceSelect
