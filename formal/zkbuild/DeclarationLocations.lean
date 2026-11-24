import DeclarationCounts

namespace ZkBuild.DeclarationLocations
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def startField (params : Bool) : Nat := if params then 2 else 3
def countField (params : Bool) : Nat := if params then 5 else 6
def vectorStart (params : Bool) (d : DeclarationType.Decoded) : Nat := if params then d.paramsStart else d.resultsStart
def arity (params : Bool) (d : DeclarationType.Decoded) : Nat := if params then d.params else d.results

theorem related_at {α β : Type} [Inhabited α] [Inhabited β] (relation : α → β → Prop)
    (xs : List α) (ys : List β) (images : Related relation xs ys) (i : Nat) (bound : i < xs.length) :
    relation (xs.getD i default) (ys.getD i default) := by
  induction images generalizing i with
  | nil => simp at bound
  | cons head tail ih =>
    cases i with
    | zero => simpa using head
    | succ i => exact ih i (by simpa using bound)

theorem natural_equal {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 2^64) (bb : b < 2^64) (same : (a : F) = (b : F)) : a = b := by
  have large : 2^64 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp same

theorem packed_unique (a b c d : Nat) (ab : a < 2^32) (cb : c < 2^32)
    (same : a+2^32*b = c+2^32*d) : a = c ∧ b = d := by
  have low := congrArg (fun n => n % 2^32) same
  have high := congrArg (fun n => n / 2^32) same
  simp [Nat.add_mod,Nat.mod_eq_of_lt ab,Nat.mod_eq_of_lt cb] at low
  simp [Nat.add_mul_div_left,Nat.div_eq_of_lt ab,Nat.div_eq_of_lt cb] at high
  exact ⟨low,high⟩

theorem arity_bound (params : Bool) (d : DeclarationType.Decoded) (bound : DeclarationType.Bounded d) :
    arity params d < 2^32 ∧ vectorStart params d < 2^32 := by
  cases params <;> constructor <;> apply bound <;> simp [arity,vectorStart,DeclarationType.numbers]

theorem field_images {F : Type} [CommRing F] (values : Nat → F) (params : Bool)
    (row : TypeRow) (d : DeclarationType.Decoded) (image : DeclarationType.Represents values row d) :
    E values (get row.fields (startField params)) = (vectorStart params d : F) ∧
    E values (get row.fields (countField params)) = (arity params d : F) := by
  cases params
  · exact ⟨image.2.2.2.1,image.2.2.2.2.2.2⟩
  · exact ⟨image.2.2.1,image.2.2.2.2.2.1⟩

/-- A successful immutable location lookup selects the actual source type row,
    and both halves of its vector span agree as natural numbers. -/
