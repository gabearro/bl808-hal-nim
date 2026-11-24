import SlotShape

/- Independent integer-coefficient matrix for ordinary-byte compilation.
   Both established component matrices are substituted into disjoint private
   wire ranges. The bridge decodes constants and queues non-nop operations. -/
namespace ZkBuild.ByteCompileShape

open CircuitShape

def remap (wires : Array Linear) (linear : Linear) : Linear :=
  linear.flatMap fun (wire, coefficient) => scale (lookupLinear wires wire) coefficient

def appendShape (source : Shape) (publicWires : Array Linear) : Builder (Array Linear) := do
  let mut wires := #[constant 1] ++ publicWires
  for _ in [source.publicCount+1:source.wires] do wires := wires.push (← fresh)
  for gate in source.gates do
    constrain (remap wires gate.a) (remap wires gate.b) (remap wires gate.c)
  return wires

def materialize (expression : Linear) : Builder Linear := do
  let output ← fresh
  equal output expression
  return output

def selectWire (selector yes no : Linear) : Builder Linear := do
  let output ← fresh
  constrain selector (sub yes no) (sub output no)
  return output

structure Parts where
  bytes : Array Linear
  slots : Array Linear
  queue : Array Linear

def build : Builder Parts := do
  let mut publicWires := #[]
  for _ in [:12] do publicWires := publicWires.push (← fresh)
  modify fun s => { s with publicCount := 12 }
  let bytes ← appendShape byteShape (publicWires.toList.take 7).toArray
  let mut slotPublic := #[]
  for _ in [:5] do slotPublic := slotPublic.push (← fresh)
  slotPublic := slotPublic ++ (publicWires.toList.drop 7).toArray
  let slots ← appendShape SlotShape.compileShape slotPublic
  let mut queue := Array.replicate 16 (constant 0)
  let mut immediate := constant 0
  for row in byteShape.rows do
    let bits := ((row.inputs.toList.drop 17).take 8).toArray.map (remap bytes)
    let selected := (List.range 10).toArray.map fun i => remap bytes [(row.wireStart+i, 1)]
    let beginConst := lookupLinear selected 2
    let finishConst := remap bytes [(row.wireStart+10, 1)]
    let get := remap bytes (lookupLinear row.inputs 1)
    let binary := total ((selected.toList.drop 3).take 6).toArray
    let event := get ++ finishConst ++ binary
    let mut payload := []
    let mut signExtension := []
    for i in [:5] do
      let phase := remap bytes (lookupLinear row.inputs (2+i))
      let bitCount := if i = 4 then 4 else 7
      let product ← mul phase (weighted (bits.toList.take bitCount).toArray)
      payload := payload ++ scale product (Int.ofNat (2^(7*i)))
      if i < 4 then
        signExtension := signExtension ++ scale phase (Int.ofNat (2^32 - 2^(7*(i+1))))
    let negativeEnd ← mul (sub (constant 1) (lookupLinear bits 7)) (lookupLinear bits 6)
    let sign ← mul negativeEnd signExtension
    let previous ← selectWire beginConst (constant 0) immediate
    immediate ← materialize (previous ++ payload ++ sign)
    let getToken ← mul get (constant 1 ++ lookupLinear bits 0)
    let constToken ← mul finishConst (constant 3 ++ scale immediate 16)
    let mut token := getToken ++ constToken
    for action in [3:9] do token := token ++ scale (lookupLinear selected action) (Int.ofNat (action+1))
    constrain event (lookupLinear queue 0) (constant 0)
    let mut next := #[]
    for i in [:16] do
      let yes := if i+1 < 16 then lookupLinear queue (i+1) else token
      next := next.push (← selectWire event yes (lookupLinear queue i))
    queue := next
  for i in [:16] do
    let row := SlotShape.compileShape.rows[i]!
    let mut kind := []
    for op in [:10] do
      kind := kind ++ scale (remap slots [(row.wireStart+op, 1)]) (Int.ofNat op)
    let bits := (List.range 32).toArray.map fun bit => remap slots [(row.wireStart+10+bit, 1)]
    let value ← mul (remap slots [(row.wireStart+3, 1)]) (weighted bits)
    equal (lookupLinear queue i) (kind ++ scale value 16)
  return ⟨bytes, slots, queue⟩

def built : Parts × Shape := build.run {}
def shape : Shape := built.2

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem dimensions : shape.wires = 21277 ∧ shape.publicCount = 12 ∧ shape.gates.size = 23555 := by
  native_decide

#print axioms dimensions

end ZkBuild.ByteCompileShape
