import NameGraphLinks
set_option autoImplicit false
namespace ZkBuild.NameGraphTable
open Lean.Grind CircuitShape FullMatrix GadgetShape NameGraphMatrix NameGraphRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def WordAt {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (id word : Nat) : Prop :=
  id < 2^32 ∧ word < 2^42 ∧ ∃ q ∈ bank.queries, E values q.active = 1 ∧
    E values q.address = (id : F) ∧ E values q.value = (word : F)

noncomputable def words {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (id : Nat) : Option Nat := by
  classical
  exact if h : ∃ word, WordAt values bank id word then some (Classical.choose h) else none

def node (word : Nat) : NameLists.Node := ⟨⟨byteOf word,Nat.mod_lt _ (by decide)⟩,tailOf word⟩
noncomputable def table {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) : NameLists.Table :=
  fun id => (words values bank id).map node

theorem word_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id a b : Nat) (atA : WordAt values bank id a) (atB : WordAt values bank id b) : a = b := by
  obtain ⟨_,ab,qa,am,aa,ak,av⟩ := atA
  obtain ⟨_,bb,qb,bm,ba,bk,bv⟩ := atB
  have same := ReadOnlyFacts.queries_agree matrix bank checked values oneValue satisfied qa qb am bm aa ba (ak.trans bk.symm)
  exact DeclarationLocations.natural_equal (F := F) a b (by omega) (by omega) (av.symm.trans (same.trans bv))

theorem words_found {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id word : Nat) (atWord : WordAt values bank id word) : words values bank id = some word := by
  classical
  have present : ∃ w, WordAt values bank id w := ⟨word,atWord⟩
  simp only [words,dif_pos present]
  congr 1
  exact word_unique matrix bank checked values oneValue satisfied id _ word (Classical.choose_spec present) atWord

theorem table_found {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id word : Nat) (atWord : WordAt values bank id word) : table values bank id = some (node word) := by
  rw [table,words_found matrix bank checked values oneValue satisfied id word atWord]
  rfl

theorem source {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id word : Nat) (atWord : WordAt values (NameGraphMatrix.table tables r 0) id word) :
    ∃ row ∈ r.nodes, E values row.entry.active = 1 ∧ E values row.entry.address = (id : F) ∧ E values row.entry.value = (word : F) := by
  obtain ⟨_,_,q,qm,qa,qk,qv⟩ := atWord
  have bc := NameGraphLinks.bank_checked matrix tables tableChecks r checked 0 (by decide)
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ bc values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := lookup q qm qa
  have metadata := NameGraphLinks.metadata matrix tables r checked
  rw [metadata.2.2.2.1] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  exact ⟨row,rm,ea,ek.trans qk,ev.trans qv⟩

theorem details {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id word : Nat) (atWord : WordAt values (NameGraphMatrix.table tables r 0) id word) :
    ∃ row ∈ r.nodes, ∃ following : Nat, following < 2^42 ∧ 0 < id ∧ tailOf word < id ∧
      (tailOf word = 0 → following = 0) ∧
      (tailOf word ≠ 0 → WordAt values (NameGraphMatrix.table tables r 0) (tailOf word) following) ∧
      Utf8Suffix.suffix (byteOf word) (stateOf following) (highOf following) = some (stateOf word) ∧
      E values row.canonical.active = 1 ∧ E values row.canonical.address = ((byteOf word+256*tailOf word : Nat) : F) ∧
      E values row.canonical.value = (id : F) := by
  obtain ⟨row,rm,ra,rk,rv⟩ := source matrix tables tableChecks r checked values oneValue satisfied id word atWord
  obtain ⟨i,ib,rc⟩ := NameGraphLinks.node_checked matrix tables r checked row rm
  obtain ⟨current,following,cb,fb,ci,fi,byteImage,tailImage,stateImage,nextStateImage,nextHighImage⟩ := NameGraphRules.words matrix row i rc values oneValue satisfied
  have currentSame : current = word := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := atWord.2.1; omega) (ci.symm.trans rv)
  subst current
  have metadata := NameGraphLinks.metadata matrix tables r checked
  have ibound : i+1 < 2^32 := by have b := metadata.2.2.1; omega
  have idSame : id = i+1 := DeclarationLocations.natural_equal (F := F) _ _ (by have b := atWord.1; omega) (by omega)
    (rk.symm.trans (node_index matrix row i rc values oneValue satisfied ra))
  have tb : tailOf word < 2^32 := Nat.mod_lt _ (by decide)
  have less : tailOf word < id := by rw [idSame]; exact NameGraphLinks.decreasing matrix row i rc values oneValue satisfied ra _ tb tailImage ibound
  have refs := tail_query matrix row i rc values oneValue satisfied ra (tailOf word) tb tailImage
  have qm : row.query ∈ (NameGraphMatrix.table tables r 0).queries := by
    rw [metadata.2.2.2.2.1]
    exact List.mem_append_left _ (List.mem_map.mpr ⟨row,rm,rfl⟩)
  have bc := NameGraphLinks.bank_checked matrix tables tableChecks r checked 0 (by decide)
  have zero : tailOf word = 0 → following = 0 := by
    intro nil
    have queryZero := (ReadOnlyInactive.query_zero matrix _ bc values oneValue satisfied row.query qm (by simpa [nil] using refs.1)).2
    exact DeclarationLocations.natural_equal (F := F) following 0 (by omega) (by decide) (by simpa using fi.symm.trans queryZero)
  have next : tailOf word ≠ 0 → WordAt values (NameGraphMatrix.table tables r 0) (tailOf word) following := by
    intro nonzero
    exact ⟨tb,fb,row.query,qm,by simpa [nonzero] using refs.1,refs.2,fi⟩
  have transition := NameGraphLookup.transition matrix row i rc (NameGraphLinks.node_table matrix tables r checked row rm)
    values oneValue satisfied ra word following byteImage stateImage nextStateImage nextHighImage
  have sh := shape matrix row i rc
  have all := part values row i (holds matrix row i rc values satisfied) 5 (by decide)
  have key := multiply_sound values row.entry.active (field row 0 ++ CircuitShape.scale (field row 1) 256) row.canonical.address (all _ (by simp [nodeParts]))
  have cat : E values (field row 0 ++ CircuitShape.scale (field row 1) 256) = E values (field row 0)+E values (CircuitShape.scale (field row 1) 256) := eval_append values _ _
  have sc : E values (CircuitShape.scale (field row 1) 256) = ((256 : Int) : F)*E values (field row 1) := eval_scale values _ _
  have int256 : ((256 : Int) : F) = ((256 : Nat) : F) := Ring.intCast_natCast _
  have keyImage : E values row.canonical.address = ((byteOf word+256*tailOf word : Nat) : F) := by
    rw [key,ra,cat,sc,byteImage,tailImage,int256,Semiring.natCast_add,Semiring.natCast_mul]
    grind
  exact ⟨row,rm,following,fb,by omega,less,zero,next,transition,by rw [sh.2.2.2.2.2.2.1]; exact ra,keyImage,by rw [sh.2.2.2.2.2.2.2]; exact rk⟩

#print axioms words_found
#print axioms source
#print axioms details
end ZkBuild.NameGraphTable
