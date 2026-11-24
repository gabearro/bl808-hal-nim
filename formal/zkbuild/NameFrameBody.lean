import NameFrameSoundness
set_option autoImplicit false
namespace ZkBuild.NameFrameBody
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Coverage {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (owned : List OwnedMatrix.Record) (r : NameFrameMatrix.Record) (message : List Sha256.Byte) : Prop :=
  ∃ ps : List ParentValue, Related (ParentImage values) (stream owned r).parents ps ∧ (∀ p ∈ ps, ParentBound p) ∧
    ∀ i j, i < ps.length → j < (ps.getD i default).count → ∃ b ∈ r.bytes,
      E values (bget b 0) = 1 ∧ E values (bget b 1) = (i : F) ∧ E values (bget b 2) = (j : F) ∧
      (ps.getD i default).start+j < message.length ∧
      E values (bget b 3) = (((ps.getD i default).start+j : Nat) : F) ∧
      E values (EnvelopeMatrix.token tokens b.token).value = ((message.getD ((ps.getD i default).start+j) 0).toNat : F)

/-- Every declared ordinal has an actual reader of the committed byte at the
    corresponding position. Completeness comes from constrained counts and
    unique child keys, not from the host's list length. -/
theorem complete_bytes {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (ownChecks : owned.all (OwnedMatrix.check matrix tables splits) = true)
    (r : NameFrameMatrix.Record) (checked : NameFrameMatrix.check matrix tokens tables imports owned r = true) (flat : r.flat = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    Coverage values tokens owned r message := by
  have parts := NameFrameFlat.parts matrix tokens tables imports owned r checked flat
  have member : stream owned r ∈ owned := by
    unfold stream; rw [← List.getElem_eq_getD default]; exact List.getElem_mem parts.2.2.1
  have ownedCheck := List.all_eq_true.mp ownChecks _ member
  obtain ⟨ps,cs,pi,ci,pb,cb,_,_,_,_,complete⟩ := OwnedComplete.checked_complete matrix tables tableChecks splits (stream owned r) ownedCheck values oneValue satisfied
  have placed := OwnedUnit.checked_positions matrix tables tableChecks splits splitChecks (stream owned r) ownedCheck values oneValue satisfied ps pi pb cs ci cb
    (NameFrameFlat.unit_width matrix tokens tokenChecks tables imports owned r checked flat values oneValue satisfied)
  refine ⟨ps,pi,pb,?_⟩
  intro i j ib jb
  have arity : (ps.map ParentValue.count).getD i 0 = (ps.getD i default).count := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some]
  have desired := DeclarationCompleteness.vector_keys_at (ps.map ParentValue.count) 0 i j (by simpa using ib) (by rw [arity]; exact jb)
  have present : (i,j) ∈ OwnedComplete.keys cs := complete (by simpa using desired)
  obtain ⟨entry,em,ea,ek⟩ := (DeclarationCompleteness.keys_member (cs.map OwnedOrder.entry) (i,j)).mp present
  obtain ⟨d,dm,entryEq⟩ := List.mem_map.mp em
  subst entry
  have db := cb d dm
  have da : d.active = true := ea
  have pair := (OwnedComplete.entry_key d db).symm.trans ek
  have owner : d.owner = i := congrArg Prod.fst pair
  have ordinal : d.ordinal = j := congrArg Prod.snd pair
  have pos := placed d dm da
  have start : d.start = (ps.getD i default).start+j := by simpa only [owner,ordinal] using pos.2.1
  obtain ⟨child,cm,image⟩ := BinaryReadMemory.right_member _ _ _ ci d dm
  have included : child.fields ∈ r.bytes.map ByteRow.fields := by
    rw [← parts.2.2.2.2]; exact List.mem_map.mpr ⟨child,cm,rfl⟩
  obtain ⟨b,bm,equal⟩ := List.mem_map.mp included
  have fields (k : Nat) : bget b k = OwnedMatrix.cget child k := by simp only [bget,OwnedMatrix.cget]; rw [equal]
  have active : E values (bget b 0) = 1 := by rw [fields,image.1]; simp [da]
  obtain ⟨p,pbound,inside,pimage,_,value⟩ := NameFrameRules.byte_read matrix tokens tokenChecks true b (List.all_eq_true.mp parts.1 b bm) values oneValue satisfied active message decoded
  have pStart : p = d.start := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := db.2.2.1; omega)
    (by rw [← pimage,fields,image.2.2.2.1])
  refine ⟨b,bm,active,?_,?_,?_,?_,?_⟩
  · rw [fields,image.2.1,owner]
  · rw [fields,image.2.2.1,ordinal]
  · simpa only [pStart,start] using inside
  · rw [fields,image.2.2.2.1,start]
  · simpa only [pStart,start] using value


/-- Completeness rules out a nonempty declared body extending beyond EOF. -/
theorem nonempty_within {F : Type} [Field F]
    (values : Nat → F) (tokens : Tokens) (owned : List OwnedMatrix.Record)
    (r : NameFrameMatrix.Record) (message : List Sha256.Byte)
    (covered : Coverage values tokens owned r message) :
    ∃ ps : List ParentValue, Related (ParentImage values) (stream owned r).parents ps ∧
      ∀ i, i < ps.length → 0 < (ps.getD i default).count →
        (ps.getD i default).start+(ps.getD i default).count ≤ message.length := by
  obtain ⟨ps,images,_,bytes⟩ := covered
  refine ⟨ps,images,?_⟩
  intro i inside nonempty
  obtain ⟨_,_,_,_,_,within,_,_⟩ := bytes i ((ps.getD i default).count-1) inside (by omega)
  omega

/-- Public-digest composition for complete physical name bodies. -/
theorem module_complete_bytes {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (names : NameFrameMatrix.Record)
    (checked : NameFrameSound.check matrix body tables splits declaration indexed signature space imports owned names = true)
    (flat : names.flat = true) (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ h ∈ names.headers, E values (hget h 0) = 1 → NameFrameSource.Framed values h message) ∧
      Coverage values body.tokens owned names message := by
  obtain ⟨message,meaning,d0,d1,unique,frames,_,_⟩ := NameFrameSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned names checked values oneValue satisfied
  have checks := Bool.and_eq_true_iff.mp checked
  have ownedParts := Bool.and_eq_true_iff.mp checks.1
  have signatureCheck := (Bool.and_eq_true_iff.mp ownedParts.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨other,otherMeaning,_,_,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique other otherMeaning
  subst other
  exact ⟨message,meaning,d0,d1,frames,complete_bytes matrix body.tokens tokenChecks tables tableChecks splits splitChecks imports owned ownedParts.2 names checks.2 flat values oneValue satisfied message decoded⟩

#print axioms nonempty_within
#print axioms complete_bytes
#print axioms module_complete_bytes
end ZkBuild.NameFrameBody
