import DeclarationStreams
namespace ZkBuild.DeclarationBinding
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ModuleAuditIO DeclarationStreams
attribute [local instance] Ring.intCast Semiring.natCast

theorem function_member (matrix : Shape) (tokens : Tokens) (first : Linear) (rows : List FunctionRow)
    (index : Nat) (cursor previous count : Linear)
    (accepted : checkFunctions matrix tokens first rows index cursor previous count = true)
    (r : FunctionRow) (member : r ∈ rows) : ∃ i c p n, checkFunction matrix tokens r i first c p n = true := by
  induction rows generalizing index cursor previous count with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,cursor,previous,count,parts.1⟩
    · exact ih (index+1) row.cursor row.active row.count parts.2 later

theorem tag_member (matrix : Shape) (tokens : Tokens) (rows : List TagRow) (cursor : Linear)
    (accepted : checkTags matrix tokens rows cursor = true) (r : TagRow) (member : r ∈ rows) : ∃ c, checkTag matrix tokens r c = true := by
  induction rows generalizing cursor with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨cursor,parts.1⟩
    · exact ih row.cursor parts.2 later

theorem checked_source_declarations {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : DeclarationMatrix.Record)
    (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      (∀ row ∈ r.types, ∃ d : DeclarationType.Decoded, DeclarationType.Represents values row d ∧ DeclarationType.Bounded d ∧
        (d.active = true → d.start < message.length ∧ (message.getD d.start 0).toNat = 96)) ∧
      (∀ row ∈ r.params++r.results, E values (get row.fields 0) = 1 → ∃ (tag : Fin 7) (position : Nat), position < message.length ∧
        E values (get row.fields 2) = (tag.val : F) ∧ E values row.position = (position : F) ∧
        (message.getD position 0).toNat = BinaryDeclarations.encodedType tag) ∧
      (∀ row ∈ r.functions, E values row.active = 1 → ∃ index position length,
        position < 2^32 ∧ UnsignedValue values row.query.value message position length ∧
        E values row.cursor = ((position+length : Nat) : F) ∧ E values row.query.address = 2*(E values r.firstFunction+(index : F))) ∧
      (∀ row ∈ r.tags, E values row.active = 1 → ∃ position length,
        position < message.length ∧ (message.getD position 0).toNat = 0 ∧
        UnsignedValue values row.typeIndex message (position+1) length ∧ E values row.cursor = ((position+1+length : Nat) : F)) := by
  obtain ⟨message,meaning,d0,d1,unique,types,vectors⟩ := DeclarationSound.checked_source_types matrix body tables splits r accepted values oneValue satisfied
  have parts := Bool.and_eq_true_iff.mp accepted
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message2,meaning2,_,_,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique message2 meaning2
  subst message2
  have functions : checkFunctions matrix body.tokens r.firstFunction r.functions 0 r.functionStart o z = true := by
    have checked := parts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
    grind only
  have tags : checkTags matrix body.tokens r.tags r.tagStart = true := by
    have checked := parts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
    grind only
  refine ⟨message,meaning,d0,d1,unique,types,vectors,?_,?_⟩
  · intro row member active
    obtain ⟨i,c,p,n,checked⟩ := function_member matrix body.tokens r.firstFunction r.functions 0 r.functionStart o z functions row member
    obtain ⟨position,length,pb,value,_,cursor,key,_⟩ := function_item matrix body.tokens tokenChecks row i r.firstFunction c p n checked values oneValue satisfied active message decoded
    exact ⟨i,position,length,pb,value,cursor,key⟩
  · intro row member active
    obtain ⟨c,checked⟩ := tag_member matrix body.tokens r.tags r.tagStart tags row member
    obtain ⟨position,length,pb,zeroAttribute,value,_,cursor⟩ := tag_item matrix body.tokens tokenChecks row c checked values oneValue satisfied active message decoded
    exact ⟨position,length,pb,zeroAttribute,value,cursor⟩

#print axioms checked_source_declarations
end ZkBuild.DeclarationBinding
