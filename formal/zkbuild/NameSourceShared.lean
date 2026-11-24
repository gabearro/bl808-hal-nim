import NameSourceNodes
set_option autoImplicit false
namespace ZkBuild.NameSourceShared
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Matches (message : List Sha256.Byte) (start : Nat) (bytes : List Nat) : Prop :=
  ∀ i, i < bytes.length → start+i < message.length ∧ (message.getD (start+i) 0).toNat = bytes.getD i 0

theorem matches_cons (message : List Sha256.Byte) (start first : Nat) (rest : List Nat)
    (inside : start < message.length) (value : (message.getD start 0).toNat = first)
    (tail : Matches message (start+1) rest) : Matches message start (first::rest) := by
  intro i bound
  cases i with
  | zero => simpa using And.intro inside value
  | succ i =>
    have h := tail i (by simpa using bound)
    simpa [Nat.add_comm,Nat.add_left_comm,Nat.add_assoc] using h

theorem related_drop {α β : Type} (relation : α → β → Prop) (xs : List α) (ys : List β)
    (h : Related relation xs ys) (n : Nat) : Related relation (xs.drop n) (ys.drop n) := by
  induction h generalizing n with
  | nil => simp; exact Related.nil
  | @cons x y xs ys head tail ih => cases n with
    | zero => simpa using Related.cons head tail
    | succ n => simpa using ih n

theorem related_take {α β : Type} (relation : α → β → Prop) (xs : List α) (ys : List β)
    (h : Related relation xs ys) (n : Nat) : Related relation (xs.take n) (ys.take n) := by
  induction h generalizing n with
  | nil => simp; exact Related.nil
  | @cons x y xs ys head tail ih => cases n with
    | zero => exact Related.nil
    | succ n => simpa using Related.cons head (ih n)

theorem rep_values_bound (table : NameLists.Table) (head : Nat) (bytes : List Nat)
    (represented : NameLists.Represents table head bytes) : ∀ b ∈ bytes, b < 256 := by
  induction represented with
  | nil => simp
  | @cons id node rest _ _ _ ih =>
    intro b member
    rcases List.mem_cons.mp member with same | later
    · subst b; exact node.byte.isLt
    · exact ih b later

theorem root_rep {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (h : Header) (member : h ∈ source.headers) :
    ∃ bytes, RepWire values (NameGraphMatrix.table tables graph 0) h.head bytes ∧ Utf8Suffix.Valid bytes := by
  have facts := metadata matrix tokens tables frame graph source sourceCheck
  have hm : h.head ∈ graph.roots.map NameGraphMatrix.Root.head := by
    rw [← facts.2.2.1]
    exact List.mem_map.mpr ⟨h,member,rfl⟩
  obtain ⟨root,rm,same⟩ := List.mem_map.mp hm
  obtain ⟨id,bytes,bound,image,rep,valid⟩ := NameGraphRoots.root_valid matrix tables tableChecks graph graphCheck values oneValue satisfied root rm
  exact ⟨bytes,⟨id,bound,by rw [← same]; exact image,rep⟩,valid⟩

theorem rep_unique {F : Type} [Field F] [IsCharP F scalarModulus] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (a b : Linear) (xs ys : List Nat) (same : E values a = E values b)
    (first : RepWire values bank a xs) (second : RepWire values bank b ys) : xs = ys := by
  obtain ⟨i,ib,ii,ir⟩ := first
  obtain ⟨j,jb,ji,jr⟩ := second
  have eq : i = j := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (ii.symm.trans (same.trans ji))
  subst j
  exact NameLists.represents_unique _ i xs ys ir jr

theorem zip_members {α β : Type} (xs : List α) (ys : List β) (a : α) (b : β)
    (member : (a,b) ∈ xs.zip ys) : a ∈ xs ∧ b ∈ ys := by
  induction xs generalizing ys with
  | nil => simp at member
  | cons x xs ih => cases ys with
    | nil => simp at member
    | cons y ys =>
      simp only [List.zip_cons_cons,List.mem_cons] at member
      rcases member with same | later
      · cases same; simp
      · obtain ⟨am,bm⟩ := ih ys later
        exact ⟨by simp [am],by simp [bm]⟩

def BoundName {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (f : NameFrameMatrix.Header) (h : Header) (message : List Sha256.Byte) : Prop :=
  ∃ start length : Nat, ∃ bytes : List Nat,
    start < 2^32 ∧ 0 < length ∧ length ≤ 5 ∧ start+length ≤ message.length ∧ start+length+bytes.length < 2^32 ∧
    E values (NameFrameMatrix.hget f 2) = (start : F) ∧ E values (NameFrameMatrix.hget f 3) = ((start+length : Nat) : F) ∧
    E values (NameFrameMatrix.hget f 1) = (bytes.length : F) ∧ E values (NameFrameMatrix.hget f 4) = ((start+length+bytes.length : Nat) : F) ∧
    TokenInteger.decode 1 length (fun i => (message.getD (start+i) 0).toNat) = bytes.length ∧
    RepWire values bank h.head bytes ∧ Utf8Suffix.Valid bytes ∧ Matches message (start+length) bytes

def LegacyByte (matrix : Shape) (tokens : Tokens) (f : NameFrameMatrix.ByteRow) (b : ByteRow) : Prop :=
  NameSourceMatrix.checkByte matrix tokens false f b 0 z z = true ∧ NameFrameMatrix.checkByte matrix tokens false f = true

theorem legacy_bytes (matrix : Shape) (tokens : Tokens) (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow)
    (sourceCheck : checkBytes matrix tokens false fs bs 0 z z = true)
    (frameCheck : fs.all (NameFrameMatrix.checkByte matrix tokens false) = true) : Related (LegacyByte matrix tokens) fs bs := by
  have walk (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow) (i : Nat) (po pt : Linear)
      (sourceCheck : checkBytes matrix tokens false fs bs i po pt = true)
      (frameCheck : fs.all (NameFrameMatrix.checkByte matrix tokens false) = true) : Related (LegacyByte matrix tokens) fs bs := by
    induction fs generalizing bs i po pt with
    | nil => cases bs with
      | nil => exact Related.nil
      | cons b bs => simp [checkBytes] at sourceCheck
    | cons f fs ih => cases bs with
      | nil => simp [checkBytes] at sourceCheck
      | cons b bs =>
        have sc := Bool.and_eq_true_iff.mp sourceCheck
        have fc : NameFrameMatrix.checkByte matrix tokens false f = true ∧ fs.all (NameFrameMatrix.checkByte matrix tokens false) = true := by
          simpa only [List.all_cons,Bool.and_eq_true_iff] using frameCheck
        refine Related.cons ⟨?_,fc.1⟩ (ih bs (i+1) (NameFrameMatrix.bget f 1) (field b 1) sc.2 fc.2)
        simpa [NameSourceMatrix.checkByte,NameSourceMatrix.byteShape,NameSourceMatrix.byteGates] using sc.1
  exact walk fs bs 0 z z sourceCheck frameCheck
end ZkBuild.NameSourceShared