theorem location_binding {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (rows : List TypeRow) (types : List DeclarationType.Decoded)
    (params : Bool) (table : ReadOnlyMatrix.Record) (query : Entry)
    (checked : ReadOnlyMatrix.check matrix table = true)
    (entries : table.entries = locations rows (startField params) (countField params))
    (member : query ∈ table.queries) (rowsBound : rows.length < 2^32)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (images : Related (DeclarationType.Represents values) rows types)
    (bounds : ∀ d ∈ types, DeclarationType.Bounded d)
    (typeIndex base length : Nat) (indexBound : typeIndex < 2^32) (baseBound : base < 2^32) (lengthBound : length < 2^32)
    (active : E values query.active = 1) (address : E values query.address = (typeIndex : F))
    (value : E values query.value = ((base+2^32*length : Nat) : F)) :
    typeIndex < types.length ∧ (types.getD typeIndex default).active = true ∧
      base = vectorStart params (types.getD typeIndex default) ∧ length = arity params (types.getD typeIndex default) := by
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix table checked values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership query member active
  rw [entries] at em
  obtain ⟨i,im,ie⟩ := List.mem_map.mp em
  have ib : i < rows.length := List.mem_range.mp im
  subst entry
  have image := related_at (DeclarationType.Represents values) rows types images i ib
  have typesLength := related_length _ _ _ images
  have it : i < types.length := by omega
  have typeMember : types.getD i default ∈ types := by
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem it
  have bounded := bounds _ typeMember
  have a : E values (get (rows.getD i default).fields 0) = 1 := ea
  have enabled : (types.getD i default).active = true := by
    have bit := image.1.symm.trans a
    change ((types.getD i default).active.toNat : F) = 1 at bit
    cases flag : (types.getD i default).active with
    | true => rfl
    | false => simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at bit; exact False.elim (Field.zero_ne_one bit)
  have scaled := eval_scale values (get (rows.getD i default).fields 0) (Int.ofNat i)
  change E values (scale (get (rows.getD i default).fields 0) (Int.ofNat i)) = (Int.ofNat i : F)*E values (get (rows.getD i default).fields 0) at scaled
  have key : (i : F) = (typeIndex : F) := by
    change E values (scale (get (rows.getD i default).fields 0) (Int.ofNat i)) = E values query.address at ek
    have castIndex : (Int.ofNat i : F) = (i : F) := Ring.intCast_natCast i
    rw [scaled,a,castIndex,Semiring.mul_one,address] at ek
    exact ek
  have sameIndex : i = typeIndex := natural_equal (F := F) i typeIndex (by omega) (by omega) key
  have fields := field_images values params (rows.getD i default) (types.getD i default) image
  have packed : ((vectorStart params (types.getD i default)+2^32*arity params (types.getD i default) : Nat) : F) =
      ((base+2^32*length : Nat) : F) := by
    change E values (get (rows.getD i default).fields (startField params)++scale (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32))) = E values query.value at ev
    have add := eval_append values (get (rows.getD i default).fields (startField params)) (scale (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32)))
    change E values (get (rows.getD i default).fields (startField params)++scale (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32))) = E values (get (rows.getD i default).fields (startField params))+E values (scale (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32))) at add
    have scaleCount := eval_scale values (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32))
    change E values (scale (get (rows.getD i default).fields (countField params)) (Int.ofNat (2^32))) = (Int.ofNat (2^32) : F)*E values (get (rows.getD i default).fields (countField params)) at scaleCount
    have castBase : (Int.ofNat (2^32) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast (2^32)
    rw [add,scaleCount,fields.1,fields.2,castBase,value] at ev
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using ev
  have small := arity_bound params _ bounded
  have same := natural_equal (F := F) _ _ (by omega) (by omega) packed
  have components := packed_unique _ _ _ _ small.2 baseBound same
  subst i
  exact ⟨it,enabled,components.1.symm,components.2.symm⟩

def locationTable (tables : List ReadOnlyMatrix.Record) (r : DeclarationMatrix.Record) (params : Bool) :=
  table tables r (if params then 0 else 1)
def vectorRows (r : DeclarationMatrix.Record) (params : Bool) := if params then r.params else r.results

theorem location_links (tables : List ReadOnlyMatrix.Record) (r : DeclarationMatrix.Record)
    (checked : checkLinks tables r = true) (params : Bool) :
    locationTable tables r params ∈ tables ∧
    (locationTable tables r params).entries = locations r.types (startField params) (countField params) ∧
    (locationTable tables r params).queries = (vectorRows r params).map VectorRow.location := by
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have size : r.tables.length = 6 := facts.1
  have bound : (if params then 0 else 1) < r.tables.length := by rw [size]; cases params <;> decide
  have indexMember : r.tables.getD (if params then 0 else 1) 0 ∈ r.tables := by
    rw [← List.getElem_eq_getD 0]; exact List.getElem_mem bound
  have tb : r.tables.getD (if params then 0 else 1) 0 < tables.length := facts.2.1 _ indexMember
  have member : locationTable tables r params ∈ tables := by
    unfold locationTable table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem tb
  refine ⟨member,?_⟩
  cases params
  · exact ⟨facts.2.2.2.2.1,facts.2.2.2.2.2.1⟩
  · exact ⟨facts.2.2.1,facts.2.2.2.1⟩

theorem split_recombine {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : PackedFields.Record) (checked : PackedFields.check matrix r = true)
    (width : r.lowWidth = 32) (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values r.value = E values r.low+((2^32 : Nat) : F)*E values r.high := by
  obtain ⟨n,lo,hi,_,_,_,ni,li,hiI,same,_,_⟩ := PackedFields.checked_split matrix r checked values oneValue satisfied
  rw [ni,li,hiI,same,width,Semiring.natCast_add,Semiring.natCast_mul]

/-- Every active vector row refers to a present active source type, has a
    bounded ordinal in that type, and encodes precisely that pair as its key. -/
theorem checked_member {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (images : Related (DeclarationType.Represents values) r.types types)
    (bounds : ∀ d ∈ types, DeclarationType.Bounded d)
    (params : Bool) (row : VectorRow) (member : row ∈ vectorRows r params)
    (index : Nat) (previous previousAddress count : Linear)
    (rowCheck : checkVector matrix body.tokens splits row params index previous previousAddress count = true)
    (active : E values (get row.fields 0) = 1) :
    ∃ typeIndex ordinal : Nat,
      typeIndex < types.length ∧ (types.getD typeIndex default).active = true ∧
      ordinal < arity params (types.getD typeIndex default) ∧
      E values (get row.fields 1) = ((ordinal+2^32*typeIndex : Nat) : F) ∧
      E values row.position = ((vectorStart params (types.getD typeIndex default)+ordinal : Nat) : F) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp parts.1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have record := parts.2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at record
  have links : checkLinks tables r = true := by grind only
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have location := location_links tables r links params
  have checkedTable := List.all_eq_true.mp tableChecks _ location.1
  have qm : row.location ∈ (locationTable tables r params).queries := by
    rw [location.2.2]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  have rowShape := DeclarationVector.vector_metadata matrix body.tokens splits row params index previous previousAddress count rowCheck
  obtain ⟨ti,ordinal,base,len,tib,ord,lenb,baseb,tii,oi,bi,li,position,queryIndex⟩ :=
    DeclarationSelection.selected_member matrix body.tokens splits splitChecks row params index previous previousAddress count rowCheck values oneValue satisfied active
  have keyShape := rowShape.2.2.2.2.2.2.2.2.1
  have spanShape := rowShape.2.2.2.2.2.2.2.2.2.1
  have keyMember : split splits row.keySplit ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.2.2.1
  have spanMember : split splits row.spanSplit ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.2.2.2.1
  have key := split_recombine matrix _ (List.all_eq_true.mp splitChecks _ keyMember) keyShape.2.1 values oneValue satisfied
  have span := split_recombine matrix _ (List.all_eq_true.mp splitChecks _ spanMember) spanShape.2.1 values oneValue satisfied
  have qa : row.location.active = get row.fields 0 := rowShape.2.2.2.2.2.2.2.2.2.2.2.2.1
  have value : E values row.location.value = ((base+2^32*len : Nat) : F) := by
    rw [spanShape.1,bi,li] at span
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using span
  obtain ⟨bound,enabled,sameBase,sameLength⟩ := location_binding matrix r.types types params _ row.location checkedTable location.2.1 qm shape.1 values oneValue satisfied images bounds ti base len tib baseb lenb (by rw [qa]; exact active) queryIndex value
  refine ⟨ti,ordinal,bound,enabled,by simpa [sameLength] using ord,?_,?_⟩
  · rw [keyShape.1,oi,tii] at key
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using key
  · simpa [sameBase] using position

#print axioms location_binding
#print axioms checked_member
end ZkBuild.DeclarationLocations
