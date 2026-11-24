import R1CS

/- FIPS 180-4 SHA-256 reference and algebraic components for the circuit.
   The whole Nim constraint generator is not extracted from this definition. -/
namespace ZkBuild.Sha256

open Lean.Grind
attribute [local instance] Semiring.natCast

abbrev Word := BitVec 32
abbrev Byte := BitVec 8

def rotate (x : Word) (n : Nat) : Word := (x >>> n) ||| (x <<< (32-n))
def small0 (x : Word) : Word := rotate x 7 ^^^ rotate x 18 ^^^ (x >>> 3)
def small1 (x : Word) : Word := rotate x 17 ^^^ rotate x 19 ^^^ (x >>> 10)
def big0 (x : Word) : Word := rotate x 2 ^^^ rotate x 13 ^^^ rotate x 22
def big1 (x : Word) : Word := rotate x 6 ^^^ rotate x 11 ^^^ rotate x 25
def choose (x y z : Word) : Word := (x &&& y) ^^^ (~~~x &&& z)
def majority (x y z : Word) : Word := (x &&& y) ^^^ (x &&& z) ^^^ (y &&& z)

def initial : List Word := [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
  0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]

def constants : List Word := [
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]

def wordAt (words : List Word) (i : Nat) : Word := words.getD i 0

def schedule (block : List Byte) : List Word :=
  let head := (List.range 16).map fun i =>
    BitVec.ofNat 32 (block[i*4]!.toNat*2^24 + block[i*4+1]!.toNat*2^16 +
      block[i*4+2]!.toNat*2^8 + block[i*4+3]!.toNat)
  (List.range 48).foldl (fun words j =>
    let i := j+16
    words ++ [wordAt words (i-16) + small0 (wordAt words (i-15)) + wordAt words (i-7) + small1 (wordAt words (i-2))]) head

def round (state : List Word) (word k : Word) : List Word :=
  let a := wordAt state 0; let b := wordAt state 1; let c := wordAt state 2; let d := wordAt state 3
  let e := wordAt state 4; let f := wordAt state 5; let g := wordAt state 6; let h := wordAt state 7
  let t1 := h + big1 e + choose e f g + k + word
  let t2 := big0 a + majority a b c
  [t1+t2,a,b,c,d+t1,e,f,g]

def compress (state : List Word) (block : List Byte) : List Word :=
  let words := schedule block
  let final := (List.range 64).foldl (fun current i => round current (wordAt words i) (wordAt constants i)) state
  (List.range 8).map (fun i => wordAt state i+wordAt final i)

def zeroCount (length : Nat) : Nat := (119-length%64)%64
def blockCount (length : Nat) : Nat := length/64+1+(if length%64 < 56 then 0 else 1)

def pad (bytes : List Byte) : List Byte :=
  bytes ++ [128] ++ List.replicate (zeroCount bytes.length) 0 ++
    (List.range 8).map (fun i => BitVec.ofNat 8 (bytes.length*8 / 256^(7-i)))

def hash (bytes : List Byte) : List Word :=
  let padded := pad bytes
  (List.range (blockCount bytes.length)).foldl
    (fun state i => compress state ((padded.drop (i*64)).take 64)) initial

theorem xor_formula {F : Type} [Field F] (a b : Bool) :
    (a.toNat : F)+(b.toNat : F)-2*(a.toNat : F)*(b.toNat : F) = (Bool.xor a b).toNat := by
  cases a <;> cases b <;> simp <;> grind

theorem choose_formula {F : Type} [Field F] (a b c : Bool) :
    (c.toNat : F)+(a.toNat : F)*((b.toNat : F)-(c.toNat : F)) = (if a then b else c).toNat := by
  cases a <;> cases b <;> cases c <;> simp <;> grind

theorem majority_formula {F : Type} [Field F] (a b c : Bool) :
    (a.toNat : F)*(b.toNat : F)+(c.toNat : F)*
      ((a.toNat : F)+(b.toNat : F)-2*(a.toNat : F)*(b.toNat : F)) =
    ((a && b) || (a && c) || (b && c)).toNat := by
  cases a <;> cases b <;> cases c <;> simp <;> grind

theorem add_low_unique (sum low carry : Nat) (range : low < 2^32)
    (bound : sum = low+2^32*carry) : low = sum % 2^32 := by omega

theorem padding_length (length : Nat) :
    length+1+zeroCount length+8 = 64*blockCount length := by
  have remainder := Nat.mod_lt length (by decide : 0 < 64)
  unfold zeroCount blockCount
  split <;> omega

theorem padded_length (bytes : List Byte) : (pad bytes).length = 64*blockCount bytes.length := by
  have sized := padding_length bytes.length
  simp only [pad, List.length_append, List.length_cons, List.length_nil, List.length_replicate, List.length_map, List.length_range]
  omega

theorem block_count_ceil (length : Nat) : blockCount length = (length+72)/64 := by
  have remainder := Nat.mod_lt length (by decide : 0 < 64)
  unfold blockCount
  split <;> omega

theorem block_count_monotone (length capacity : Nat) (bound : length ≤ capacity) :
    blockCount length ≤ blockCount capacity := by
  rw [block_count_ceil,block_count_ceil]
  omega

theorem carry_bit_formula : ∀ offset : Fin 64,
    offset.val/8%2*(offset.val/16%2)*(offset.val/32) =
      (if offset.val < 56 then 0 else 1) := by decide

theorem marker_precedes_length_field (length : Nat) :
    length+1 ≤ 64*blockCount length-8 := by
  have sized := padding_length length
  omega

theorem message_precedes_length_field (length position : Nat) (inside : position < length) :
    position < 64*blockCount length-8 := by
  have marker := marker_precedes_length_field length
  omega

theorem bit_length_bound (length : Nat) (u32 : length < 2^32) : length*8 < 2^35 := by omega

theorem length_field_fits (length : Nat) (u32 : length < 2^32) : length*8 < 2^64 := by
  have bounded := bit_length_bound length u32
  omega

theorem final_block_exists (length capacity : Nat) (bounded : length ≤ capacity) :
    length/64 + (if length%64 < 56 then 0 else 1) < blockCount capacity := by
  have bound := block_count_monotone length capacity bounded
  unfold blockCount at bound ⊢
  omega

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem empty_known_answer : hash [] =
    [0xe3b0c442,0x98fc1c14,0x9afbf4c8,0x996fb924,0x27ae41e4,0x649b934c,0xa495991b,0x7852b855] := by decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem abc_known_answer : hash [97,98,99] =
    [0xba7816bf,0x8f01cfea,0x414140de,0x5dae2223,0xb00361a3,0x96177a9c,0xb410ff61,0xf20015ad] := by decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem two_block_known_answer :
    hash ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toList.map
      (fun c => BitVec.ofNat 8 c.toNat)) =
    [0x248d6a61,0xd20638b8,0xe5c02693,0x0c3e6039,0xa33ce459,0x64ff2167,0xf6ecedd4,0x19db06c1] := by decide

#print axioms xor_formula
#print axioms choose_formula
#print axioms majority_formula
#print axioms add_low_unique
#print axioms padding_length
#print axioms padded_length
#print axioms block_count_monotone
#print axioms carry_bit_formula
#print axioms marker_precedes_length_field
#print axioms message_precedes_length_field
#print axioms length_field_fits
#print axioms final_block_exists
#print axioms empty_known_answer
#print axioms abc_known_answer
#print axioms two_block_known_answer

end ZkBuild.Sha256
