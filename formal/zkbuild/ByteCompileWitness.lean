import ByteCompileCompleteness

/- Executable indexed construction of the combined witness. Component and
   row caches preserve the canonical layout without mutable assembly loops. -/
namespace ZkBuild.ByteCompileWitness

open Lean.Grind CircuitShape FullMatrix ByteCompileSoundness
attribute [local instance] Ring.intCast Semiring.natCast

structure Cache where
  bytes : Array Int
  slots : Array Int
  rows : Array (Array Int)

def prepare (wasm : List (Fin 256)) (ops : List Op) : Cache := Id.run do
  let bytes := Array.ofFn fun i : Fin 6096 => ByteCompileSourceWitness.source (F := Int) wasm i.val
  let actions := SlotCheckedTrace.actionsFor ops
  let heights := SlotCheckedTrace.heightsFor ops
  let slotRows := SlotWitness.rowCache actions heights
  let slotInputs := SlotModuleCompleteness.cachedPublicValues (F := Int) slotRows
  let slots := Array.ofFn fun i : Fin 11899 => SlotWitness.cachedValues slotInputs slotRows i.val
  let rows := Array.ofFn fun i : Fin 121 =>
    let cfg := ByteCompileSourceWitness.cfgAt wasm i.val
    let byte := ByteCompileSourceWitness.byteAt wasm i
    Array.ofFn fun j : Fin 27 => ByteCompileCanonicalRow.values cfg byte (40+j.val)
  return ⟨bytes, slots, rows⟩

def base (cache : Cache) : Nat → Int :=
  ByteCompileMerge.values (fun i => cache.bytes[i]?.getD 0) (fun i => cache.slots[i]?.getD 0) (fun _ => 0)

def bodyValues (cache : Cache) (wire : Nat) : Int :=
  if wire < 17994 then base cache wire
  else if wire < 21261 then
    (((cache.rows[(wire-17994)/27]?).getD #[])[(wire-17994)%27]?).getD 0
  else 0

def valueAt (cache : Cache) (wire : Nat) : Int :=
  if wire < 21261 then bodyValues cache wire
  else if bound : wire < 21277 then
    let i : Fin 16 := ⟨wire-21261, by omega⟩
    evalLinear (bodyValues cache) (ByteCompileSlotBinding.booleanLinear i 3) *
      evalLinear (bodyValues cache) (ByteCompileSlotBinding.valueLinear i)
  else 0

def construct (wasm : List (Fin 256)) : Option (Array Int) := do
  let final ← decodeBinary wasm
  let cache := prepare wasm (paddedProgram final.operations)
  return Array.ofFn fun i : Fin 21277 => valueAt cache i.val

end ZkBuild.ByteCompileWitness
