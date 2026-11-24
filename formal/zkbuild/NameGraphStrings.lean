import NameGraphTable
set_option autoImplicit false
namespace ZkBuild.NameGraphStrings
open Lean.Grind CircuitShape FullMatrix GadgetShape NameGraphMatrix NameGraphRules NameGraphTable
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem high_byte (word : Nat) : highOf word = byteOf word / 16 := by
  unfold highOf byteOf
  omega

theorem represented {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id word : Nat) (atWord : WordAt values (NameGraphMatrix.table tables r 0) id word) :
    ∃ bytes, NameLists.Represents (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) id bytes ∧
      Utf8Suffix.Run bytes (stateOf word) ∧ bytes.headD 0 = byteOf word := by
  induction id using Nat.strongRecOn generalizing word with
  | ind id ih =>
    obtain ⟨row,_,following,_,positive,less,zero,next,transition,_,_,_⟩ := details matrix tables tableChecks r checked values oneValue satisfied id word atWord
    have bc := NameGraphLinks.bank_checked matrix tables tableChecks r checked 0 (by decide)
    have tails : ∃ bytes, NameLists.Represents (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) (tailOf word) bytes ∧
        Utf8Suffix.Run bytes (stateOf following) ∧ bytes.headD 0 / 16 = highOf following := by
      by_cases nil : tailOf word = 0
      · have empty := zero nil
        refine ⟨[],?_,?_,?_⟩
        · rw [nil]; exact NameLists.Represents.nil
        · simpa [empty,stateOf] using Utf8Suffix.Run.nil
        · simp [empty,highOf]
      · obtain ⟨bytes,rep,run,head⟩ := ih (tailOf word) less following (next nil)
        exact ⟨bytes,rep,run,by rw [head,high_byte]⟩
    obtain ⟨bytes,rep,run,high⟩ := tails
    have found := table_found matrix _ bc values oneValue satisfied id word atWord
    refine ⟨byteOf word::bytes,NameLists.Represents.cons (by omega) found rep,?_,rfl⟩
    exact Utf8Suffix.Run.cons (byteOf word) (stateOf word) bytes (stateOf following) run (by rw [high]; exact transition)

theorem table_word {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (id : Nat) (n : NameLists.Node) (found : NameGraphTable.table values bank id = some n) :
    ∃ word, WordAt values bank id word ∧ node word = n := by
  classical
  unfold NameGraphTable.table NameGraphTable.words at found
  split at found
  next existsWord =>
    exact ⟨Classical.choose existsWord,Classical.choose_spec existsWord,Option.some.inj found⟩
  next absent => simp at found

theorem canonical {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    NameLists.Canonical (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) := by
  intro i j n a b
  obtain ⟨x,xa,xn⟩ := table_word values _ i n a
  obtain ⟨y,ya,yn⟩ := table_word values _ j n b
  obtain ⟨xr,xm,_,_,_,_,_,_,_,ax,kx,vx⟩ := details matrix tables tableChecks r checked values oneValue satisfied i x xa
  obtain ⟨yr,ym,_,_,_,_,_,_,_,ay,ky,vy⟩ := details matrix tables tableChecks r checked values oneValue satisfied j y ya
  have sameNode : node x = node y := xn.trans yn.symm
  have sameByte : byteOf x = byteOf y := congrArg (fun n : NameLists.Node => n.byte.val) sameNode
  have sameTail : tailOf x = tailOf y := congrArg (fun n : NameLists.Node => n.next) sameNode
  have metadata := NameGraphLinks.metadata matrix tables r checked
  have xq : xr.canonical ∈ (NameGraphMatrix.table tables r 1).queries := by
    rw [metadata.2.2.2.2.2.1]; exact List.mem_map.mpr ⟨xr,xm,rfl⟩
  have yq : yr.canonical ∈ (NameGraphMatrix.table tables r 1).queries := by
    rw [metadata.2.2.2.2.2.1]; exact List.mem_map.mpr ⟨yr,ym,rfl⟩
  have valuesEqual := ReadOnlyFacts.queries_agree matrix _ (NameGraphLinks.bank_checked matrix tables tableChecks r checked 1 (by decide))
    values oneValue satisfied xr.canonical yr.canonical xq yq ax ay (by rw [kx,ky,sameByte,sameTail])
  exact DeclarationLocations.natural_equal (F := F) i j (by have h := xa.1; omega) (by have h := ya.1; omega)
    (vx.symm.trans (valuesEqual.trans vy))

theorem nil_absent {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    NameGraphTable.table values (NameGraphMatrix.table tables r 0) 0 = none := by
  cases found : NameGraphTable.table values (NameGraphMatrix.table tables r 0) 0 with
  | none => rfl
  | some n =>
    obtain ⟨word,atWord,_⟩ := table_word values _ 0 n found
    obtain ⟨_,_,_,_,positive,_⟩ := details matrix tables tableChecks r checked values oneValue satisfied 0 word atWord
    omega

theorem well_formed {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (n : NameLists.Node) (found : NameGraphTable.table values (NameGraphMatrix.table tables r 0) id = some n) :
    n.next < id ∧ (n.next = 0 ∨ ∃ next, NameGraphTable.table values (NameGraphMatrix.table tables r 0) n.next = some next) := by
  obtain ⟨word,atWord,same⟩ := table_word values _ id n found
  obtain ⟨_,_,following,_,_,less,_,next,_⟩ := details matrix tables tableChecks r checked values oneValue satisfied id word atWord
  have tail : n.next = tailOf word := by rw [← same]; rfl
  refine ⟨by rw [tail]; exact less,?_⟩
  by_cases empty : tailOf word = 0
  · left; exact tail.trans empty
  · right
    refine ⟨node following,?_⟩
    rw [tail]
    exact table_found matrix _ (NameGraphLinks.bank_checked matrix tables tableChecks r checked 0 (by decide)) values oneValue satisfied _ _ (next empty)

#print axioms nil_absent
#print axioms well_formed
#print axioms represented
#print axioms canonical
end ZkBuild.NameGraphStrings
