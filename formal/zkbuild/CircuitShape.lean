import R1CS
import ByteStream

/- Integer-coefficient specification of the complete byte-profile matrix.
   Unlike a comparison of generated witnesses, matrix equality covers every
   possible assignment of field elements to the wires. -/
namespace ZkBuild.CircuitShape

attribute [local instance] Lean.Grind.Ring.intCast

abbrev Term := Nat × Int
abbrev Linear := List Term

structure Gate where
  a : Linear
  b : Linear
  c : Linear
  deriving BEq, ReflBEq, LawfulBEq, Repr, Inhabited, DecidableEq

structure RowInfo where
  inputs : Array Linear
  outputs : Array Linear
  wireStart : Nat
  gateStart : Nat
  deriving Inhabited

structure Shape where
  wires : Nat := 1
  publicCount : Nat := 0
  gates : Array Gate := #[]
  rows : Array RowInfo := #[]

abbrev Builder := StateM Shape

def constant (n : Int) : Linear := [(0, n)]
def scale (xs : Linear) (n : Int) : Linear := xs.map fun (wire, coefficient) => (wire, coefficient * n)
def sub (xs ys : Linear) : Linear := xs ++ scale ys (-1)
def total (xs : Array Linear) : Linear := xs.toList.flatten

def fresh : Builder Linear := do
  let s ← get
  set { s with wires := s.wires + 1 }
  return [(s.wires, 1)]

def constrain (a b c : Linear) : Builder Unit :=
  modify fun s => { s with gates := s.gates.push ⟨a, b, c⟩ }

def equal (a b : Linear) : Builder Unit := constrain (sub a b) (constant 1) (constant 0)

def mul (a b : Linear) : Builder Linear := do
  let output ← fresh
  constrain a b output
  return output

def bit : Builder Linear := do
  let output ← fresh
  constrain output (sub output (constant 1)) (constant 0)
  return output

def weighted (bits : Array Linear) : Linear :=
  (bits.toList.zipIdx.map fun (b, i) => scale b (Int.ofNat (2^i))).flatten

structure Parser where
  ready : Linear
  index : Linear
  done : Linear
  leb : Array Linear
  depths : Array Linear

def initial : Parser := {
  ready := constant 1, index := constant 0, done := constant 0,
  leb := Array.replicate 5 (constant 0),
  depths := (List.range 9).toArray.map fun i => constant (if i = 0 then 1 else 0)
}

def lookupLinear (xs : Array Linear) (i : Nat) : Linear := xs[i]?.getD []

def row (state : Parser) (bits : Array Linear) : Builder Parser := do
  let before ← get
  let value := weighted bits
  let continuation := lookupLinear bits 7
  let terminate := sub (constant 1) continuation
  constrain state.done value (constant 0)
  let mut selected := #[]
  let mut selectedValue := []
  for action in [:10] do
    let selector ← bit
    selected := selected.push selector
    selectedValue := selectedValue ++ scale selector (Int.ofNat (ByteStream.opcode action))
  equal (total selected) state.ready
  constrain state.ready value selectedValue
  for i in [1:8] do constrain state.index (lookupLinear bits i) (constant 0)
  constrain (lookupLinear state.leb 4) continuation (constant 0)
  for i in [4:7] do constrain (lookupLinear state.leb 4) (sub (lookupLinear bits i) (lookupLinear bits 3)) (constant 0)
  let finish ← mul (total state.leb) terminate
  let push := state.index ++ finish
  let binary := total ((selected.toList.drop 3).take 6).toArray
  constrain binary ((lookupLinear state.depths 0) ++ (lookupLinear state.depths 1)) (constant 0)
  let keep := sub (sub (constant 1) push) binary
  let mut depths := #[]
  for depth in [:9] do
    let mut value ← mul (lookupLinear state.depths depth) keep
    if depth > 0 then
      let pushed ← mul (lookupLinear state.depths (depth - 1)) push
      value := value ++ pushed
    if depth < 8 then
      let popped ← mul (lookupLinear state.depths (depth + 1)) binary
      value := value ++ popped
    depths := depths.push value
  equal (total depths) (constant 1)
  constrain (lookupLinear selected 9) (sub (lookupLinear state.depths 1) (constant 1)) (constant 0)
  let mut leb := #[lookupLinear selected 2]
  for i in [1:5] do leb := leb.push (← mul (lookupLinear state.leb (i - 1)) continuation)
  let ready := (lookupLinear selected 0) ++ binary ++ state.index ++ finish
  let index := lookupLinear selected 1
  let done := sub (sub (sub (constant 1) ready) index) (total leb)
  let inputs := #[state.ready, state.index] ++ state.leb ++ #[state.done] ++ state.depths ++ bits
  let outputs := #[ready, index] ++ leb ++ #[done] ++ depths
  modify fun s => { s with rows := s.rows.push ⟨inputs, outputs, before.wires, before.gates.size⟩ }
  return ⟨ready, index, done, leb, depths⟩

def modulePrefix : Array Nat := #[
  0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127,
  3, 2, 1, 0, 7, 7, 1, 3, 114, 117, 110, 0, 0, 10, 100, 1, 98, 0]

