import VariableTyping
set_option autoImplicit false
namespace ZkBuild.OpcodeCatalog

-- Independent declarative binary layout for the runtime's unfused opcode set.
-- Numeric/variable admission uses the existing formal type-rule catalog.
def simdSubcodes : List Nat := [0,11,12,15,16,17,18,19,20,27,28,31,32,77,78,80,81,174,177,181,228,229,230,231,21,22,23,24,25,26,29,30,33,34,79,96,97,110,113,118,119,120,121,128,129,142,145,149,160,161,171,172,173,182,183,184,185,206,209,224,225,236,237,240,241,242,243]

def admitted (code : Nat) : Bool :=
  (StaticTyping.signature code).isSome || VariableTyping.environment code != 0 ||
  [2,3,4,5,8,10,11,12,13,14,15,16,17,18,19,0x1b,0x1c,0x1f,0xd0].contains code

def form (code : Nat) : Nat :=
  if code < 256 then
    if [2,3,4].contains code then 3
    else if code = 0x1f then 5
    else if code = 0x0e then 4
    else if [8,12,13,16,18,0x3f,0x40,0xd2].contains code || (0x20 ≤ code && code ≤ 0x26) then 1
    else if [17,19].contains code || (0x28 ≤ code && code ≤ 0x3e) then 2
    else if code = 0x1c then 6
    else if code = 0x41 then 7
    else if code = 0x42 then 8
    else if code = 0x43 then 9
    else if code = 0x44 then 10
    else if code = 0xd0 then 11 else 0
  else if code ≤ 0x111 then
    if [0x108,0x10a,0x10c,0x10e].contains code then 2
    else if [0x109,0x10b,0x10d].contains code || (0x10f ≤ code && code ≤ 0x111) then 1 else 0
  else if code = 0x300 || code = 0x301 then 2
  else if code = 0x302 then 13
  else if (0x309 ≤ code && code ≤ 0x30c) || (0x318 ≤ code && code ≤ 0x321) then 12 else 0

def modes (form : Nat) : Nat × Nat :=
  if form = 1 || form = 4 then (2,0)
  else if form = 2 then (2,2)
  else if form = 3 then (4,0)
  else if form = 5 then (4,2)
  else if form = 6 then (2,1)
  else if form = 7 then (3,0)
  else if form = 8 then (5,0)
  else if form = 9 then (6,0)
  else if form = 10 then (7,0)
  else if form = 11 || form = 12 then (1,0)
  else if form = 13 then (7,7) else (0,0)

def fields (code : Nat) : List Nat :=
  if !admitted code then [0,0,0,0,0,0,0,0]
  else if code < 256 then
    let mode := modes (form code)
    [1,code,0,0,form code,if 0x28 ≤ code && code ≤ 0x3e then 1 else 0,mode.1,mode.2]
  else if 0x100 ≤ code && code ≤ 0x111 then
    let mode := modes (form code)
    [1,0xfc,1,code-0x100,form code,0,mode.1,mode.2]
  else if 0x300 ≤ code && code ≤ 0x342 then
    let mode := modes (form code)
    [1,0xfd,1,simdSubcodes.getD (code-0x300) 0,form code,0,mode.1,mode.2]
  else [0,0,0,0,0,0,0,0]

def payload (code field : Nat) : Int := Int.ofNat ((fields code).getD field 0)

theorem simd_count : simdSubcodes.length = 67 := by decide
theorem simd_unique : simdSubcodes.Nodup := by decide
#print axioms simd_count
#print axioms simd_unique
end ZkBuild.OpcodeCatalog
