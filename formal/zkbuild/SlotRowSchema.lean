import SlotShape
import RowMatrix

/- Algebraic semantics of one compilation slot after eliminating every
   multiplication-result wire. Inputs are nine prior depths followed by 63
   Boolean wires: ten op selectors, 32 immediate bits, 20 upper bits, carry. -/
namespace ZkBuild.SlotRow

open Lean.Grind RowSoundness CircuitShape
attribute [local instance] Ring.intCast Semiring.natCast

def prior (i : Nat) : Expr := .input i
def selected (i : Nat) : Expr := .input (9+i)
def valueBit (i : Nat) : Expr := .input (19+i)
def upperBit (i : Nat) : Expr := .input (51+i)
def overflow : Expr := .input 71

def packed (f : Nat → Expr) (start count : Nat) : Expr :=
  sumExpr ((List.range count).map fun i => f (start+i) * .literal (Int.ofNat (2^i)))

def constBytes : Array Expr :=
  ((List.range 4).map fun i => (128 : Expr) + packed valueBit (7*i) 7).toArray |>.push
    (packed valueBit 28 4 + valueBit 31 * 112)

def constantWord (word : Nat) : Array Expr :=
  (List.range 4).toArray.map fun i => .literal (Int.ofNat ((word >>> (8*i)) % 256))

def words (kind depth : Nat) : Array Expr := Id.run do
  let mut result := constantWord 0x13 ++ constantWord 0x13
  if SlotShape.pushes kind then
    let rd := SlotShape.register depth
    if kind = 3 then
      result := constantWord ((rd <<< 7) ||| 0x37) ++ constantWord (SlotShape.addi rd rd)
      result := result.set! 1 (result[1]! + packed upperBit 0 4 * 16)
      result := result.set! 2 (packed upperBit 4 8)
      result := result.set! 3 (packed upperBit 12 8)
      result := result.set! 6 (result[6]! + packed valueBit 0 4 * 16)
      result := result.set! 7 (packed valueBit 4 8)
    else result := constantWord (SlotShape.addi rd (if kind = 1 then 28 else 29)) ++ constantWord 0x13
  else if SlotShape.binary kind then
    result := constantWord (SlotShape.binaryWord kind (SlotShape.register (depth-2)) (SlotShape.register (depth-1))) ++ constantWord 0x13
  return result

def transitions : List (Nat × Nat) :=
  (List.range 10).flatMap fun kind => (List.range 9).filterMap fun depth =>
    if SlotShape.valid kind depth then some (kind, depth) else none

def nextDepths : List Expr := (List.range 9).map fun output =>
  sumExpr (transitions.filterMap fun (kind, depth) =>
    if SlotShape.nextDepth kind depth = output then some (selected kind * prior depth) else none)

def wasmBytes : List Expr :=
  sumExpr ((List.range 10).map fun kind => selected kind * .literal (Int.ofNat (SlotShape.opcode kind))) ::
    ((List.range 5).map fun j => sumExpr ((List.range 10).map fun kind =>
      selected kind * (if kind = 3 then constBytes[j]!
        else if kind = 1 ∧ j = 0 then 0 else 1)))

def nativeBytes : List Expr := (List.range 8).map fun j =>
  sumExpr (transitions.map fun (kind, depth) => selected kind * prior depth * (words kind depth)[j]!)

def residuals : List Expr :=
  ((List.range 63).map fun i => (.input (9+i) : Expr) * (.input (9+i) - 1)) ++
  [sumExpr ((List.range 10).map selected) - 1,
   packed valueBit 0 32 + 2048 -
     (packed upperBit 0 20 * 4096 + (packed valueBit 0 11 + (1-valueBit 11)*2048) + overflow*4294967296),
   sumExpr nextDepths - 1]

def outputs : List Expr := nextDepths ++ wasmBytes ++ nativeBytes
def rowBuild : SlotShape.Output × Shape :=
  (SlotShape.slot true ((List.range 9).toArray.map fun i => SlotShape.wire (i+1))).run { wires := 10 }
def outputLinears : List Linear := rowBuild.1.depths.toList ++ rowBuild.1.wasm.toList ++ rowBuild.1.native.toList
def sourceWire (i : Nat) : Nat := if i < 51 then i+1 else i+6
def baseEnvironment : Array Expr := #[.literal 1] ++ (List.range 51).toArray.map Expr.input
def productGate (j : Fin 5) : Gate := rowBuild.2.gates[43+j.val]!
def productExpression (j : Fin 5) : Expr :=
  RowMatrix.linearExpr baseEnvironment (productGate j).a * RowMatrix.linearExpr baseEnvironment (productGate j).b
def inputEnvironment : Array Expr := baseEnvironment ++
  (List.finRange 5).toArray.map productExpression ++ (List.range 21).toArray.map fun i => Expr.input (51+i)
def eliminated := RowMatrix.eliminate inputEnvironment rowBuild.2.gates.toList

def certificate : Bool := match eliminated with
  | none => false
  | some result =>
    result.environment.size == 753 && result.assertions.length == 71 &&
    (0 :: residuals).all (fun expected => result.assertions.any (RowMatrix.samePolynomial expected)) &&
    result.assertions.all (fun actual => (0 :: residuals).any (RowMatrix.samePolynomial actual)) &&
    RowMatrix.polynomialListEqual (outputLinears.map (RowMatrix.linearExpr result.environment)) outputs

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem row_certificate : certificate = true := by native_decide

theorem base_entries : ∀ i : Fin 52,
    baseEnvironment[i.val]? = some (if i.val = 0 then .literal 1 else .input (i.val-1)) := by native_decide

theorem input_entries : ∀ i : Fin 78,
    inputEnvironment[i.val]? = some (if i.val = 0 then .literal 1 else if i.val < 52 then .input (i.val-1)
      else if h : i.val < 57 then productExpression ⟨i.val-52, by omega⟩ else .input (i.val-6)) := by native_decide

theorem product_gates : ∀ j : Fin 5,
    productGate j ∈ rowBuild.2.gates.toList ∧ (productGate j).c = [(52+j.val, 1)] ∧
    RowMatrix.inBounds baseEnvironment (productGate j).a = true ∧
    RowMatrix.inBounds baseEnvironment (productGate j).b = true := by native_decide

theorem outputs_bounded : outputLinears.all (fun linear => linear.all fun term => term.1 < 753) = true := by
  native_decide


#print axioms row_certificate

end ZkBuild.SlotRow
