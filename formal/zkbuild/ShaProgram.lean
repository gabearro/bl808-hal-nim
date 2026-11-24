import ShaWordFips
import Init.Data.List.Nat.TakeDrop

namespace ZkBuild.ShaProgram

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaWordMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Step (α : Type u) where
  value : α
  next : Nat
  gates : List Gate

abbrev Build (α : Type u) := Nat → Step α

instance : Monad Build where
  pure value := fun start => ⟨value,start,[]⟩
  bind first rest := fun start =>
    let a := first start
    let b := rest a.value a.next
    ⟨b.value,b.next,a.gates++b.gates⟩

def emit (fragment : Nat → Fragment) : Build ShaWordMatrix.Word :=
  fun start => let f := fragment start; ⟨f.word,f.next,f.gates⟩

structure Ensures {F : Type} [CommRing F] (values : Nat → F) (program : Build α) (post : α → Prop) : Prop where
  run : ∀ start, AllHold values (program start).gates → post (program start).value

theorem pure_sound {F : Type} [CommRing F] (values : Nat → F) (a : α) (post : α → Prop)
    (ha : post a) : Ensures values (pure a) post := ⟨by intro _ _; exact ha⟩

theorem bind_sound {F : Type} [CommRing F] (values : Nat → F) (first : Build α) (rest : α → Build β)
    (p : α → Prop) (q : β → Prop) (ha : Ensures values first p)
    (hb : ∀ a, p a → Ensures values (rest a) q) : Ensures values (first >>= rest) q := by
  constructor
  intro start holds
  have left : AllHold values (first start).gates := by
    intro gate member
    exact holds gate (List.mem_append_left _ member)
  have right : AllHold values (rest (first start).value (first start).next).gates := by
    intro gate member
    exact holds gate (List.mem_append_right _ member)
  exact (hb _ (ha.run start left)).run _ right

def Represents {F : Type} [CommRing F] (values : Nat → F) (w : ShaWordMatrix.Word) (reference : Sha256.Word) : Prop :=
  ∃ bits : Bits, Rep values w bits ∧ ShaWordFips.word bits = reference

def RepresentsBits {F : Type} [CommRing F] (values : Nat → F) (w : ShaWordMatrix.Word) (reference : Sha256.Word) : Prop :=
  ∃ bits : Bits, BitsRep values w bits ∧ ShaWordFips.word bits = reference

inductive Related (r : α → β → Prop) : List α → List β → Prop
  | nil : Related r [] []
  | cons : r a b → Related r as bs → Related r (a::as) (b::bs)

theorem to_bits {F : Type} [CommRing F] (values : Nat → F) (w : ShaWordMatrix.Word) (reference : Sha256.Word)
    (rep : Represents values w reference) : RepresentsBits values w reference := by
  obtain ⟨bits,word,same⟩ := rep
  exact ⟨bits,word.1,same⟩

def rot (w : ShaWordMatrix.Word) (amount : Nat) : ShaWordMatrix.Word := (rotate 0 amount w).word
def shr (w : ShaWordMatrix.Word) (amount : Nat) : ShaWordMatrix.Word := (shift 0 amount w).word

theorem rot_sound {F : Type} [CommRing F] (values : Nat → F) (w : ShaWordMatrix.Word)
    (reference : Sha256.Word) (amount : Nat) (small : amount < 32)
    (rep : RepresentsBits values w reference) : RepresentsBits values (rot w amount) (Sha256.rotate reference amount) := by
  obtain ⟨bits,meaning,same⟩ := rep
  refine ⟨fun i => bits ⟨(i.val+amount)%32,Nat.mod_lt _ (by decide)⟩,rotate_sound values 0 amount w bits meaning,?_⟩
  rw [ShaWordFips.word_rotate bits amount small,same]

theorem shr_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (w : ShaWordMatrix.Word) (reference : Sha256.Word) (amount : Nat)
    (rep : RepresentsBits values w reference) : RepresentsBits values (shr w amount) (reference >>> amount) := by
  obtain ⟨bits,meaning,same⟩ := rep
  refine ⟨fun i => if h : i.val+amount < 32 then bits ⟨i.val+amount,h⟩ else false,
    shift_sound values one 0 amount w bits meaning,?_⟩
  rw [ShaWordFips.word_shift bits amount,same]

