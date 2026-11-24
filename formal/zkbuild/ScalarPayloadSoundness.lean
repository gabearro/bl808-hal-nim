import ScalarPayloadLimits
import NameSourceConsumers
import BinaryTokenSyntax
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ScalarPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def GlobalPrefix {F : Type} [Field F] (values : Nat → F) (constants : List ConstantSourceMatrix.Record)
    (r : Row) (start : Linear) (message : List Sha256.Byte) : Prop :=
  ∃ p, p < 2^32 ∧ p+2 ≤ message.length ∧ E values start = (p : F) ∧
    E values (ConstantSourceMatrix.field (constAt constants r) 2) = ((p+2 : Nat) : F) ∧
    E values (typeByte 2 r) = ((message.getD p 0).toNat : F) ∧
    E values ((RangeUse.bits r.objectRange).getD 3 z) = ((message.getD (p+1) 0).toNat : F)

def RowMeaning {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (start : Linear) (message : List Sha256.Byte) : Prop :=
  (∀ i, i < ScalarPayloadRead.length kind → ∃ p len, ScalarPayloadRead.Step values tokens splits kind r start message i p len) ∧
  (∀ i, i < ScalarPayloadRead.length kind → E values (ScalarPayloadRead.layout splits kind r start i).2.1 = 1 →
    ∃ p len, ScalarPayloadRead.Decoded values splits kind r start message i p len) ∧
  (kind = 2 → E values r.active = 1 → ConstantSourceSoundness.Modern values (constAt constants r) message ∧ ConstantSourceTrace.Trace values tokens (constAt constants r) message ∧ GlobalPrefix values constants r start message) ∧
  (kind = 3 → E values r.active = 1 → ∃ p q bytes, p < 2^32 ∧ q < 2^32 ∧
    NameSourceConsumers.Encoded message p q bytes ∧ E values start = (p : F) ∧ E values r.name.cursor = (q : F)) ∧
  (kind = 0 ∨ kind = 1 →
    (E values ((limitAt r 1).value ++ (limitAt r 3).value) = 0 ∨ E values ((limitAt r 1).value ++ (limitAt r 3).value) = 1) ∧
    ∃ lo hi : Nat, lo < 2^32 ∧ hi < 2^32 ∧ E values (split splits r.limitHeads).low = (lo : F) ∧
      E values (split splits r.limitHeads).high = (hi : F) ∧
      E values ((limitAt r 0).value ++ (limitAt r 2).value) = ((lo+2^32*hi : Nat) : F))

/-- A recursive interpretation of every slot, including inactive padding. The
    input of each following slot is the previous slot's actual output. -/
def Trace {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (message : List Sha256.Byte) : List Row → Linear → Prop
  | [],_ => True
  | r::rs,start => RowMeaning values tokens splits constants kind r start message ∧
      Trace values tokens splits constants kind message rs (rowEnd constants kind r)

theorem global_modern {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (constantChecks : constants.all (ConstantSourceMatrix.check matrix tokens splits) = true)
    (r : Row) (index : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants 2 r index start previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p len, BinaryTokenSound.Result values t message p len)
    (active : E values r.active = 1) : ConstantSourceSoundness.Modern values (constAt constants r) message := by
  have links := ScalarPayloadRules.global_constant matrix tokens splits imports constants r index start previous checked
  have ca : E values (ConstantSourceMatrix.field (constAt constants r) 0) = 1 :=
    (NameGraphRoots.normalized_eval values _ _ links.2.1).trans active
  have mode : E values (ConstantSourceMatrix.field (constAt constants r) 1) = 1 :=
    (NameGraphRoots.normalized_eval values _ _ links.2.2.1).trans (by simp [o,eval_constant values oneValue])
  have choice := (ConstantSourceSoundness.active_constant matrix tokens tokenChecks splits splitChecks _
    (List.all_eq_true.mp constantChecks _ links.1) values oneValue satisfied message decoded ca).2.2
  rcases choice with modern | legacy
  · exact modern
  · exact False.elim (Field.zero_ne_one (legacy.1.symm.trans mode))

theorem export_name {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record) (graph : NameGraphMatrix.Record)
    (frameCheck : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (tableCheck : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (constants : List ConstantSourceMatrix.Record) (r : Row) (index : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants 3 r index start previous = true)
    (member : r.name.query ∈ (ImportMatrix.table tables imports 0).queries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte)
    (names : ∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
      NameSourceShared.BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message)
    (active : E values r.active = 1) :
    ∃ p q bytes, p < 2^32 ∧ q < 2^32 ∧ NameSourceConsumers.Encoded message p q bytes ∧
      E values start = (p : F) ∧ E values r.name.cursor = (q : F) := by
  have sh := ScalarPayloadRules.metadata matrix tokens splits imports constants 3 r index start previous checked
  have all := ScalarPayloadRules.row_holds matrix tokens splits imports constants 3 r index start previous checked values satisfied
  have holds : AllHold values (ImportMatrix.nameGates splits r.name r.active (n index) start) := by
    intro g gm
    exact all g (by simp only [rowGates,List.mem_append]; exact Or.inl (Or.inl gm))
  exact NameSourceConsumers.consume_name matrix tokens tables splits splitChecks imports owned frame source graph
    frameCheck tableCheck values oneValue satisfied message names r.name r.active (n index) start sh.2.2.1 member active holds

/-- Both global header bytes are consumed before its modern initializer. -/
theorem global_prefix {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (r : Row) (index : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants 2 r index start previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p len, BinaryTokenSound.Result values t message p len)
    (active : E values r.active = 1) :
    GlobalPrefix values constants r start message := by
  have a := ScalarPayloadRead.active_read matrix tokens tokenChecks splits imports constants 2 (by decide) r index start previous checked values oneValue satisfied message decoded 0 (by decide) active
  have b := ScalarPayloadRead.active_read matrix tokens tokenChecks splits imports constants 2 (by decide) r index start previous checked values oneValue satisfied message decoded 1 (by decide) active
  obtain ⟨p,l,pb,lp,lb,inside,pi,pe,pv⟩ := a
  obtain ⟨q,m,qb,mp,mb,qinside,qi,qe,qv⟩ := b
  have lOne : l = 1 := by
    change l ≤ 1 at lb
    omega
  have mOne : m = 1 := by
    change m ≤ 1 at mb
    omega
  subst l; subst m
  have qi' : E values (readAt r 0).cursor = (q : F) := qi
  have pe' : E values (readAt r 0).cursor = ((p+1 : Nat) : F) := pe
  have equal : q = p+1 := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (qi'.symm.trans pe')
  subst q
  have link := (ScalarPayloadRules.global_constant matrix tokens splits imports constants r index start previous checked).2.2.2
  have image := (NameGraphRoots.normalized_eval values _ _ link).trans qe
  have pByte : (message.getD p 0).toNat < 256 := (message.getD p 0).isLt
  have qByte : (message.getD (p+1) 0).toNat < 256 := (message.getD (p+1) 0).isLt
  change E values (typeByte 2 r) = (TokenInteger.decode 0 1 (fun j => (message.getD (p+j) 0).toNat) : F) at pv
  change E values ((RangeUse.bits r.objectRange).getD 3 z) =
    (TokenInteger.decode 0 1 (fun j => (message.getD (p+1+j) 0).toNat) : F) at qv
  rw [EnvelopeSound.decode_byte (fun j => (message.getD (p+j) 0).toNat) pByte] at pv
  rw [EnvelopeSound.decode_byte (fun j => (message.getD (p+1+j) 0).toNat) qByte] at qv
  have typeImage := pv
  have mutImage := qv
  exact ⟨p,pb,by omega,pi,by simpa [Nat.add_assoc] using image,typeImage,mutImage⟩

/-- Public-digest composition for all four complete scalar section loops. The
    count and end constraints belong to the actual matrix, rather than to the
    untrusted list of audit rows. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (payload : ScalarPayloadMatrix.Record)
    (checked : ScalarPayloadSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source constants payload = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ t ∈ body.tokens, t.kind = 1 → E values t.activeMode = 1 →
        ∃ p len, p < 2^32 ∧ p+len ≤ message.length ∧ E values t.position = (p : F) ∧ E values t.length = (len : F) ∧
          BinaryTokenSyntax.U32 len (fun j => (message.getD (p+j) 0).toNat)) ∧
      ∀ kind, kind < 4 → Trace values body.tokens splits constants kind message (getRows payload kind) (ScalarPayloadMatrix.start body kind) ∧
        E values (final constants kind (getRows payload kind) (ScalarPayloadMatrix.start body kind)) = E values (finish body kind) ∧
        ∃ count : Nat, count ≤ (getRows payload kind).length ∧ count < 2^32 ∧ E values (size body kind) = (count : F) := by
  have cp := Bool.and_eq_true_iff.mp checked
  have constantParts := Bool.and_eq_true_iff.mp cp.1
  have nameCheck := constantParts.1
  have gp := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp nameCheck).1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have ip := Bool.and_eq_true_iff.mp op.1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ip.1).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,unique,_,names⟩ := NameSourceSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned frame graph source nameCheck values oneValue satisfied
  obtain ⟨other,otherMeaning,_,_,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique other otherMeaning
  subst other
  obtain ⟨grammarMessage,grammarMeaning,_,_,grammar⟩ := BinaryTokenSyntax.checked_u32 matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have grammarSame := unique grammarMessage grammarMeaning
  subst grammarMessage
  have il : ImportMatrix.links tables signature imports := by
    have h := ip.2
    simp only [ImportMatrix.check,Bool.and_eq_true_iff] at h
    have facts : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ ImportMatrix.links tables signature imports := _root_.of_decide_eq_true (by grind only)
    exact facts.2.2
  have bank : ImportMatrix.table tables imports 0 ∈ tables := by
    have b : 0 < imports.tables.length := by rw [il.1]; decide
    have m : imports.tables.getD 0 0 ∈ imports.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold ImportMatrix.table
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (il.2.1 _ m)
  have bankCheck := List.all_eq_true.mp tableChecks _ bank
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp cp.2).1
  obtain ⟨_,_,_,_,_,limitMembers,_,nameMembers,_,_,_,_,widths⟩ := links
  have limitBanks (i : Fin 4) : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports (3+i.val)) = true := by
    have b : 3+i.val < imports.tables.length := by rw [il.1]; have ib := i.isLt; omega
    have m : imports.tables.getD (3+i.val) 0 ∈ imports.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    have bank : ImportMatrix.table tables imports (3+i.val) ∈ tables := by
      unfold ImportMatrix.table
      rw [← List.getElem_eq_getD default]
      exact List.getElem_mem (il.2.1 _ m)
    exact List.all_eq_true.mp tableChecks _ bank
  refine ⟨message,meaning,d0,d1,grammar,?_⟩
  intro kind kb
  have rowsCheck := (ScalarPayloadRules.kind_checked matrix body tables splits imports constants payload cp.2 kind kb).1
  have walk (rows : List Row) (index : Nat) (start previous : Linear)
      (members : ∀ r ∈ rows, r ∈ getRows payload kind)
      (rc : checkRows matrix body.tokens splits imports constants kind rows index start previous = true) :
      Trace values body.tokens splits constants kind message rows start := by
    induction rows generalizing index start previous with
    | nil => trivial
    | cons r rs ih =>
      have rowCheck := Bool.and_eq_true_iff.mp rc
      refine ⟨⟨?_,?_,?_,?_,?_⟩,ih (index+1) (rowEnd constants kind r) r.active (by intro r rm; exact members r (by simp [rm])) rowCheck.2⟩
      · exact fun i ib => ScalarPayloadRead.step matrix body.tokens splits imports constants kind kb r index start previous rowCheck.1 values oneValue satisfied message decoded i ib
      · exact fun i ib enabled => ScalarPayloadRead.active_read matrix body.tokens tokenChecks splits imports constants kind kb r index start previous rowCheck.1 values oneValue satisfied message decoded i ib enabled
      · intro isGlobal active
        subst kind
        exact ⟨global_modern matrix body.tokens tokenChecks splits splitChecks imports constants constantParts.2 r index start previous rowCheck.1 values oneValue satisfied message decoded active,
          ConstantSourceTrace.checked_trace matrix body.tokens splits (constAt constants r)
            (List.all_eq_true.mp constantParts.2 _ (ScalarPayloadRules.global_constant matrix body.tokens splits imports constants r index start previous rowCheck.1).1)
            values oneValue satisfied message decoded,
          global_prefix matrix body.tokens tokenChecks splits imports constants r index start previous rowCheck.1 values oneValue satisfied message decoded active⟩
      · intro isExport active
        have rm := members r (by simp)
        subst kind
        exact export_name matrix body.tokens tables splits splitChecks imports owned frame source graph fp.2 bankCheck constants r index start previous rowCheck.1 (nameMembers r rm) values oneValue satisfied message names active
      · intro isLimit
        have rm := members r (by simp)
        have k2 : kind < 2 := by rcases isLimit with rfl | rfl <;> decide
        have sh := ScalarPayloadRules.metadata matrix body.tokens splits imports constants kind r index start previous rowCheck.1
        exact ⟨ScalarPayloadLimits.flag_boolean matrix body.tokens tables splits imports constants kind isLimit r start sh
          (limitMembers ⟨kind,k2⟩ r rm) limitBanks (fun i => (widths i).2) values oneValue satisfied,
          ScalarPayloadLimits.split_values matrix body.tokens splits splitChecks constants kind isLimit r start sh values oneValue satisfied⟩
  obtain ⟨n,nb,n32,_,ni⟩ := ScalarPayloadCounts.checked_count matrix body tables tokenChecks splits imports constants payload cp.2 kind kb values oneValue satisfied
  exact ⟨walk _ 0 _ o (by intro r rm; exact rm) rowsCheck,
    (ScalarPayloadRules.closing matrix body tables splits imports constants payload cp.2 kind kb values oneValue satisfied).1,n,nb,n32,ni⟩

#print axioms global_prefix
#print axioms global_modern
#print axioms export_name
#print axioms module_verified
end ZkBuild.ScalarPayloadSoundness
