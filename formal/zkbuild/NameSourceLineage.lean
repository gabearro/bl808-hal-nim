import NameSourceFlatFacts
set_option autoImplicit false
namespace ZkBuild.NameSourceLineage
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceFlatFacts ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Prior where
  child : OwnedMatrix.Child
  data : ChildValue
  row : ByteRow

def Before {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (source : NameSourceMatrix.Record)
    (i : Nat) (po pt : Linear) : Option Prior → Prop
  | none => i = 0
  | some p => 0 < i ∧ ChildImage values p.child p.data ∧ ChildBound p.data ∧ p.row ∈ source.bytes ∧
      E values po = (p.data.owner : F) ∧ E values pt = E values (field p.row 1) ∧
      E values p.row.rootQuery.address = (p.data.owner : F) ∧ E values p.row.rootQuery.active = (p.data.active.toNat : F) ∧
      (p.data.active = true → RowMeaning values bank p.row p.data)

def Certified {F : Type} [Field F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (matrix : Shape) (tokens : Tokens)
    (pair : NameFrameMatrix.ByteRow × ByteRow) (d : ChildValue) : Prop :=
  FrameImage values pair.1 d ∧ ChildBound d ∧ (∃ i po pt, checkByte matrix tokens true pair.1 pair.2 i po pt = true) ∧
    (d.active = true → RowMeaning values bank pair.2 d)

theorem head_drop (xs : List Nat) (i : Nat) : (xs.drop i).headD 0 = xs.getD i 0 := by
  induction xs generalizing i with
  | nil => simp
  | cons x xs ih => cases i with
    | zero => rfl
    | succ i => simp

theorem first_ordinal {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (c : OwnedMatrix.Child) (prior next : Option OwnedMatrix.Child)
    (checked : OwnedMatrix.checkChild matrix splits c prior next = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : ChildValue) (image : ChildImage values c d) (bound : ChildBound d) (active : d.active = true)
    (same : E values c.same = 0) : d.ordinal = 0 := by
  have part := OwnedRules.child_part values splits c prior next (OwnedRules.child_holds matrix splits c prior next checked values satisfied) 4 (by decide)
  have gate := part (gate (sub (OwnedMatrix.cget c 0) c.same) (OwnedMatrix.cget c 2)) (by simp [OwnedMatrix.childParts])
  change E values (sub (OwnedMatrix.cget c 0) c.same)*E values (OwnedMatrix.cget c 2) = E values z at gate
  rw [eval_sub,image.1,active,same,image.2.2.1,z,eval_constant values oneValue] at gate
  exact DeclarationLocations.natural_equal (F := F) d.ordinal 0 (by have b := bound.2.1; omega) (by decide) (by simp only [Bool.toNat_true,Semiring.natCast_one,Ring.intCast_zero,Semiring.natCast_zero] at gate ⊢; grind)

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = true) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true) (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (splits : Splits) (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (cs : List OwnedMatrix.Child) (ds : List ChildValue) (images : Related (ChildImage values) cs ds) (bounds : ∀ d ∈ ds, ChildBound d)
    (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow) (fields : cs.map OwnedMatrix.Child.fields = fs.map NameFrameMatrix.ByteRow.fields)
    (members : ∀ b ∈ bs, b ∈ source.bytes) (i : Nat) (po pt : Linear) (prior : Option Prior)
    (ownedCheck : OwnedMatrix.checkChildren matrix splits cs (prior.map Prior.child) = true)
    (sourceRows : checkBytes matrix tokens true fs bs i po pt = true)
    (before : Before values (NameGraphMatrix.table tables graph 0) source i po pt prior) :
    Related (Certified values (NameGraphMatrix.table tables graph 0) matrix tokens) (fs.zip bs) ds := by
  induction images generalizing fs bs i po pt prior with
  | nil =>
    cases fs with
    | cons f fs => simp at fields
    | nil => cases bs with
      | nil => exact Related.nil
      | cons b bs => simp [checkBytes] at sourceRows
  | @cons c d cs ds image images ih =>
    cases fs with
    | nil => simp at fields
    | cons f fs => cases bs with
      | nil => simp [checkBytes] at sourceRows
      | cons b bs =>
        have fieldLinks := List.cons.inj fields
        have own := Bool.and_eq_true_iff.mp ownedCheck
        have src := Bool.and_eq_true_iff.mp sourceRows
        have db := bounds d (by simp)
        have bm := members b (by simp)
        have fi : FrameImage values f d := by
          unfold ChildImage OwnedMatrix.cget at image
          rw [fieldLinks.1] at image
          exact image
        have shape := byte_shape matrix tokens true f b i po pt src.1
        have rootActive : b.rootQuery.active = NameFrameMatrix.bget f 0 := by unfold NameSourceMatrix.byteShape at shape; simp only [↓reduceIte] at shape; grind only
        have rootAddress : b.rootQuery.address = NameFrameMatrix.bget f 1 := by unfold NameSourceMatrix.byteShape at shape; simp only [↓reduceIte] at shape; grind only
        have rootActivity : E values b.rootQuery.active = (d.active.toNat : F) := by rw [rootActive]; exact fi.1
        have rootOwner : E values b.rootQuery.address = (d.owner : F) := by rw [rootAddress]; exact fi.2.1
        have meaning : d.active = true → RowMeaning values (NameGraphMatrix.table tables graph 0) b d := by
          intro active
          have enabled : E values (NameFrameMatrix.bget f 0) = 1 := by simpa only [active,Bool.toNat_true,Semiring.natCast_one] using fi.1
          have nodeEnabled : E values b.nodeQuery.active = 1 := by rw [shape.2.1]; exact enabled
          have rootEnabled : E values b.rootQuery.active = 1 := by rw [rootActive]; exact enabled
          obtain ⟨bytes,rootRep,valid⟩ := query_root matrix tokens tables tableChecks frame flat graph source sourceCheck graphCheck values oneValue satisfied b bm rootEnabled
          have headRep : RepWire values (NameGraphMatrix.table tables graph 0) b.nodeQuery.address (bytes.drop d.ordinal) := by
            cases prior with
            | none =>
              have iZero : i = 0 := before
              have flag : field b 2 = z := by
                unfold NameSourceMatrix.byteShape at shape
                simp only [↓reduceIte] at shape
                exact (shape.2.2.2.2.2.2 iZero).2
              have sourceSame : E values (field b 2) = 0 := by rw [flag,z,eval_constant values oneValue]; simp
              have ownedSame := (OwnedLinks.absent_flags matrix splits c none cs.head? own.1 values oneValue).1 rfl
              have ordinal := first_ordinal matrix splits c none cs.head? own.1 values oneValue satisfied d image db active ownedSame
              have head := head_first matrix tokens f b i po pt src.1 values oneValue satisfied enabled sourceSame
              simpa only [ordinal,List.drop_zero] using rep_transfer values _ b.rootQuery.value b.nodeQuery.address bytes head.symm rootRep
            | some p =>
              obtain ⟨positive,pimage,pb,pm,poi,pti,pOwner,pActive,pMeaning⟩ := before
              have same := same_flag matrix tokens f b i po pt src.1 positive values oneValue satisfied d.owner p.data.owner db.1 pb.1 enabled fi.2.1 poi
              by_cases owners : d.owner = p.data.owner
              · have sourceSame : E values (field b 2) = 1 := by simpa [owners] using same
                have prevActive := (OwnedOrder.step_order matrix splits c p.child cs.head? own.1 values oneValue satisfied p.data d pimage image pb db active).1
                obtain ⟨oldBytes,oldRoot,_,_,oldTail,_,_⟩ := pMeaning prevActive
                have rootEq := ReadOnlyFacts.queries_agree matrix _ (root_bank matrix tokens tables tableChecks frame flat graph source sourceCheck).1 values oneValue satisfied b.rootQuery p.row.rootQuery
                  (by rw [(root_bank matrix tokens tables tableChecks frame flat graph source sourceCheck).2.2]; exact List.mem_map.mpr ⟨b,bm,rfl⟩)
                  (by rw [(root_bank matrix tokens tables tableChecks frame flat graph source sourceCheck).2.2]; exact List.mem_map.mpr ⟨p.row,pm,rfl⟩)
                  rootEnabled (by simpa [prevActive] using pActive) (by rw [rootOwner,pOwner,owners])
                have bytesEq := rep_unique values _ b.rootQuery.value p.row.rootQuery.value bytes oldBytes rootEq rootRep oldRoot
                have adjacent := OwnedLinks.adjacent matrix splits c p.child cs.head? own.1 values oneValue satisfied d p.data image pimage db pb active owners
                have head := (head_next matrix tokens f b i po pt src.1 values oneValue satisfied sourceSame).trans pti
                have transferred := rep_transfer values _ (field p.row 1) b.nodeQuery.address _ head.symm oldTail
                simpa only [bytesEq,adjacent.1] using transferred
              · have sourceSame : E values (field b 2) = 0 := by simpa [owners] using same
                have ownedSame : E values c.same = 0 := by simpa [owners] using OwnedLinks.same_owner matrix splits c p.child cs.head? own.1 values oneValue satisfied d p.data image pimage db pb active
                have ordinal := first_ordinal matrix splits c (some p.child) cs.head? own.1 values oneValue satisfied d image db active ownedSame
                have head := head_first matrix tokens f b i po pt src.1 values oneValue satisfied enabled sourceSame
                simpa only [ordinal,List.drop_zero] using rep_transfer values _ b.rootQuery.value b.nodeQuery.address bytes head.symm rootRep
          have byteCheck : checkByte matrix tokens frame.flat f b i po pt = true := by simpa only [flat] using src.1
          obtain ⟨first,rest,dropEq,byteValue,tailRep⟩ := NameSourceNodes.read_node matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied b bm f i po pt byteCheck nodeEnabled _ headRep
          have tailEq : bytes.drop (d.ordinal+1) = rest := by
            have step := congrArg (List.drop 1) dropEq
            simpa only [List.drop_drop,List.drop_succ_cons,List.drop_zero] using step
          have firstEq : bytes.getD d.ordinal 0 = first := by
            have step := congrArg (fun xs : List Nat => xs.headD 0) dropEq
            simpa only [head_drop,List.headD_cons] using step
          have inside : d.ordinal < bytes.length := by
            have len := congrArg List.length dropEq
            simp only [List.length_drop,List.length_cons] at len
            omega
          exact ⟨bytes,rootRep,valid,headRep,by rw [tailEq]; exact tailRep,by rw [firstEq]; exact byteValue,inside⟩
        have beforeNext : Before values (NameGraphMatrix.table tables graph 0) source (i+1) (NameFrameMatrix.bget f 1) (field b 1) (some ⟨c,d,b⟩) :=
          ⟨by omega,image,db,bm,fi.2.1,rfl,rootOwner,rootActivity,meaning⟩
        have tail := ih (by intro d dm; exact bounds d (by simp [dm])) fs bs fieldLinks.2
          (by intro row rm; exact members row (by simp [rm])) (i+1) (NameFrameMatrix.bget f 1) (field b 1) (some ⟨c,d,b⟩) own.2 src.2 beforeNext
        exact Related.cons ⟨fi,db,⟨i,po,pt,src.1⟩,meaning⟩ tail

#print axioms rows
end ZkBuild.NameSourceLineage
