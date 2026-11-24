import NameLists
set_option autoImplicit false

/- The byte classes are Unicode Table 3-7, used by WASM binary names:
   https://webassembly.github.io/spec/core/binary/values.html#binary-name
   https://www.unicode.org/versions/Unicode17.0.0/UnicodeStandard-17.0.pdf
   This specification is independent of the suffix machine's transition table. -/
namespace ZkBuild.Utf8Suffix

def Continuation (b : Nat) : Prop := 128 ≤ b ∧ b ≤ 191

inductive Valid : List Nat → Prop where
  | nil : Valid []
  | ascii (a : Nat) (rest : List Nat) : a < 128 → Valid rest → Valid (a::rest)
  | two (a b : Nat) (rest : List Nat) : 194 ≤ a → a ≤ 223 → Continuation b → Valid rest → Valid (a::b::rest)
  | three (a b c : Nat) (rest : List Nat) : 224 ≤ a → a ≤ 239 → Continuation b → Continuation c →
      (a ≠ 224 ∨ 160 ≤ b) → (a ≠ 237 ∨ b < 160) → Valid rest → Valid (a::b::c::rest)
  | four (a b c d : Nat) (rest : List Nat) : 240 ≤ a → a ≤ 244 → Continuation b → Continuation c → Continuation d →
      (a ≠ 240 ∨ 144 ≤ b) → (a ≠ 244 ∨ b < 144) → Valid rest → Valid (a::b::c::d::rest)

/-- This is the actual reverse-scanning transition used by the Nim builder. -/
def suffix (byte tailState tailHigh : Nat) : Option Nat :=
  if byte < 128 ∧ tailState = 0 then some 0
  else if 128 ≤ byte ∧ byte ≤ 191 ∧ tailState < 3 then some (tailState+1)
  else if 194 ≤ byte ∧ byte ≤ 223 ∧ tailState = 1 then some 0
  else if 224 ≤ byte ∧ byte ≤ 239 ∧ tailState = 2 ∧ (byte ≠ 224 ∨ 10 ≤ tailHigh) ∧ (byte ≠ 237 ∨ tailHigh < 10) then some 0
  else if 240 ≤ byte ∧ byte ≤ 244 ∧ tailState = 3 ∧ (byte ≠ 240 ∨ 9 ≤ tailHigh) ∧ (byte ≠ 244 ∨ tailHigh < 9) then some 0
  else none

def expected (code column : Nat) : Int :=
  if code < 16384 then
    match suffix (code%256) (code/256%4) (code/1024%16) with
    | none => 0
    | some state => if column = 0 then 1 else Int.ofNat state
  else 0

/-- Pending leading continuation bytes, followed by complete scalar encodings. -/
inductive Pending : Nat → List Nat → Prop where
  | complete (bytes : List Nat) : Valid bytes → Pending 0 bytes
  | cont (state byte : Nat) (bytes : List Nat) : state < 3 → Continuation byte →
      Pending state bytes → Pending (state+1) (byte::bytes)

theorem pending_zero (bytes : List Nat) (h : Pending 0 bytes) : Valid bytes := by
  cases h with
  | complete _ valid => exact valid

theorem pending_one (bytes : List Nat) (h : Pending 1 bytes) :
    ∃ b rest, bytes = b::rest ∧ Continuation b ∧ Valid rest := by
  cases h with
  | cont state byte rest bound cb tail => exact ⟨byte,rest,rfl,cb,pending_zero rest tail⟩

theorem pending_two (bytes : List Nat) (h : Pending 2 bytes) :
    ∃ b c rest, bytes = b::c::rest ∧ Continuation b ∧ Continuation c ∧ Valid rest := by
  cases h with
  | cont state byte rest bound cb tail =>
    obtain ⟨c,rest,equal,cc,valid⟩ := pending_one _ tail
    exact ⟨byte,c,rest,by rw [equal],cb,cc,valid⟩

