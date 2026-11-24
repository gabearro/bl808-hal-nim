import BinarySourceEmbedded
import MemoryEmbedded
import ReadOnlyMemory

/- The byte table, its digest, and the finite RAM trace refer to the same
   expressions. No byte values or memory correctness are supplied by the audit. -/
namespace ZkBuild.BinaryReadMemory

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram MemoryTrace
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

abbrev Access := MemoryPacking.Access

def payload (a : Access) : List Linear := [a.active,a.write,a.address,a.value]
def normalizedPayload (a : Access) : List Linear := (payload a).map normalizeLinear

def Image {F : Type} [CommRing F] (values : Nat → F) (a : Access) (e : Entry) : Prop :=
  E values a.active = (e.active.toNat : F) ∧ E values a.write = (e.write.toNat : F) ∧
  E values a.address = (e.address : F) ∧ E values a.value = (e.value : F)

def initializer (source : BinarySourceEmbedded.Record) (i : Nat) : Access :=
  let e := BinarySourceMatrix.entry source.firstWire i
  ⟨e.active,e.active,e.address,e.value,constant 0⟩

def initializers (source : BinarySourceEmbedded.Record) : List Access :=
  (List.range source.capacity).map (initializer source)

def readAccess (q : BinarySourceMatrix.Entry) : Access :=
  ⟨q.active,constant 0,q.address,q.value,constant 0⟩

def padding : Access := ⟨constant 0,constant 0,constant 0,constant 0,constant 0⟩

def expected (source : BinarySourceEmbedded.Record) (queries : List BinarySourceMatrix.Entry) (count : Nat) : List Access :=
  initializers source ++ queries.map readAccess ++ List.replicate (count-source.capacity-queries.length) padding

def checkLinks (source : BinarySourceEmbedded.Record) (memory : MemoryEmbedded.Record)
    (queries : List BinarySourceMatrix.Entry) : Bool :=
  decide (memory.addressBits = 32 ∧ memory.valueBits = 8 ∧
    source.capacity+queries.length ≤ memory.inputs.length ∧
    (memory.inputs.map (fun r => normalizedPayload r.fields)) =
      (expected source queries memory.inputs.length).map normalizedPayload)

def check (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry) : Bool :=
  BinarySourceEmbedded.checkLinked matrix source hash && MemoryEmbedded.check matrix memory && checkLinks source memory queries

theorem same_payload {F : Type} [CommRing F] [IsCharP F scalarModulus] (values : Nat → F) (a b : Access)
    (same : normalizedPayload a = normalizedPayload b) (e : Entry) (image : Image values a e) : Image values b e := by
  have evaluated := congrArg (List.map (fun l => E values (l : Linear))) same
  have eqs : E values a.active = E values b.active ∧ E values a.write = E values b.write ∧
      E values a.address = E values b.address ∧ E values a.value = E values b.value := by
    have eqs : (payload a).map (fun l => R1CS.eval values (interpretLinear (normalizeLinear l))) =
        (payload b).map (fun l => R1CS.eval values (interpretLinear (normalizeLinear l))) := by
      simpa only [normalizedPayload,List.map_map,Function.comp_def,E,FullMatrix.evalLinear] using evaluated
    simpa only [normalized_linear_same_field,payload,List.map_cons,List.map_nil,List.cons.injEq,and_true,E,FullMatrix.evalLinear] using eqs
  exact ⟨eqs.1.symm.trans image.1,eqs.2.1.symm.trans image.2.1,
    eqs.2.2.1.symm.trans image.2.2.1,eqs.2.2.2.symm.trans image.2.2.2⟩

theorem payload_images {F : Type} [CommRing F] [IsCharP F scalarModulus] (values : Nat → F)
    (actual wanted : List Access) (decoded : List Entry)
    (same : actual.map normalizedPayload = wanted.map normalizedPayload)
    (images : Related (MemoryPacking.Represents values) actual decoded) : Related (Image values) wanted decoded := by
  induction images generalizing wanted with
  | nil =>
    cases wanted with
    | nil => exact .nil
    | cons a rest => simp at same
  | @cons a e actual decoded head tail ih =>
    cases wanted with
    | nil => simp at same
    | cons b rest =>
      have parts := List.cons.inj same
      exact .cons (same_payload values a b parts.1 e ⟨head.1,head.2.1,head.2.2.1,head.2.2.2.1⟩) (ih rest parts.2)