def build : Builder Unit := do
  let mut publicWires := #[]
  for _ in [:7] do publicWires := publicWires.push (← fresh)
  modify fun s => { s with publicCount := 7 }
  let mut bytes := #[]
  let mut byteBits := #[]
  for _ in [:156] do
    let mut bits := #[]
    for _ in [:8] do bits := bits.push (← bit)
    byteBits := byteBits.push bits
    bytes := bytes.push (weighted bits)
  let mut limb := 1
  let mut packed := []
  let mut weight : Int := 1
  for i in [:156] do
    packed := packed ++ scale (lookupLinear bytes i) weight
    weight := weight * 256
    if i % 31 = 30 || i = 155 then
      equal packed (lookupLinear publicWires limb)
      limb := limb + 1
      packed := []
      weight := 1
  for i in [:modulePrefix.size] do
    if 25 ≤ i && i ≤ 27 then
      equal (lookupLinear (byteBits[i]?.getD #[]) 7) (constant 0)
    else if i = 31 then equal (lookupLinear bytes i) (sub (lookupLinear publicWires 0) (constant 32))
    else if i = 33 then equal (lookupLinear bytes i) (sub (lookupLinear publicWires 0) (constant 34))
    else equal (lookupLinear bytes i) (constant (Int.ofNat (modulePrefix[i]?.getD 0)))
  let mut state := initial
  let mut processed := constant 0
  for position in [modulePrefix.size:156] do
    processed := sub (processed ++ constant 1) state.done
    state ← row state (byteBits[position]?.getD #[])
  equal state.done (constant 1)
  equal processed (sub (lookupLinear publicWires 0) (constant (Int.ofNat modulePrefix.size)))

def byteShape : Shape := (build.run {}).2

def interpretLinear {F : Type} [Lean.Grind.CommRing F] (linear : Linear) : R1CS.Linear F :=
  linear.map fun (wire, coefficient) => ⟨wire, (coefficient : F)⟩

def interpretGate {F : Type} [Lean.Grind.CommRing F] (gate : Gate) : R1CS.Constraint F :=
  ⟨interpretLinear gate.a, interpretLinear gate.b, interpretLinear gate.c⟩

def Satisfied {F : Type} [Lean.Grind.CommRing F] (shape : Shape) (values : Nat → F) : Prop :=
  ∀ gate ∈ shape.gates.toList, R1CS.Holds values (interpretGate gate)

def normalizeLinear (linear : Linear) : Linear :=
  linear.map fun (wire, coefficient) => (wire, coefficient % Int.ofNat scalarModulus)

-- Most serialized coefficients are already canonical. Avoid a big-integer
-- remainder in that case; the compiler substitution is justified below.
def normalizeLinearFast (linear : Linear) : Linear :=
  linear.map fun (wire, coefficient) =>
    if 0 ≤ coefficient ∧ coefficient < Int.ofNat scalarModulus then (wire,coefficient)
    else (wire,coefficient % Int.ofNat scalarModulus)

@[csimp] theorem normalizeLinear_fast : normalizeLinear = normalizeLinearFast := by
  funext linear
  apply List.map_congr_left
  intro term _
  rcases term with ⟨wire,coefficient⟩
  change (wire,coefficient % Int.ofNat scalarModulus) =
    (if 0 ≤ coefficient ∧ coefficient < Int.ofNat scalarModulus then (wire,coefficient)
      else (wire,coefficient % Int.ofNat scalarModulus))
  by_cases canonical : 0 ≤ coefficient ∧ coefficient < Int.ofNat scalarModulus
  · rw [if_pos canonical,Int.emod_eq_of_lt canonical.1 canonical.2]
  · rw [if_neg canonical]

def normalizeGate (gate : Gate) : Gate :=
  ⟨normalizeLinear gate.a, normalizeLinear gate.b, normalizeLinear gate.c⟩

theorem normalized_linear_same_field {F : Type} [Lean.Grind.CommRing F]
    [Lean.Grind.IsCharP F scalarModulus] (linear : Linear) :
    interpretLinear (F := F) (normalizeLinear linear) = interpretLinear linear := by
  simp [interpretLinear, normalizeLinear, List.map_map, Lean.Grind.IsCharP.intCast_emod]

theorem normalized_gate_same_field {F : Type} [Lean.Grind.CommRing F]
    [Lean.Grind.IsCharP F scalarModulus] (gate : Gate) :
    interpretGate (F := F) (normalizeGate gate) = interpretGate gate := by
  simp [interpretGate, normalizeGate, normalized_linear_same_field]

theorem same_canonical_matrix_same_relation {F : Type} [Lean.Grind.CommRing F]
    [Lean.Grind.IsCharP F scalarModulus] (a b : Shape)
    (same : a.gates.toList.map normalizeGate = b.gates.toList.map normalizeGate)
    (values : Nat → F) : Satisfied a values ↔ Satisfied b values := by
  have mapped := congrArg (fun gs => ∀ gate ∈ gs, R1CS.Holds values (interpretGate gate)) same
  simpa [Satisfied, normalized_gate_same_field] using mapped

-- Exact matrix equality is stronger than comparison of accepted sample
-- witnesses: it transfers satisfaction for arbitrary field-valued witnesses.
theorem identical_matrix_same_relation {F : Type} [Lean.Grind.CommRing F]
    (a b : Shape) (same : a.gates = b.gates) (values : Nat → F) :
    Satisfied a values ↔ Satisfied b values := by
  simp only [Satisfied, same]

#print axioms normalizeLinear_fast
#print axioms identical_matrix_same_relation
#print axioms same_canonical_matrix_same_relation

end ZkBuild.CircuitShape