theorem pending_three (bytes : List Nat) (h : Pending 3 bytes) :
    ∃ b c d rest, bytes = b::c::d::rest ∧ Continuation b ∧ Continuation c ∧ Continuation d ∧ Valid rest := by
  cases h with
  | cont state byte rest bound cb tail =>
    obtain ⟨c,d,rest,equal,cc,dc,valid⟩ := pending_two _ tail
    exact ⟨byte,c,d,rest,by rw [equal],cb,cc,dc,valid⟩

theorem suffix_cases (b t h s : Nat) (accepted : suffix b t h = some s) :
    (b < 128 ∧ t = 0 ∧ s = 0) ∨
    (Continuation b ∧ t < 3 ∧ s = t+1) ∨
    (194 ≤ b ∧ b ≤ 223 ∧ t = 1 ∧ s = 0) ∨
    (224 ≤ b ∧ b ≤ 239 ∧ t = 2 ∧ (b ≠ 224 ∨ 10 ≤ h) ∧ (b ≠ 237 ∨ h < 10) ∧ s = 0) ∨
    (240 ≤ b ∧ b ≤ 244 ∧ t = 3 ∧ (b ≠ 240 ∨ 9 ≤ h) ∧ (b ≠ 244 ∨ h < 9) ∧ s = 0) := by
  unfold suffix at accepted
  split at accepted
  · simp_all
  · split at accepted
    · simp_all [Continuation]
    · split at accepted
      · simp_all
      · split at accepted
        · simp_all
        · split at accepted <;> simp_all

theorem step_sound (b state : Nat) (bytes : List Nat) (tailState : Nat)
    (tail : Pending tailState bytes) (accepted : suffix b tailState (bytes.headD 0/16) = some state) :
    Pending state (b::bytes) := by
  rcases suffix_cases b tailState (bytes.headD 0/16) state accepted with ascii | cont | two | three | four
  · obtain ⟨ab,rfl,rfl⟩ := ascii
    exact Pending.complete _ (Valid.ascii b bytes ab (pending_zero bytes tail))
  · obtain ⟨cb,tb,rfl⟩ := cont
    exact Pending.cont tailState b bytes tb cb tail
  · obtain ⟨lo,hi,rfl,rfl⟩ := two
    obtain ⟨c,rest,rfl,cb,valid⟩ := pending_one bytes tail
    exact Pending.complete _ (Valid.two b c rest lo hi cb valid)
  · obtain ⟨lo,hi,rfl,lower,upper,rfl⟩ := three
    obtain ⟨c,d,rest,rfl,cc,dc,valid⟩ := pending_two bytes tail
    simp only [List.headD_cons] at lower upper
    exact Pending.complete _ (Valid.three b c d rest lo hi cc dc (by omega) (by omega) valid)
  · obtain ⟨lo,hi,rfl,lower,upper,rfl⟩ := four
    obtain ⟨c,d,e,rest,rfl,cc,dc,ec,valid⟩ := pending_three bytes tail
    simp only [List.headD_cons] at lower upper
    exact Pending.complete _ (Valid.four b c d e rest lo hi cc dc ec (by omega) (by omega) valid)

inductive Run : List Nat → Nat → Prop where
  | nil : Run [] 0
  | cons (b state : Nat) (bytes : List Nat) (tailState : Nat) : Run bytes tailState →
      suffix b tailState (bytes.headD 0/16) = some state → Run (b::bytes) state

theorem run_sound (bytes : List Nat) (state : Nat) (run : Run bytes state) : Pending state bytes := by
  induction run with
  | nil => exact Pending.complete [] Valid.nil
  | cons b state bytes tailState _ step ih => exact step_sound b state bytes tailState ih step

theorem zero_sound (bytes : List Nat) (run : Run bytes 0) : Valid bytes := pending_zero bytes (run_sound bytes 0 run)