def xorM (a b c : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := emit (fun start => xor3 start a b c)
def chooseM (a b c : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := emit (fun start => choose start a b c)
def majorityM (a b c : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := emit (fun start => majority start a b c)
def addM (words : List ShaWordMatrix.Word) : Build ShaWordMatrix.Word := emit (fun start => add start words)
def materializeM (w : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := emit (fun start => materialize start w)

theorem xorM_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (a b c : ShaWordMatrix.Word) (x y z : Sha256.Word)
    (ha : RepresentsBits values a x) (hb : RepresentsBits values b y) (hc : RepresentsBits values c z) :
    Ensures values (xorM a b c) (fun out => Represents values out (x ^^^ y ^^^ z)) := by
  obtain ⟨aa,ar,ax⟩ := ha
  obtain ⟨bb,br,bx⟩ := hb
  obtain ⟨cc,cr,cx⟩ := hc
  constructor
  intro start holds
  refine ⟨fun i => Bool.xor (Bool.xor (aa i) (bb i)) (cc i),xor3_sound values one start a b c aa bb cc ar br cr holds,?_⟩
  rw [ShaWordFips.word_xor3,ax,bx,cx]

theorem chooseM_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (a b c : ShaWordMatrix.Word) (x y z : Sha256.Word)
    (ha : Represents values a x) (hb : Represents values b y) (hc : Represents values c z) :
    Ensures values (chooseM a b c) (fun out => Represents values out (Sha256.choose x y z)) := by
  obtain ⟨aa,ar,ax⟩ := ha
  obtain ⟨bb,br,bx⟩ := hb
  obtain ⟨cc,cr,cx⟩ := hc
  constructor
  intro start holds
  refine ⟨fun i => if aa i then bb i else cc i,choose_sound values one start a b c aa bb cc ar.1 br.1 cr.1 holds,?_⟩
  rw [ShaWordFips.word_choose,ax,bx,cx]

theorem majorityM_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (a b c : ShaWordMatrix.Word) (x y z : Sha256.Word)
    (ha : Represents values a x) (hb : Represents values b y) (hc : Represents values c z) :
    Ensures values (majorityM a b c) (fun out => Represents values out (Sha256.majority x y z)) := by
  obtain ⟨aa,ar,ax⟩ := ha
  obtain ⟨bb,br,bx⟩ := hb
  obtain ⟨cc,cr,cx⟩ := hc
  constructor
  intro start holds
  refine ⟨fun i => (aa i && bb i) || (aa i && cc i) || (bb i && cc i),
    majority_sound values one start a b c aa bb cc ar.1 br.1 cr.1 holds,?_⟩
  rw [ShaWordFips.word_majority,ax,bx,cx]

private theorem decode_inputs {F : Type} [CommRing F] (values : Nat → F)
    (words : List ShaWordMatrix.Word) (references : List Sha256.Word)
    (related : Related (Represents values) words references) :
    ∃ entries : List (ShaWordMatrix.Word × Bits), entries.map Prod.fst = words ∧
      (entries.map (fun e => ShaWordFips.word e.2)) = references ∧
      ∀ entry ∈ entries, Rep values entry.1 entry.2 := by
  induction related with
  | nil => exact ⟨[],rfl,rfl,by simp⟩
  | @cons w reference ws refs relation tail ih =>
    obtain ⟨bits,rep,same⟩ := relation
    obtain ⟨entries,heads,meanings,good⟩ := ih
    refine ⟨(w,bits)::entries,by simp [heads],by simp [meanings,same],?_⟩
    intro entry member
    rcases List.mem_cons.mp member with head | rest
    · simpa [head] using rep
    · exact good entry rest

theorem addM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (words : List ShaWordMatrix.Word) (references : List Sha256.Word)
    (small : words.length ≤ 8) (related : Related (Represents values) words references) :
    Ensures values (addM words) (fun out => Represents values out references.sum) := by
  obtain ⟨entries,heads,meanings,good⟩ := decode_inputs values words references related
  constructor
  intro start holds
  have h : AllHold values (add start (entries.map Prod.fst)).gates := by simpa [addM,emit,heads] using holds
  obtain ⟨bits,rep,packed⟩ := add_sound values one start entries (by simpa [← heads] using small) good h
  refine ⟨bits,by simpa [addM,emit,heads] using rep,?_⟩
  have sum := ShaWordFips.word_sum (entries.map Prod.snd) bits (by simpa [List.map_map,Function.comp_def] using packed)
  simpa only [List.map_map,Function.comp_def,meanings] using sum

theorem materializeM_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (w : ShaWordMatrix.Word) (reference : Sha256.Word) (rep : RepresentsBits values w reference) :
    Ensures values (materializeM w) (fun out => Represents values out reference) := by
  obtain ⟨bits,meaning,same⟩ := rep
  constructor
  intro start holds
  exact ⟨bits,materialize_sound values one start w bits meaning holds,same⟩

def small0M (w : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := xorM (rot w 7) (rot w 18) (shr w 3)
def small1M (w : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := xorM (rot w 17) (rot w 19) (shr w 10)
def big0M (w : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := xorM (rot w 2) (rot w 13) (rot w 22)
def big1M (w : ShaWordMatrix.Word) : Build ShaWordMatrix.Word := xorM (rot w 6) (rot w 11) (rot w 25)

theorem small0M_sound {F : Type} [Field F] (v : Nat → F) (one : v 0 = 1)
    (w : ShaWordMatrix.Word) (r : Sha256.Word) (rep : Represents v w r) :
    Ensures v (small0M w) (fun out => Represents v out (Sha256.small0 r)) :=
  xorM_sound v one _ _ _ _ _ _ (rot_sound v w r 7 (by decide) (to_bits v w r rep))
    (rot_sound v w r 18 (by decide) (to_bits v w r rep)) (shr_sound v one w r 3 (to_bits v w r rep))

theorem small1M_sound {F : Type} [Field F] (v : Nat → F) (one : v 0 = 1)
    (w : ShaWordMatrix.Word) (r : Sha256.Word) (rep : Represents v w r) :
    Ensures v (small1M w) (fun out => Represents v out (Sha256.small1 r)) :=
  xorM_sound v one _ _ _ _ _ _ (rot_sound v w r 17 (by decide) (to_bits v w r rep))
    (rot_sound v w r 19 (by decide) (to_bits v w r rep)) (shr_sound v one w r 10 (to_bits v w r rep))

theorem big0M_sound {F : Type} [Field F] (v : Nat → F) (one : v 0 = 1)
    (w : ShaWordMatrix.Word) (r : Sha256.Word) (rep : Represents v w r) :
    Ensures v (big0M w) (fun out => Represents v out (Sha256.big0 r)) :=
  xorM_sound v one _ _ _ _ _ _ (rot_sound v w r 2 (by decide) (to_bits v w r rep))
    (rot_sound v w r 13 (by decide) (to_bits v w r rep)) (rot_sound v w r 22 (by decide) (to_bits v w r rep))

theorem big1M_sound {F : Type} [Field F] (v : Nat → F) (one : v 0 = 1)
    (w : ShaWordMatrix.Word) (r : Sha256.Word) (rep : Represents v w r) :
    Ensures v (big1M w) (fun out => Represents v out (Sha256.big1 r)) :=
  xorM_sound v one _ _ _ _ _ _ (rot_sound v w r 6 (by decide) (to_bits v w r rep))
    (rot_sound v w r 11 (by decide) (to_bits v w r rep)) (rot_sound v w r 25 (by decide) (to_bits v w r rep))

structure State (α : Type) where
  a : α
  b : α
  c : α
  d : α
  e : α
  f : α
  g : α
  h : α

def State.toList (s : State α) : List α := [s.a,s.b,s.c,s.d,s.e,s.f,s.g,s.h]

structure StateRep {F : Type} [CommRing F] (v : Nat → F)
    (s : State ShaWordMatrix.Word) (r : State Sha256.Word) : Prop where
  a : Represents v s.a r.a
  b : Represents v s.b r.b
  c : Represents v s.c r.c
  d : Represents v s.d r.d
  e : Represents v s.e r.e
  f : Represents v s.f r.f
  g : Represents v s.g r.g
  h : Represents v s.h r.h

def roundM (s : State ShaWordMatrix.Word) (w k : ShaWordMatrix.Word) : Build (State ShaWordMatrix.Word) := do
  let s1 ← big1M s.e
  let ch ← chooseM s.e s.f s.g
  let t1 ← addM [s.h,s1,ch,k,w]
  let s0 ← big0M s.a
  let maj ← majorityM s.a s.b s.c
  let t2 ← addM [s0,maj]
  let e ← addM [s.d,t1]
  let a ← addM [t1,t2]
  return ⟨a,s.a,s.b,s.c,e,s.e,s.f,s.g⟩

def roundRef (s : State Sha256.Word) (w k : Sha256.Word) : State Sha256.Word :=
  let t1 := [s.h,Sha256.big1 s.e,Sha256.choose s.e s.f s.g,k,w].sum
  let t2 := [Sha256.big0 s.a,Sha256.majority s.a s.b s.c].sum
  ⟨[t1,t2].sum,s.a,s.b,s.c,[s.d,t1].sum,s.e,s.f,s.g⟩

theorem roundM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1) (s : State ShaWordMatrix.Word) (r : State Sha256.Word)
    (state : StateRep v s r) (w k : ShaWordMatrix.Word) (rw rk : Sha256.Word)
    (hw : Represents v w rw) (hk : Represents v k rk) :
    Ensures v (roundM s w k) (fun out => StateRep v out (roundRef r rw rk)) := by
  unfold roundM
  apply bind_sound v _ _ _ _ (big1M_sound v one s.e r.e state.e)
  intro s1 hs1
  apply bind_sound v _ _ _ _ (chooseM_sound v one s.e s.f s.g r.e r.f r.g state.e state.f state.g)
  intro ch hch
  apply bind_sound v _ _ _ _ (addM_sound v one [s.h,s1,ch,k,w] _ (by simp)
    (.cons state.h (.cons hs1 (.cons hch (.cons hk (.cons hw .nil))))))
  intro t1 ht1
  apply bind_sound v _ _ _ _ (big0M_sound v one s.a r.a state.a)
  intro s0 hs0
  apply bind_sound v _ _ _ _ (majorityM_sound v one s.a s.b s.c r.a r.b r.c state.a state.b state.c)
  intro maj hmaj
  apply bind_sound v _ _ _ _ (addM_sound v one [s0,maj] _ (by simp) (.cons hs0 (.cons hmaj .nil)))
  intro t2 ht2
  apply bind_sound v _ _ _ _ (addM_sound v one [s.d,t1] _ (by simp) (.cons state.d (.cons ht1 .nil)))
  intro e he
  apply bind_sound v _ _ _ _ (addM_sound v one [t1,t2] _ (by simp) (.cons ht1 (.cons ht2 .nil)))
  intro a ha
  apply pure_sound
  exact ⟨ha,state.a,state.b,state.c,he,state.e,state.f,state.g⟩

theorem roundRef_fips (s : State Sha256.Word) (w k : Sha256.Word) :
    (roundRef s w k).toList = Sha256.round s.toList w k := by
  simp [roundRef,State.toList,Sha256.round,Sha256.wordAt,BitVec.add_assoc]

def roundsM (pairs : List (ShaWordMatrix.Word × ShaWordMatrix.Word))
    (s : State ShaWordMatrix.Word) : Build (State ShaWordMatrix.Word) :=
  match pairs with
  | [] => pure s
  | (w,k)::rest => do
    let next ← roundM s w k
    roundsM rest next

def roundsRef (pairs : List (Sha256.Word × Sha256.Word)) (s : State Sha256.Word) : State Sha256.Word :=
  match pairs with
  | [] => s
  | (w,k)::rest => roundsRef rest (roundRef s w k)

theorem roundsM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1)
    (pairs : List (ShaWordMatrix.Word × ShaWordMatrix.Word)) (refs : List (Sha256.Word × Sha256.Word))
    (related : Related (fun p r => Represents v p.1 r.1 ∧ Represents v p.2 r.2) pairs refs)
    (s : State ShaWordMatrix.Word) (r : State Sha256.Word) (state : StateRep v s r) :
    Ensures v (roundsM pairs s) (fun out => StateRep v out (roundsRef refs r)) := by
  induction related generalizing s r with
  | nil => exact pure_sound v s _ state
  | @cons pair ref rest refs relation tail ih =>
    apply bind_sound v _ _ _ _ (roundM_sound v one s r state pair.1 pair.2 ref.1 ref.2 relation.1 relation.2)
    intro next represented
    exact ih next (roundRef r ref.1 ref.2) represented

theorem roundsRef_fips (pairs : List (Sha256.Word × Sha256.Word)) (s : State Sha256.Word) :
    (roundsRef pairs s).toList = pairs.foldl (fun state pair => Sha256.round state pair.1 pair.2) s.toList := by
  induction pairs generalizing s with
  | nil => rfl
  | cons pair rest ih =>
    rw [List.foldl_cons,← roundRef_fips,← ih]
    rfl

theorem literal_rep {F : Type} [CommRing F] (v : Nat → F) (one : v 0 = 1)
    (n : Nat) (member : n ∈ literalValues) :
    Represents v (literal 0 n).word (BitVec.ofNat 32 n) := by
  refine ⟨natBits n,literal_sound v one 0 n member,?_⟩
  apply BitVec.eq_of_toNat_eq
  rw [ShaWordFips.word_value,BitVec.toNat_ofNat]
  have same : packed (natBits n) = n := by simpa using List.all_eq_true.mp literal_packed n member
  rw [same]
  exact (Nat.mod_eq_of_lt (by simpa [same] using packed_bound (natBits n))).symm

def zeroWord : ShaWordMatrix.Word := (literal 0 0).word

theorem zero_rep {F : Type} [CommRing F] (v : Nat → F) (one : v 0 = 1) : Represents v zeroWord 0 :=
  literal_rep v one 0 (by simp [literalValues])

theorem related_getD (relation : α → β → Prop) (xs : List α) (ys : List β)
    (related : Related relation xs ys) (a : α) (b : β) (defaults : relation a b) (index : Nat) :
    relation (xs.getD index a) (ys.getD index b) := by
  induction related generalizing index with
  | nil => simpa using defaults
  | cons head tail ih => cases index with
    | zero => simpa using head
    | succ index => simpa using ih index

theorem related_append (relation : α → β → Prop) (xs : List α) (ys : List β)
    (related : Related relation xs ys) (a : α) (b : β) (last : relation a b) :
    Related relation (xs++[a]) (ys++[b]) := by
  induction related with
  | nil => exact .cons last .nil
  | cons head tail ih => exact .cons head ih

theorem related_length (relation : α → β → Prop) (xs : List α) (ys : List β)
    (related : Related relation xs ys) : xs.length = ys.length := by
  induction related with
  | nil => rfl
  | cons _ _ ih => simp [ih]

def materializeListM (words : List ShaWordMatrix.Word) : Build (List ShaWordMatrix.Word) :=
  match words with
  | [] => pure []
  | head::tail => do
    let out ← materializeM head
    let rest ← materializeListM tail
    return out::rest

theorem materializeListM_sound {F : Type} [CommRing F] (v : Nat → F) (one : v 0 = 1)
    (words : List ShaWordMatrix.Word) (refs : List Sha256.Word)
    (related : Related (Represents v) words refs) :
    Ensures v (materializeListM words) (fun out => Related (Represents v) out refs) := by
  induction related with
  | nil => exact pure_sound v [] _ .nil
  | @cons w r ws rs head tail ih =>
    apply bind_sound v _ _ _ _ (materializeM_sound v one w r (to_bits v w r head))
    intro out represented
    apply bind_sound v _ _ _ _ ih
    intro rest relatedRest
    exact pure_sound v (out::rest) _ (.cons represented relatedRest)

theorem materializeBitsListM_sound {F : Type} [CommRing F] (v : Nat → F) (one : v 0 = 1)
    (words : List ShaWordMatrix.Word) (refs : List Sha256.Word)
    (related : Related (RepresentsBits v) words refs) :
    Ensures v (materializeListM words) (fun out => Related (Represents v) out refs) := by
  induction related with
  | nil => exact pure_sound v [] _ .nil
  | @cons w r ws rs head tail ih =>
    apply bind_sound v _ _ _ _ (materializeM_sound v one w r head)
    intro out represented
    apply bind_sound v _ _ _ _ ih
    intro rest relatedRest
    exact pure_sound v (out::rest) _ (.cons represented relatedRest)

def scheduleStepM (i : Nat) (words : List ShaWordMatrix.Word) : Build (List ShaWordMatrix.Word) := do
  let s0 ← small0M (words.getD (i-15) zeroWord)
  let s1 ← small1M (words.getD (i-2) zeroWord)
  let out ← addM [words.getD (i-16) zeroWord,s0,words.getD (i-7) zeroWord,s1]
  return words++[out]

def scheduleStepRef (i : Nat) (words : List Sha256.Word) : List Sha256.Word :=
  words++[[words.getD (i-16) 0,Sha256.small0 (words.getD (i-15) 0),
    words.getD (i-7) 0,Sha256.small1 (words.getD (i-2) 0)].sum]

theorem scheduleStepM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1) (i : Nat) (words : List ShaWordMatrix.Word) (refs : List Sha256.Word)
    (related : Related (Represents v) words refs) :
    Ensures v (scheduleStepM i words) (fun out => Related (Represents v) out (scheduleStepRef i refs)) := by
  have lookup (j : Nat) := related_getD (Represents v) words refs related zeroWord 0 (zero_rep v one) j
  apply bind_sound v _ _ _ _ (small0M_sound v one _ _ (lookup (i-15)))
  intro s0 hs0
  apply bind_sound v _ _ _ _ (small1M_sound v one _ _ (lookup (i-2)))
  intro s1 hs1
  apply bind_sound v _ _ _ _ (addM_sound v one _ _ (by simp)
    (.cons (lookup (i-16)) (.cons hs0 (.cons (lookup (i-7)) (.cons hs1 .nil)))))
  intro out represented
  exact pure_sound v _ _ (related_append (Represents v) words refs related out _ represented)

def extendM (indices : List Nat) (words : List ShaWordMatrix.Word) : Build (List ShaWordMatrix.Word) :=
  match indices with
  | [] => pure words
  | i::rest => do
    let next ← scheduleStepM i words
    extendM rest next

def extendRef (indices : List Nat) (words : List Sha256.Word) : List Sha256.Word :=
  indices.foldl (fun words i => scheduleStepRef i words) words

theorem extendM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1) (indices : List Nat)
    (words : List ShaWordMatrix.Word) (refs : List Sha256.Word)
    (related : Related (Represents v) words refs) :
    Ensures v (extendM indices words) (fun out => Related (Represents v) out (extendRef indices refs)) := by
  induction indices generalizing words refs with
  | nil => exact pure_sound v words _ related
  | cons i rest ih =>
    apply bind_sound v _ _ _ _ (scheduleStepM_sound v one i words refs related)
    intro next represented
    exact ih next _ represented

theorem schedule_ref_fips (block : List Sha256.Byte) :
    extendRef ((List.range 48).map (fun j => j+16))
      ((List.range 16).map fun i => BitVec.ofNat 32
        (block[i*4]!.toNat*2^24+block[i*4+1]!.toNat*2^16+block[i*4+2]!.toNat*2^8+block[i*4+3]!.toNat)) =
      Sha256.schedule block := by
  simp [extendRef,List.foldl_map,scheduleStepRef,Sha256.schedule,Sha256.wordAt,BitVec.add_assoc]

theorem related_map (relation : α → β → Prop) (f : β → α) (xs : List β)
    (good : ∀ x ∈ xs, relation (f x) x) : Related relation (xs.map f) xs := by
  induction xs with
  | nil => exact .nil
  | cons x xs ih => exact .cons (good x (by simp)) (ih (by intro y hy; exact good y (by simp [hy])))

theorem related_zip (r : α → β → Prop) (s : γ → δ → Prop)
    (as : List α) (bs : List β) (cs : List γ) (ds : List δ)
    (h : Related r as bs) (k : Related s cs ds) :
    Related (fun p q => r p.1 q.1 ∧ s p.2 q.2) (as.zip cs) (bs.zip ds) := by
  induction h generalizing cs ds with
  | nil => exact .nil
  | cons head tail ih => cases k with
    | nil => exact .nil
    | cons other rest => exact .cons ⟨head,other⟩ (ih _ _ rest)

def roundKey (key : Sha256.Word) : ShaWordMatrix.Word := (literal 0 key.toNat).word
def roundKeys : List ShaWordMatrix.Word := Sha256.constants.map roundKey

theorem roundKeys_rep {F : Type} [CommRing F] (v : Nat → F) (one : v 0 = 1) :
    Related (Represents v) roundKeys Sha256.constants := by
  apply related_map
  intro key member
  have inside : key.toNat ∈ literalValues := by
    apply List.mem_append_right
    apply List.mem_map.mpr
    exact ⟨key,List.mem_append_right _ member,rfl⟩
  simpa [roundKey] using literal_rep v one key.toNat inside

theorem state_related {F : Type} [CommRing F] (v : Nat → F)
    (s : State ShaWordMatrix.Word) (r : State Sha256.Word) (h : StateRep v s r) :
    Related (Represents v) s.toList r.toList :=
  .cons h.a (.cons h.b (.cons h.c (.cons h.d (.cons h.e (.cons h.f (.cons h.g (.cons h.h .nil)))))))

def addPairsM (pairs : List (ShaWordMatrix.Word × ShaWordMatrix.Word)) : Build (List ShaWordMatrix.Word) :=
  match pairs with
  | [] => pure []
  | (a,b)::rest => do
    let out ← addM [a,b]
    let remaining ← addPairsM rest
    return out::remaining

theorem addPairsM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1)
    (pairs : List (ShaWordMatrix.Word × ShaWordMatrix.Word)) (refs : List (Sha256.Word × Sha256.Word))
    (related : Related (fun p r => Represents v p.1 r.1 ∧ Represents v p.2 r.2) pairs refs) :
    Ensures v (addPairsM pairs) (fun out => Related (Represents v) out (refs.map (fun r => r.1+r.2))) := by
  induction related with
  | nil => exact pure_sound v [] _ .nil
  | @cons pair ref rest refs head tail ih =>
    apply bind_sound v _ _ _ _ (addM_sound v one [pair.1,pair.2] [ref.1,ref.2] (by simp) (.cons head.1 (.cons head.2 .nil)))
    intro out represented
    apply bind_sound v _ _ _ _ ih
    intro remaining representedRest
    apply pure_sound
    exact .cons (by simpa using represented) representedRest

def scheduleIndices : List Nat := (List.range 48).map (fun j => j+16)

def compressM (previous : State ShaWordMatrix.Word) (heads : List ShaWordMatrix.Word) : Build (List ShaWordMatrix.Word) := do
  let loaded ← materializeListM heads
  let schedule ← extendM scheduleIndices loaded
  let final ← roundsM (schedule.zip roundKeys) previous
  addPairsM (previous.toList.zip final.toList)

def compressRef (previous : State Sha256.Word) (heads : List Sha256.Word) : List Sha256.Word :=
  let schedule := extendRef scheduleIndices heads
  let final := roundsRef (schedule.zip Sha256.constants) previous
  (previous.toList.zip final.toList).map (fun pair => pair.1+pair.2)

theorem compressM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1)
    (previous : State ShaWordMatrix.Word) (reference : State Sha256.Word) (state : StateRep v previous reference)
    (heads : List ShaWordMatrix.Word) (refs : List Sha256.Word) (words : Related (Represents v) heads refs) :
    Ensures v (compressM previous heads) (fun out => Related (Represents v) out (compressRef reference refs)) := by
  apply bind_sound v _ _ _ _ (materializeListM_sound v one heads refs words)
  intro loaded represented
  apply bind_sound v _ _ _ _ (extendM_sound v one scheduleIndices loaded refs represented)
  intro schedule scheduleRep
  apply bind_sound v _ _ _ _ (roundsM_sound v one _ _
    (related_zip _ _ _ _ _ _ scheduleRep (roundKeys_rep v one)) previous reference state)
  intro final stateRep
  exact addPairsM_sound v one _ _
    (related_zip _ _ _ _ _ _ (state_related v previous reference state) (state_related v final _ stateRep))

theorem compressBitsM_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (v : Nat → F) (one : v 0 = 1)
    (previous : State ShaWordMatrix.Word) (reference : State Sha256.Word) (state : StateRep v previous reference)
    (heads : List ShaWordMatrix.Word) (refs : List Sha256.Word) (words : Related (RepresentsBits v) heads refs) :
    Ensures v (compressM previous heads) (fun out => Related (Represents v) out (compressRef reference refs)) := by
  apply bind_sound v _ _ _ _ (materializeBitsListM_sound v one heads refs words)
  intro loaded represented
  apply bind_sound v _ _ _ _ (extendM_sound v one scheduleIndices loaded refs represented)
  intro schedule scheduleRep
  apply bind_sound v _ _ _ _ (roundsM_sound v one _ _
    (related_zip _ _ _ _ _ _ scheduleRep (roundKeys_rep v one)) previous reference state)
  intro final stateRep
  exact addPairsM_sound v one _ _
    (related_zip _ _ _ _ _ _ (state_related v previous reference state) (state_related v final _ stateRep))

def blockHeads (block : List Sha256.Byte) : List Sha256.Word :=
  (List.range 16).map fun i => BitVec.ofNat 32
    (block[i*4]!.toNat*2^24+block[i*4+1]!.toNat*2^16+block[i*4+2]!.toNat*2^8+block[i*4+3]!.toNat)

theorem block_schedule (block : List Sha256.Byte) :
    extendRef scheduleIndices (blockHeads block) = Sha256.schedule block := schedule_ref_fips block

theorem extendRef_length (indices : List Nat) (words : List Sha256.Word) :
    (extendRef indices words).length = words.length+indices.length := by
  induction indices generalizing words with
  | nil => simp [extendRef]
  | cons i rest ih =>
    simp only [extendRef,List.foldl_cons] at *
    rw [ih]
    simp [scheduleStepRef]
    omega

theorem schedule_length (block : List Sha256.Byte) : (Sha256.schedule block).length = 64 := by
  rw [← block_schedule,extendRef_length]
  simp [blockHeads,scheduleIndices]

theorem zip_enumerate (xs : List α) (ys : List β) (n : Nat) (x : α) (y : β)
    (hx : xs.length = n) (hy : ys.length = n) :
    xs.zip ys = (List.range n).map (fun i => (xs.getD i x,ys.getD i y)) := by
  apply List.ext_getElem
  · simp [hx,hy]
  · intro i left right
    have ix : i < xs.length := by simp only [List.length_zip,hx,hy,Nat.min_self] at left; omega
    have iy : i < ys.length := by omega
    rw [List.getElem_zip,List.getElem_map,List.getElem_range]
    rw [← List.getElem_eq_getD x,← List.getElem_eq_getD y]

theorem compressRef_fips (previous : State Sha256.Word) (block : List Sha256.Byte) :
    compressRef previous (blockHeads block) = Sha256.compress previous.toList block := by
  let schedule := Sha256.schedule block
  have zipped : schedule.zip Sha256.constants = (List.range 64).map
      (fun i => (Sha256.wordAt schedule i,Sha256.wordAt Sha256.constants i)) := by
    exact zip_enumerate schedule Sha256.constants 64 0 0 (schedule_length block) (by decide)
  have final : (roundsRef (schedule.zip Sha256.constants) previous).toList =
      (List.range 64).foldl (fun current i => Sha256.round current (Sha256.wordAt schedule i)
        (Sha256.wordAt Sha256.constants i)) previous.toList := by
    rw [roundsRef_fips,zipped,List.foldl_map]
  simp only [compressRef,block_schedule]
  rw [zip_enumerate previous.toList (roundsRef (schedule.zip Sha256.constants) previous).toList 8 0 0 rfl rfl]
  simp only [List.map_map,Function.comp_def,final,Sha256.compress,Sha256.wordAt,schedule]

#print axioms bind_sound
#print axioms addM_sound
#print axioms small0M_sound
#print axioms big1M_sound
#print axioms roundM_sound
#print axioms roundRef_fips
#print axioms roundsM_sound
#print axioms roundsRef_fips
#print axioms scheduleStepM_sound
#print axioms extendM_sound
#print axioms schedule_ref_fips
#print axioms roundKeys_rep
#print axioms compressM_sound
#print axioms compressRef_fips

end ZkBuild.ShaProgram
