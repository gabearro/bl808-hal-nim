import ShaScalar

namespace ZkBuild.ShaHash

open CircuitShape GadgetShape ShaProgram

abbrev ByteWires := Fin 8 → Linear

structure PaddedByte where
  active : Linear
  value : Linear
  bits : ByteWires

structure HashState where
  words : State ShaWordMatrix.Word
  selected : List Linear
  active : Linear
  ends : Linear

structure LengthContext where
  bits : Fin 32 → Linear
  last : Linear

def inputByte (source : List Linear) (position : Nat) : Linear := source.getD position (constant 0)

def boundaryM (capacity : Nat) (length : Linear) (position : Nat) : Build Linear :=
  if position ≤ capacity then ShaScalar.zero (sub length (constant (Int.ofNat position)))
  else pure (constant 0)

def padByteM (source : List Linear) (length : Linear) (lengthBits : Fin 32 → Linear)
    (last active : Linear) (blockIndex : Nat) (offset : Fin 64) : Build PaddedByte := do
  let position := blockIndex*64+offset.val
  let boundary ← boundaryM source.length length position
  let next ← ShaScalar.materialize (sub active boundary)
  let value := inputByte source position
  let _ ← ShaScalar.constrain (sub (constant 1) next) value (constant 0)
  let lengthByte := ShaBoundary.lengthWiring lengthBits offset
  let extra ← ShaScalar.multiply last lengthByte
  let padded ← ShaScalar.materialize (value ++ scale boundary 128 ++ extra)
  let bits ← ShaScalar.range 8 padded
  return ⟨next,padded,bits⟩

def padBlockM (source : List Linear) (length : Linear) (lengthBits : Fin 32 → Linear)
    (last active : Linear) (blockIndex : Nat) (offsets : List (Fin 64)) : Build (Linear × List ByteWires) :=
  match offsets with
  | [] => pure (active,[])
  | offset::rest => do
    let byte ← padByteM source length lengthBits last active blockIndex offset
    let next ← padBlockM source length lengthBits last byte.active blockIndex rest
    return (next.1,byte.bits::next.2)

def byteHeads (bytes : List ByteWires) : List ShaWordMatrix.Word :=
  (List.range 16).map fun i =>
    ⟨ShaBoundary.wordBits (fun b => bytes.getD (i*4+b.val) (fun _ => constant 0)),[]⟩

def stateOfList (words : List ShaWordMatrix.Word) : State ShaWordMatrix.Word :=
  ⟨words.getD 0 zeroWord,words.getD 1 zeroWord,words.getD 2 zeroWord,words.getD 3 zeroWord,
   words.getD 4 zeroWord,words.getD 5 zeroWord,words.getD 6 zeroWord,words.getD 7 zeroWord⟩

def selectM (selector : Linear) (previous : List Linear) (words : List ShaWordMatrix.Word) : Build (List Linear) :=
  match previous,words with
  | head::tail,w::rest => do
    let chosen ← ShaScalar.multiply selector w.value
    let next ← selectM selector tail rest
    return (head++chosen)::next
  | _,_ => pure []

def blockM (source : List Linear) (length : Linear) (lengthBits : Fin 32 → Linear)
    (finalBlock : Linear) (state : HashState) (index : Nat) : Build HashState := do
  let last ← ShaScalar.zero (sub finalBlock (constant (Int.ofNat index)))
  let padded ← padBlockM source length lengthBits last state.active index (List.ofFn (fun i : Fin 64 => i))
  let words ← compressM state.words (byteHeads padded.2)
  let selected ← selectM last state.selected words
  return ⟨stateOfList words,selected,padded.1,state.ends++last⟩

def blocksM (source : List Linear) (length : Linear) (lengthBits : Fin 32 → Linear)
    (finalBlock : Linear) (indices : List Nat) (state : HashState) : Build HashState :=
  match indices with
  | [] => pure state
  | index::rest => do
    let next ← blockM source length lengthBits finalBlock state index
    blocksM source length lengthBits finalBlock rest next

def initialState : State ShaWordMatrix.Word := stateOfList (Sha256.initial.map roundKey)

def prepareBitsM (capacity : Nat) (length : Linear) (bits : Fin 32 → Linear) : Build LengthContext := do
  let _ ← ShaScalar.range 32 (sub (constant (Int.ofNat capacity)) length)
  let a ← ShaScalar.multiply (bits 3) (bits 4)
  let b ← ShaScalar.multiply a (bits 5)
  let finalBlock ← ShaScalar.materialize (ShaBoundary.packLinear (fun i : Fin 26 => bits ⟨i.val+6,by omega⟩) ++ b)
  return ⟨bits,finalBlock⟩

def prepareM (capacity : Nat) (length : Linear) : Build LengthContext := do
  let bits ← ShaScalar.range 32 length
  prepareBitsM capacity length bits