theorem ascii_step (b high : Nat) (bound : b < 128) : suffix b 0 high = some 0 := by
  simp [suffix,bound]

theorem continuation_step (b state high : Nat) (bound : Continuation b) (small : state < 3) :
    suffix b state high = some (state+1) := by
  have no : ¬b < 128 := by have h := bound.1; omega
  simp [suffix,no,bound.1,bound.2,small]

theorem two_step (a high : Nat) (lo : 194 ≤ a) (hi : a ≤ 223) : suffix a 1 high = some 0 := by
  have no : ¬a < 128 := by omega
  have nc : ¬a ≤ 191 := by omega
  simp [suffix,no,nc,lo,hi]

theorem three_step (a b : Nat) (lo : 224 ≤ a) (hi : a ≤ 239)
    (lower : a ≠ 224 ∨ 160 ≤ b) (upper : a ≠ 237 ∨ b < 160) : suffix a 2 (b/16) = some 0 := by
  have no : ¬a < 128 := by omega
  have nc : ¬a ≤ 191 := by omega
  have lower' : a ≠ 224 ∨ 10 ≤ b/16 := by omega
  have upper' : a ≠ 237 ∨ b/16 < 10 := by omega
  simp [suffix,no,nc,lo,hi,lower',upper']

theorem four_step (a b : Nat) (lo : 240 ≤ a) (hi : a ≤ 244)
    (lower : a ≠ 240 ∨ 144 ≤ b) (upper : a ≠ 244 ∨ b < 144) : suffix a 3 (b/16) = some 0 := by
  have no : ¬a < 128 := by omega
  have nc : ¬a ≤ 191 := by omega
  have lower' : a ≠ 240 ∨ 9 ≤ b/16 := by omega
  have upper' : a ≠ 244 ∨ b/16 < 9 := by omega
  simp [suffix,no,nc,lo,hi,lower',upper']

/-- Every well-formed scalar sequence has an accepting suffix-machine run. -/
theorem run_complete (bytes : List Nat) (valid : Valid bytes) : Run bytes 0 := by
  induction valid with
  | nil => exact Run.nil
  | ascii a rest ab _ ih => exact Run.cons a 0 rest 0 ih (ascii_step a _ ab)
  | two a b rest lo hi cb _ ih =>
    exact Run.cons a 0 (b::rest) 1 (Run.cons b 1 rest 0 ih (continuation_step b 0 _ cb (by decide))) (two_step a _ lo hi)
  | three a b c rest lo hi cb cc lower upper _ ih =>
    have cr : Run (c::rest) 1 := Run.cons c 1 rest 0 ih (continuation_step c 0 _ cc (by decide))
    have br : Run (b::c::rest) 2 := Run.cons b 2 (c::rest) 1 cr (continuation_step b 1 _ cb (by decide))
    exact Run.cons a 0 (b::c::rest) 2 br (by simpa using three_step a b lo hi lower upper)
  | four a b c d rest lo hi cb cc cd lower upper _ ih =>
    have dr : Run (d::rest) 1 := Run.cons d 1 rest 0 ih (continuation_step d 0 _ cd (by decide))
    have cr : Run (c::d::rest) 2 := Run.cons c 2 (d::rest) 1 dr (continuation_step c 1 _ cc (by decide))
    have br : Run (b::c::d::rest) 3 := Run.cons b 3 (c::d::rest) 2 cr (continuation_step b 2 _ cb (by decide))
    exact Run.cons a 0 (b::c::d::rest) 3 br (by simpa using four_step a b lo hi lower upper)

theorem valid_iff (bytes : List Nat) : Valid bytes ↔ Run bytes 0 := ⟨run_complete bytes,zero_sound bytes⟩

#print axioms run_complete
#print axioms valid_iff
#print axioms step_sound
#print axioms run_sound
#print axioms zero_sound
end ZkBuild.Utf8Suffix
