import NameSourceSyntax
set_option autoImplicit false
namespace ZkBuild.ConstantSourceMatrix
open CircuitShape GadgetShape DeclarationMatrix

structure Read where
  token : Nat
  cursor : Linear
  deriving Inhabited
structure Record where
  firstGate : Nat
  lastGate : Nat
  heads : Nat
  zeroStarts : List Nat
  fields : List Linear
  selectors : List Linear
  reads : List Read
  deriving Inhabited

def field (r : Record) (i : Nat) := get r.fields i
def selected (r : Record) (i : Nat) := get r.selectors i
def readAt (r : Record) (i : Nat) := r.reads.getD i default
def opcodes : List Nat := [0x41,0x42,0x43,0x44,0x302,0xd0,0xd2,0x23]
def modes : List Nat := [3,5,6,7,7,1,2,2]
def sumSelected (r : Record) := z ++ ((List.range 8).map (selected r)).flatten
def mode (r : Record) := z ++ scale (selected r 0) 3 ++ scale (selected r 1) 5 ++
  scale (selected r 2) 6 ++ scale (selected r 3) 7 ++ scale (selected r 4) 7 ++
  scale (selected r 5) 1 ++ scale (selected r 6) 2 ++ scale (selected r 7) 2
def wide (r : Record) := selected r 1 ++ selected r 3
def vector (r : Record) := selected r 4
def cursor (r : Record) (i : Nat) := if i = 0 then field r 2 else (readAt r (i-1)).cursor
def same (a b : Linear) : Prop := normalizeLinear a = normalizeLinear b
instance (a b : Linear) : Decidable (same a b) := by unfold same; infer_instance

def selectorGates (r : Record) (i : Nat) : List Gate :=
  let start := r.zeroStarts.getD i 0
  zeroGates (sub (field r 5) (n (opcodes.getD i 0))) (wire start) (wire (start+1)) ++
    [mulGate (field r 8) (wire start) (selected r i)]
def readGates (tokens : Tokens) (r : Record) (i : Nat) : List Gate :=
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  BinaryTokenMatrix.gates t ++ [eqGate (readAt r i).cursor (cursor r i ++ t.length)]
def parts (tokens : Tokens) (splits : Splits) (r : Record) : List (List Gate) :=
  [[mulGate (field r 0) (field r 1) (field r 8),eqGate (field r 3) (field r 0),gate (field r 0) (sub (field r 4) o)],
   (List.range 8).flatMap (selectorGates r),
   [eqGate (sumSelected r) (field r 8),mulGate (field r 8) (field r 5) (field r 10)],
   readGates tokens r 0,readGates tokens r 1,
   [mulGate (field r 8) (field r 11) (field r 12),mulGate (vector r) (field r 13) (field r 14)],
   readGates tokens r 2,readGates tokens r 3,
   splitGates (split splits r.heads) ++
     [mulGate (wide r) (split splits r.heads).low (field r 15),
      mulGate (sub (sub (field r 8) (wide r)) (vector r)) (field r 12) (field r 16),
      gate (field r 8) (sub (sub (field r 6) (field r 15)) (field r 16)),
      gate (field r 8) (sub (field r 7) (vector r))],
   readGates tokens r 4,
   [gate (field r 9) (sub (field r 5) (n 0xd2)),gate (field r 9) (field r 7),
    mulGate (field r 9) (field r 6) (field r 17)],
   readGates tokens r 5]
def gates (tokens : Tokens) (splits : Splits) (r : Record) := (parts tokens splits r).flatten
def layout (r : Record) (i : Nat) : Nat × Linear × Linear :=
  match i with
  | 0 => (0,field r 8,field r 10 ++ scale (vector r) (0xfd-0x302))
  | 1 => (1,vector r,scale (vector r) 12)
  | 2 => (7,mode r,field r 12)
  | 3 => (7,scale (vector r) 7,field r 14)
  | 4 => (0,field r 8,scale (field r 8) 11)
  | _ => (1,field r 9,field r 17)

def readShape (tokens : Tokens) (r : Record) (i kind : Nat) (active value : Linear) : Prop :=
  (readAt r i).token < tokens.length ∧
  (EnvelopeMatrix.token tokens (readAt r i).token).kind = kind ∧
  same (EnvelopeMatrix.token tokens (readAt r i).token).activeMode active ∧
  same (EnvelopeMatrix.token tokens (readAt r i).token).position (cursor r i) ∧
  same (EnvelopeMatrix.token tokens (readAt r i).token).value value
instance (tokens : Tokens) (r : Record) (i kind : Nat) (active value : Linear) : Decidable (readShape tokens r i kind active value) := by
  unfold readShape; infer_instance
def shape (tokens : Tokens) (splits : Splits) (r : Record) : Prop :=
  r.fields.length = 18 ∧ r.selectors.length = 8 ∧ r.zeroStarts.length = 8 ∧ r.reads.length = 6 ∧
  same (field r 9) (sub (field r 0) (field r 8)) ∧
  r.heads < splits.length ∧ splitMatches (split splits r.heads) (field r 12) 32 32 ∧
  readShape tokens r 0 0 (field r 8) (field r 10 ++ scale (vector r) (0xfd-0x302)) ∧
  readShape tokens r 1 1 (vector r) (scale (vector r) 12) ∧
  readShape tokens r 2 7 (mode r) (field r 12) ∧
  readShape tokens r 3 7 (scale (vector r) 7) (field r 14) ∧
  readShape tokens r 4 0 (field r 8) (scale (field r 8) 11) ∧
  readShape tokens r 5 1 (field r 9) (field r 17)
instance (tokens : Tokens) (splits : Splits) (r : Record) : Decidable (shape tokens splits r) := by
  unfold shape; infer_instance
def check (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : Record) : Bool :=
  decide (shape tokens splits r) && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (gates tokens splits r)
end ZkBuild.ConstantSourceMatrix
