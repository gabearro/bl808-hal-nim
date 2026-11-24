import CircuitShape

/- Independent integer-coefficient specification of the fixed-slot validation
   and compilation matrices built by wasm_circuit.nim. -/
namespace ZkBuild.SlotShape

open CircuitShape

def wire (i : Nat) : Linear := [(i, 1)]
def getLinear (xs : Array Linear) (i : Nat) : Linear := lookupLinear xs i
def packedSlice (xs : Array Linear) (start count : Nat) : Linear := weighted ((xs.toList.drop start).take count).toArray

def opcode (kind : Nat) : Nat :=
  match kind with
  | 0 => 1
  | 1 | 2 => 0x20
  | 3 => 0x41
  | 4 => 0x6a
  | 5 => 0x6b
  | 6 => 0x6c
  | 7 => 0x71
  | 8 => 0x72
  | _ => 0x73

def pushes (kind : Nat) : Bool := 1 ≤ kind && kind ≤ 3
def binary (kind : Nat) : Bool := 4 ≤ kind
def valid (kind depth : Nat) : Bool := !(pushes kind && depth == 8 || binary kind && depth < 2)
def nextDepth (kind depth : Nat) : Nat := if pushes kind then depth+1 else if binary kind then depth-1 else depth
def register (depth : Nat) : Nat := if depth < 3 then depth+5 else depth+7
def addi (destination source : Nat) : Nat := (source <<< 15) ||| (destination <<< 7) ||| 0x13
def binaryWord (kind destination right : Nat) : Nat :=
  let base := (right <<< 20) ||| (destination <<< 15) ||| (destination <<< 7) ||| 0x33
  match kind with
  | 5 => base ||| 0x40000000
  | 6 => base ||| 0x02000000
  | 7 => base ||| (7 <<< 12)
  | 8 => base ||| (6 <<< 12)
  | 9 => base ||| (4 <<< 12)
  | _ => base

def wordBytes (word : Nat) : Array Linear :=
  (List.range 4).toArray.map fun i => constant (Int.ofNat ((word >>> (8*i)) % 256))

structure Output where
  depths : Array Linear
  wasm : Array Linear
  native : Array Linear
  deriving Inhabited

def slot (compile : Bool) (depths : Array Linear) : Builder Output := do
  let before ← get
  let mut selectors := #[]
  for _ in [:10] do selectors := selectors.push (← bit)
  equal (total selectors) (constant 1)
  let mut bits := #[]
  for _ in [:32] do bits := bits.push (← bit)
  let mut constBytes := #[]
  for i in [:4] do constBytes := constBytes.push (constant 128 ++ packedSlice bits (7*i) 7)
  constBytes := constBytes.push (packedSlice bits 28 4 ++ scale (getLinear bits 31) 112)
  let mut wasm := Array.replicate 6 ([] : Linear)
  for kind in [:10] do
    wasm := wasm.set! 0 (getLinear wasm 0 ++ scale (getLinear selectors kind) (Int.ofNat (opcode kind)))
    for j in [1:6] do
      if kind = 3 then
        wasm := wasm.set! j (getLinear wasm j ++ (← mul (getLinear selectors kind) (getLinear constBytes (j-1))))
      else if kind = 1 then
        if j != 1 then wasm := wasm.set! j (getLinear wasm j ++ getLinear selectors kind)
      else wasm := wasm.set! j (getLinear wasm j ++ getLinear selectors kind)
  let mut next := Array.replicate 9 ([] : Linear)
  let mut native := Array.replicate 8 ([] : Linear)
  let mut upper := #[]
  if compile then
    for _ in [:20] do upper := upper.push (← bit)
    let overflow ← bit
    let remainder := packedSlice bits 0 11 ++ scale (sub (constant 1) (getLinear bits 11)) 2048
    equal (weighted bits ++ constant 2048)
      (scale (weighted upper) 4096 ++ remainder ++ scale overflow 4294967296)
  for kind in [:10] do
    for depth in [:9] do
      if valid kind depth then
        let active ← mul (getLinear selectors kind) (getLinear depths depth)
        let output := nextDepth kind depth
        next := next.set! output (getLinear next output ++ active)
        if compile then
          let mut words := wordBytes 0x13 ++ wordBytes 0x13
          if pushes kind then
            let rd := register depth
            if kind = 3 then
              words := wordBytes ((rd <<< 7) ||| 0x37) ++ wordBytes (addi rd rd)
              words := words.set! 1 (getLinear words 1 ++ scale (packedSlice upper 0 4) 16)
              words := words.set! 2 (packedSlice upper 4 8)
              words := words.set! 3 (packedSlice upper 12 8)
              words := words.set! 6 (getLinear words 6 ++ scale (packedSlice bits 0 4) 16)
              words := words.set! 7 (packedSlice bits 4 8)
            else words := wordBytes (addi rd (if kind = 1 then 28 else 29)) ++ wordBytes 0x13
          else if binary kind then
            words := wordBytes (binaryWord kind (register (depth-2)) (register (depth-1))) ++ wordBytes 0x13
          for j in [:8] do native := native.set! j (getLinear native j ++ (← mul active (getLinear words j)))
  equal (total next) (constant 1)
  modify fun shape => { shape with rows := shape.rows.push ⟨depths, next ++ wasm ++ native, before.wires, before.gates.size⟩ }
  return ⟨next, wasm, native⟩

def bindBytes (bytes publicWires : Array Linear) : Builder Unit := do
  let mut packed := []
  let mut weight : Int := 1
  let mut limb := 0
  for i in [:bytes.size] do
    packed := packed ++ scale (getLinear bytes i) weight
    weight := weight*256
    if i % 31 = 30 || i+1 = bytes.size then
      equal packed (getLinear publicWires limb)
      limb := limb+1
      packed := []
      weight := 1

def build (compile : Bool) : Builder Unit := do
  let mut publicWires := #[]
  for _ in [:(if compile then 10 else 5)] do publicWires := publicWires.push (← fresh)
  modify fun shape => { shape with publicCount := publicWires.size }
  let mut wasm := modulePrefix.map fun byte => constant (Int.ofNat byte)
  let mut native := wordBytes (addi 28 10) ++ wordBytes (addi 29 11)
  let mut depths := (List.range 9).toArray.map fun i => constant (if i = 0 then 1 else 0)
  for _ in [:16] do
    let next ← slot compile depths
    depths := next.depths
    wasm := wasm ++ next.wasm
    if compile then native := native ++ next.native
  equal (getLinear depths 1) (constant 1)
  wasm := wasm.push (constant 0x0b)
  native := native ++ wordBytes (addi 10 (register 0)) ++ wordBytes 0x00008067
  bindBytes wasm (publicWires.toList.take 5).toArray
  if compile then bindBytes native (publicWires.toList.drop 5).toArray

def shape (compile : Bool) : Shape := (build compile).run {} |>.2
def compileShape : Shape := shape true
def validateShape : Shape := shape false

theorem compile_dimensions :
    compileShape.wires = 11899 ∧ compileShape.publicCount = 10 ∧ compileShape.gates.size = 11947 ∧ compileShape.rows.size = 16 := by
  native_decide

theorem validate_dimensions :
    validateShape.wires = 1958 ∧ validateShape.publicCount = 5 ∧ validateShape.gates.size = 1990 ∧ validateShape.rows.size = 16 := by
  native_decide

#print axioms compile_dimensions
#print axioms validate_dimensions

end ZkBuild.SlotShape