theorem related_split (relation : α → β → Prop) (front back : List α) (all : List β)
    (images : Related relation (front++back) all) :
    ∃ first last, all = first++last ∧ Related relation front first ∧ Related relation back last := by
  induction front generalizing all with
  | nil => exact ⟨[],all,rfl,.nil,images⟩
  | cons a rest ih =>
    cases images with
    | cons head tail =>
      obtain ⟨first,last,rfl,frontImages,backImages⟩ := ih _ tail
      exact ⟨_::first,last,rfl,.cons head frontImages,backImages⟩

theorem right_member (relation : α → β → Prop) (xs : List α) (ys : List β)
    (images : Related relation xs ys) (y : β) (member : y ∈ ys) : ∃ x ∈ xs, relation x y := by
  induction images with
  | nil => simp at member
  | @cons a b xs ys head tail ih =>
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨a,by simp,head⟩
    · obtain ⟨x,mem,rel⟩ := ih later
      exact ⟨x,by simp [mem],rel⟩

theorem left_member (relation : α → β → Prop) (xs : List α) (ys : List β)
    (images : Related relation xs ys) (x : α) (member : x ∈ xs) : ∃ y ∈ ys, relation x y := by
  induction images with
  | nil => simp at member
  | @cons a b xs ys head tail ih =>
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨b,by simp,head⟩
    · obtain ⟨y,mem,rel⟩ := ih later
      exact ⟨y,by simp [mem],rel⟩

theorem initializer_byte {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (source : BinarySourceEmbedded.Record) (message : List Sha256.Byte)
    (meaning : BinarySourceMatrix.Message values source.firstWire source.capacity source.length message)
    (i : Nat) (inside : i < source.capacity) (entry : Entry)
    (image : Image values (initializer source i) entry) (active : entry.active = true)
    (bound : MemoryConstraints.Bounded (2^32) timeBound (2^8) entry)
    (capacity : source.capacity < 2^32) :
    entry.address < message.length ∧ entry.value = (message.getD entry.address 0).toNat := by
  have row := meaning.2.2 i inside
  have activeImage : E values (BinarySourceMatrix.entry source.firstWire i).active = 1 := by
    simpa [Image,initializer,active] using image.1
  have present : i < message.length := by
    by_cases present : i < message.length
    · exact present
    · have zero : (1 : F) = 0 := by simpa [present,activeImage] using row.1
      exact False.elim (Field.zero_ne_one zero.symm)
  have addressImage : (entry.address : F) = (i : F) := by
    exact image.2.2.1.symm.trans (by simpa [initializer,present] using row.2.2)
  have addressSmall : entry.address < scalarModulus := Nat.lt_trans bound.1 (RangeConstraints.power_below_modulus 32 (by decide))
  have iSmall : i < scalarModulus := Nat.lt_trans (Nat.lt_trans inside capacity) (RangeConstraints.power_below_modulus 32 (by decide))
  have address : entry.address = i := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus addressSmall iSmall).mp addressImage
  have valueImage : (entry.value : F) = ((message.getD i 0).toNat : F) := image.2.2.2.symm.trans row.2.1
  have valueSmall : entry.value < scalarModulus := Nat.lt_trans bound.2.2 (RangeConstraints.power_below_modulus 8 (by decide))
  have byteSmall : (message.getD i 0).toNat < scalarModulus :=
    Nat.lt_trans (BitVec.isLt _) (RangeConstraints.power_below_modulus 8 (by decide))
  have value := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus valueSmall byteSmall).mp valueImage
  exact ⟨by simpa [address] using present,by simpa [address] using value⟩

