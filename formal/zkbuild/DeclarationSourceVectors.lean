import DeclarationCompleteness

namespace ZkBuild.DeclarationSourceVectors
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
open DeclarationLocations DeclarationCompleteness
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def CompleteBytes {F : Type} [CommRing F] (values : Nat → F) (message : List Sha256.Byte)
    (types : List DeclarationType.Decoded) (rows : List VectorRow) (params : Bool) : Prop :=
  ∀ i ordinal : Nat, i < types.length → ordinal < arity params (types.getD i default) →
    (types.getD i default).active = true ∧
    ∃ (tag : Fin 7) (row : VectorRow), row ∈ rows ∧ E values (get row.fields 0) = 1 ∧
      E values (get row.fields 1) = ((ordinal+2^32*i : Nat) : F) ∧
      E values (get row.fields 2) = (tag.val : F) ∧
      vectorStart params (types.getD i default)+ordinal < message.length ∧
      (message.getD (vectorStart params (types.getD i default)+ordinal) 0).toNat = BinaryDeclarations.encodedType tag

theorem complete_bytes {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (ti : Related (DeclarationType.Represents values) r.types types)
    (tb : ∀ d ∈ types, DeclarationType.Bounded d) (params : Bool) (entries : List MemoryTrace.Entry)
    (images : Related (DeclarationOrder.Represents values) (vectorRows r params) entries)
    (bounds : ∀ e ∈ entries, DeclarationOrder.Bounded e)
    (complete : BinaryDeclarations.vectorKeys 0 (types.map (arity params)) ⊆ keys entries)
    (message : List Sha256.Byte) (messageBound : message.length < 2^32)
    (decoded : ∀ t ∈ body.tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    CompleteBytes values message types (vectorRows r params) params := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  have record := parts.2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at record
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have checks : checkVectors matrix body.tokens splits params (vectorRows r params) 0 o z z = true := by
    cases params <;> dsimp [vectorRows] <;> grind only
  intro i ordinal ib ob
  have arityAt : (types.map (arity params)).getD i 0 = arity params (types.getD i default) := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some]
  have allowed : (i,ordinal) ∈ BinaryDeclarations.vectorKeys 0 (types.map (arity params)) := by
    have found := vector_keys_at (types.map (arity params)) 0 i ordinal (by simpa using ib) (by rw [arityAt]; exact ob)
    simpa using found
  obtain ⟨entry,em,ea,ek⟩ := (keys_member entries (i,ordinal)).mp (complete allowed)
  obtain ⟨row,rm,ri⟩ := BinaryReadMemory.right_member _ _ _ images entry em
  obtain ⟨index,previous,address,count,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits params (vectorRows r params) 0 o z z checks row rm
  have active : E values (get row.fields 0) = 1 := by simpa [ea] using ri.1
  obtain ⟨typeIndex,ord,tib,enabled,ordBound,keyImage,positionImage⟩ := checked_member matrix body tables splits r accepted values oneValue satisfied types ti tb params row rm index previous address count checked active
  have tl := related_length _ _ _ ti
  have indexSmall : typeIndex < 2^32 := by have bound := shape.1; omega
  have tm : types.getD typeIndex default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem tib
  have typeBounds := arity_bound params _ (tb _ tm)
  have ordinalSmall : ord < 2^32 := Nat.lt_trans ordBound typeBounds.1
  have sameAddress := natural_equal (F := F) entry.address (ord+2^32*typeIndex) (bounds entry em).1 (by omega) (ri.2.1.symm.trans keyImage)
  have actualKey : key entry = (typeIndex,ord) := by
    simp only [key,sameAddress]
    simp [Nat.add_mul_div_left,Nat.div_eq_of_lt ordinalSmall,Nat.add_mod,Nat.mod_eq_of_lt ordinalSmall]
  have sameIndex : typeIndex = i := congrArg Prod.fst (actualKey.symm.trans ek)
  have sameOrdinal : ord = ordinal := congrArg Prod.snd (actualKey.symm.trans ek)
  subst typeIndex
  subst ord
  obtain ⟨tag,position,pb,tagImage,pi,byte⟩ := DeclarationVector.source_type_byte matrix body.tokens splits tokenChecks row params index previous address count checked values oneValue satisfied active message decoded
  have samePosition := natural_equal (F := F) position (vectorStart params (types.getD i default)+ordinal)
    (by omega) (by omega) (pi.symm.trans positionImage)
  exact ⟨enabled,tag,row,rm,active,keyImage,tagImage,by omega,by simpa [samePosition] using byte⟩

/-- Every declared vector position is a supported value-type byte in the
    single WASM source authenticated by the two public SHA-256 limbs. -/
theorem checked_source_vectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) r.types types ∧ (∀ d ∈ types, DeclarationType.Bounded d) ∧
      CompleteBytes values message types r.params true ∧ CompleteBytes values message types r.results false := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  obtain ⟨message,meaning,d0,d1,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have linked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).1).1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp linked).1
  have shape : BinarySourceEmbedded.metadata matrix body.source := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp sourceCheck).1
  have bound : message.length < 2^32 := Nat.lt_of_le_of_lt meaning.1 shape.2.2.2.2.2.2.2.2.2.2.1
  obtain ⟨types,params,results,ti,pi,ri,tb,pb,rb,_,_,_,pc,_,rc⟩ := checked_complete_vectors matrix body tables splits r accepted values oneValue satisfied
  refine ⟨message,types,meaning,d0,d1,ti,tb,?_,?_⟩
  · exact complete_bytes matrix body tables splits r accepted values oneValue satisfied types ti tb true params pi pb pc message bound decoded
  · exact complete_bytes matrix body tables splits r accepted values oneValue satisfied types ti tb false results ri rb rc message bound decoded

#print axioms checked_source_vectors
end ZkBuild.DeclarationSourceVectors