def finishM (source : List Linear) (length : Linear) (digest : Fin 2 → Linear)
    (context : LengthContext) : Build HashState := do
  let state ← blocksM source length context.bits context.last (List.range (Sha256.blockCount source.length))
    ⟨initialState,List.replicate 8 (constant 0),constant 1,constant 0⟩
  let _ ← ShaScalar.equal state.active (constant 0)
  let _ ← ShaScalar.equal state.ends (constant 1)
  let _ ← ShaScalar.equal (digest 0) (ShaBoundary.limb (fun i => state.selected.getD i.val (constant 0)))
  let _ ← ShaScalar.equal (digest 1) (ShaBoundary.limb (fun i => state.selected.getD (i.val+4) (constant 0)))
  return state

def hashM (source : List Linear) (length : Linear) (digest : Fin 2 → Linear) : Build HashState := do
  let context ← prepareM source.length length
  finishM source length digest context

def cachedM (source : List Linear) (length : Linear) (bits : Fin 32 → Linear)
    (digest : Fin 2 → Linear) : Build HashState := do
  let context ← prepareBitsM source.length length bits
  finishM source length digest context

def program (capacity : Nat) : Step HashState :=
  hashM ((List.range capacity).map (fun i => wire (i+4))) (wire 3) (fun i => wire (i.val+1)) (capacity+4)

def artifact (capacity : Nat) : Artifact :=
  ⟨{ wires := (program capacity).next,publicCount := 2,gates := (program capacity).gates.toArray },[wire 1,wire 2]⟩

theorem checked_relation {F : Type} [Lean.Grind.CommRing F] [Lean.Grind.IsCharP F scalarModulus]
    (actual : Artifact) (capacity : Nat) (checked : conforms actual (artifact capacity) = true)
    (values : Nat → F) (satisfied : CircuitShape.Satisfied actual.shape values) :
    AllHold values (program capacity).gates ∧ actual.outputs.map (E values) = [values 1,values 2] := by
  have relation := conformance_relation actual (artifact capacity) checked values
  refine ⟨?_,?_⟩
  · simpa [artifact,CircuitShape.Satisfied,AllHold,Holds] using relation.1.mp satisfied
  · simpa [artifact] using relation.2

namespace Soundness

open Lean.Grind FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def boundaryValue {F : Type} [CommRing F] [DecidableEq F]
    (values : Nat → F) (source : List Linear) (length : Linear) (position : Nat) : F :=
  if position ≤ source.length then
    if E values (sub length (constant (Int.ofNat position))) = 0 then 1 else 0
  else 0

theorem padByte_algebra {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (lengthBits : Fin 32 → Linear) (last active : Linear) (blockIndex : Nat) (offset : Fin 64) :
    Ensures values (padByteM source length lengthBits last active blockIndex offset) (fun output =>
      let boundary := boundaryValue values source length (blockIndex*64+offset.val)
      E values output.active = E values active-boundary ∧
      (1-E values output.active)*E values (inputByte source (blockIndex*64+offset.val)) = 0 ∧
      E values output.value = E values (inputByte source (blockIndex*64+offset.val)) +
        128*boundary + E values last*E values (ShaBoundary.lengthWiring lengthBits offset) ∧
      RangeReuse.Certificate 8 (E values output.value) ((List.ofFn output.bits).map (E values))) := by
  let position := blockIndex*64+offset.val
  have boundary : Ensures values (boundaryM source.length length position)
      (fun out => E values out = boundaryValue values source length position) := by
    by_cases inside : position ≤ source.length
    · simpa [boundaryM,boundaryValue,inside] using ShaScalar.zero_sound values one (sub length (constant (Int.ofNat position)))
    · simp only [boundaryM,ite_eq_right inside]
      apply pure_sound
      simp [boundaryValue,inside,eval_constant values one,Ring.intCast_zero]
  unfold padByteM
  apply bind_sound values _ _ _ _ boundary
  intro marker hmarker
  apply bind_sound values _ _ _ _ (ShaScalar.materialize_sound values one (sub active marker))
  intro next hnext
  apply bind_sound values _ _ _ _ (ShaScalar.constrain_sound values (sub (constant 1) next) (inputByte source position) (constant 0))
  intro ignored hinactive
  apply bind_sound values _ _ _ _ (ShaScalar.multiply_sound values last (ShaBoundary.lengthWiring lengthBits offset))
  intro extra hextra
  apply bind_sound values _ _ _ _ (ShaScalar.materialize_sound values one (inputByte source position ++ scale marker 128 ++ extra))
  intro padded hpadded
  apply bind_sound values _ _ _ _ (ShaScalar.range_certificate_sound values one padded 8)
  intro bits certificate
  apply pure_sound
  refine ⟨?_,?_,?_,certificate⟩
  · simpa [eval_sub,hmarker,position] using hnext
  · simpa [eval_sub,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] using hinactive
  · have packed : E values (inputByte source position ++ scale marker 128 ++ extra) =
        E values (inputByte source position)+128*E values marker+E values extra := by
      simp only [E,FullMatrix.eval_append,FullMatrix.eval_scale]
      grind
    have algebra := hpadded.trans (by simpa only [List.append_assoc] using packed)
    simpa only [hmarker,hextra,position] using algebra

end Soundness

#print axioms Soundness.padByte_algebra

end ZkBuild.ShaHash