theorem checked_queries {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (accepted : check matrix source hash memory queries = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values source.firstWire source.capacity source.length other → other = message) ∧
      (∀ q ∈ queries, E values q.active = 1 → ∃ index, index < message.length ∧
        E values q.address = (index : F) ∧ E values q.value = ((message.getD index 0).toNat : F)) := by
  have parts : BinarySourceEmbedded.checkLinked matrix source hash = true ∧ MemoryEmbedded.check matrix memory = true ∧
      checkLinks source memory queries = true := by
    simpa only [check,Bool.and_eq_true_iff,and_assoc] using accepted
  have links : memory.addressBits = 32 ∧ memory.valueBits = 8 ∧ source.capacity+queries.length ≤ memory.inputs.length ∧
      (memory.inputs.map (fun r => normalizedPayload r.fields)) =
        (expected source queries memory.inputs.length).map normalizedPayload := of_decide_eq_true parts.2.2
  obtain ⟨message,meaning,digest0,digest1,unique⟩ := BinarySourceEmbedded.linked_unique_digest matrix source hash parts.1 values one satisfied
  have sourceCheck := (Bool.and_eq_true_iff.mp parts.1).1
  have metadata : BinarySourceEmbedded.metadata matrix source := of_decide_eq_true (Bool.and_eq_true_iff.mp sourceCheck).1
  have capacity : source.capacity < 2^32 := metadata.2.2.2.2.2.2.2.2.2.2.1
  obtain ⟨chronological,sorted,images,_,_,reads,bounds,_,_⟩ := MemoryEmbedded.checked_memory matrix memory parts.2.1 values one satisfied
  have payloads := payload_images values _ _ chronological (by simpa only [List.map_map,Function.comp_def] using links.2.2.2) images
  have divided := related_split (Image values) (initializers source)
    (queries.map readAccess ++ List.replicate (memory.inputs.length-source.capacity-queries.length) padding) chronological
    (by simpa only [expected,List.append_assoc] using payloads)
  obtain ⟨init,rest,chrono,initImages,restImages⟩ := divided
  have noWrites : ∀ q ∈ rest, q.write = false := by
    intro q member
    obtain ⟨a,am,image⟩ := right_member (Image values) _ _ restImages q member
    have writeZero : a.write = constant 0 := by
      rcases List.mem_append.mp am with query | pad
      · obtain ⟨q,_,rfl⟩ := List.mem_map.mp query
        rfl
      · have eq : a = padding := List.eq_of_mem_replicate pad
        simp [eq,padding]
    have zero : (q.write.toNat : F) = 0 := by
      have eq := image.2.1.symm
      rw [writeZero,eval_constant values one] at eq
      simpa using eq
    cases h : q.write with
    | false => rfl
    | true => simp [h] at zero; exact False.elim (Field.zero_ne_one zero.symm)
  have readTrace : Reads (fun _ => none) (init++rest) := by simpa only [← chrono] using reads
  have initBytes : ∀ e ∈ init, e.active = true → e.address < message.length ∧ e.value = (message.getD e.address 0).toNat := by
    intro e member active
    obtain ⟨a,am,image⟩ := right_member (Image values) _ _ initImages e member
    obtain ⟨i,im,rfl⟩ := List.mem_map.mp am
    have eb := bounds e (by rw [chrono]; exact List.mem_append_left _ member)
    have eb' : MemoryConstraints.Bounded (2^32) (2^memory.timeBits) (2^8) e := by simpa [links.1,links.2.1] using eb
    exact initializer_byte values source message meaning i (List.mem_range.mp im) e image active eb' capacity
  refine ⟨message,meaning,digest0,digest1,unique,?_⟩
  intro q member active
  have qm : readAccess q ∈ queries.map readAccess ++ List.replicate (memory.inputs.length-source.capacity-queries.length) padding :=
    List.mem_append_left _ (List.mem_map.mpr ⟨q,member,rfl⟩)
  obtain ⟨e,em,image⟩ := left_member (Image values) _ _ restImages (readAccess q) qm
  have ea : e.active = true := by
    have eq : (e.active.toNat : F) = 1 := image.1.symm.trans active
    cases h : e.active with
    | true => rfl
    | false => simp [h] at eq; exact False.elim (Field.zero_ne_one eq)
  obtain ⟨original,om,oa,_,address,value⟩ := ReadOnlyMemory.membership init rest noWrites readTrace e em ea
  have byte := initBytes original om oa
  refine ⟨e.address,by simpa [address] using byte.1,image.2.2.1,?_⟩
  have same : e.value = (message.getD e.address 0).toNat := by simpa [address,value] using byte.2
  simpa [readAccess,same] using image.2.2.2

#print axioms checked_queries

end ZkBuild.BinaryReadMemory
