import SlotBytes
import SlotProgram

/- Relate a compilation row's eight byte expressions to the actual two RV32
   instructions. The nonconstant cases are finite; constant fields are proved
   for every 32-bit value, including the signed ADDI rounding carry. -/
namespace ZkBuild.SlotNative

open Lean.Grind RowSoundness Rv32Encoding
attribute [local instance] Ring.intCast Semiring.natCast

def operation (kind : Fin 10) (value : Word) : Op :=
  SlotProgram.withImmediate (SlotProgram.operationKind kind) value

def encodedOperation (height : Nat) (op : Op) : List (BitVec 8) :=
  (Rv32Compiler.emitOperation height op).flatMap (fun instruction => wordBytes (encode instruction))

def luiByte (destination : Register) (i : Nat) : BitVec 8 :=
  (encode (.lui destination (0#20))).extractLsb' (8*i) 8

def addiByte (destination : Register) (i : Nat) : BitVec 8 :=
  (encode (.addi destination destination (0#12))).extractLsb' (8*i) 8

theorem constant_byte_fields (destination : Register) (upper : BitVec 20) (value : Word) :
    wordBytes (encode (.lui destination upper)) ++
      wordBytes (encode (.addi destination destination (value.extractLsb' 0 12))) =
    [luiByte destination 0,
     luiByte destination 1 + ((upper.extractLsb' 0 4).setWidth 8 <<< 4),
     upper.extractLsb' 4 8, upper.extractLsb' 12 8,
     addiByte destination 0, addiByte destination 1,
     addiByte destination 2 + ((value.extractLsb' 0 4).setWidth 8 <<< 4),
     value.extractLsb' 4 8] := by
  unfold wordBytes luiByte addiByte encode
  simp only [List.cons_append, List.nil_append, List.cons.injEq, and_true]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> bv_decide

theorem base_byte_nibbles (destination : Register) :
    (luiByte destination 1).toNat < 16 ∧ (addiByte destination 2).toNat < 16 := by
  have lui : luiByte destination 1 = (destination.extractLsb' 1 4).setWidth 8 := by
    unfold luiByte encode
    bv_decide
  have addi : addiByte destination 2 = (destination.extractLsb' 1 4).setWidth 8 := by
    unfold addiByte encode
    bv_decide
  rw [lui, addi, BitVec.toNat_setWidth_of_le (by decide)]
  exact ⟨(destination.extractLsb' 1 4).isLt, (destination.extractLsb' 1 4).isLt⟩

theorem join_nibbles (low : BitVec 8) (high : BitVec 4) (bound : low.toNat < 16) :
    (low + (high.setWidth 8 <<< 4)).toNat = low.toNat + high.toNat*16 := by
  rw [BitVec.toNat_add, BitVec.toNat_shiftLeft, BitVec.toNat_setWidth_of_le (by decide), Nat.shiftLeft_eq]
  have highBound := high.isLt
  change (low.toNat + (high.toNat*16)%256)%256 = low.toNat + high.toNat*16
  omega

def constantFields (height : Nat) (value : Word) : List Nat :=
  let destination := Rv32Compiler.stackReg height
  let upper := Rv32Compiler.upperImmediate value
  [ (luiByte destination 0).toNat,
    (luiByte destination 1).toNat + (upper.extractLsb' 0 4).toNat*16,
    (upper.extractLsb' 4 8).toNat, (upper.extractLsb' 12 8).toNat,
    (addiByte destination 0).toNat, (addiByte destination 1).toNat,
    (addiByte destination 2).toNat + (value.extractLsb' 0 4).toNat*16,
    (value.extractLsb' 4 8).toNat ]

theorem constant_encoding (height : Nat) (value : Word) :
    (encodedOperation height (.const value)).map BitVec.toNat = constantFields height value := by
  unfold encodedOperation Rv32Compiler.emitOperation Rv32Compiler.lowerImmediate
  simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil]
  rw [constant_byte_fields]
  simp only [List.map_cons, List.map_nil,
    join_nibbles _ _ (base_byte_nibbles _).1, join_nibbles _ _ (base_byte_nibbles _).2]
  rfl

def literal (value : Nat) : Expr := .literal (Int.ofNat value)

def constantTemplate (height : Nat) : List Expr :=
  let destination := Rv32Compiler.stackReg height
  [ literal (luiByte destination 0).toNat,
    literal (luiByte destination 1).toNat + SlotRow.packed SlotRow.upperBit 0 4 * 16,
    SlotRow.packed SlotRow.upperBit 4 8, SlotRow.packed SlotRow.upperBit 12 8,
    literal (addiByte destination 0).toNat, literal (addiByte destination 1).toNat,
    literal (addiByte destination 2).toNat + SlotRow.packed SlotRow.valueBit 0 4 * 16,
    SlotRow.packed SlotRow.valueBit 4 8 ]

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem constant_template_certificate : ∀ height : Fin 8,
    RowMatrix.polynomialListEqual (SlotRow.words 3 height.val).toList (constantTemplate height.val) = true := by
  native_decide

theorem eval_literal {F : Type} [CommRing F] (values : Nat → F) (value : Nat) :
    evalField values (literal value) = (value : F) := Ring.intCast_natCast value

theorem eval_add {F : Type} [CommRing F] (values : Nat → F) (a b : Expr) :
    evalField values (a+b) = evalField values a + evalField values b := rfl

theorem eval_mul {F : Type} [CommRing F] (values : Nat → F) (a b : Expr) :
    evalField values (a*b) = evalField values a * evalField values b := rfl

theorem constant_template_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values) (height : Nat) :
    (constantTemplate height).map (evalField values) =
      (constantFields height (SlotImmediate.immediate values)).map (fun value : Nat => (value : F)) := by
  have upper0 := SlotImmediate.upper_slice_field values holds 0 4 (by decide)
  have upper4 := SlotImmediate.upper_slice_field values holds 4 8 (by decide)
  have upper12 := SlotImmediate.upper_slice_field values holds 12 8 (by decide)
  have lower0 := SlotImmediate.immediate_slice_field values holds 0 4 (by decide)
  have lower4 := SlotImmediate.immediate_slice_field values holds 4 8 (by decide)
  have sixteen : (16 : Expr) = literal 16 := rfl
  simp only [constantTemplate, constantFields, List.map_cons, List.map_nil, eval_add, eval_mul,
    sixteen, eval_literal, upper0, upper4, upper12, lower0, lower4,
    Semiring.natCast_add, Semiring.natCast_mul]

theorem constant_words {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (holds : SlotRow.FieldHolds ctx.get) (height : Fin 8) :
    (SlotRow.words 3 height.val).toList.map (evalField ctx.get) =
      (encodedOperation height.val (.const (SlotImmediate.immediate ctx.get))).map
        (fun byte => (byte.toNat : F)) := by
  have template := RowMatrix.polynomial_list_sound ctx _ _ (constant_template_certificate height)
  rw [template, constant_template_values ctx.get holds height.val, ← constant_encoding]
  simp only [List.map_map, Function.comp_def]

def literalBytes (bytes : List (BitVec 8)) : List Expr := bytes.map (fun byte => literal byte.toNat)

theorem other_operation (kind : Fin 10) (other : kind.val ≠ 3) (value : Word) :
    operation kind value = operation kind (0#32) := by
  unfold operation SlotProgram.operationKind
  split <;> simp_all [SlotProgram.withImmediate]

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem other_template_certificate : ∀ (kind : Fin 10) (height : Fin 9),
    kind.val ≠ 3 → SlotShape.valid kind.val height.val = true →
    RowMatrix.polynomialListEqual (SlotRow.words kind.val height.val).toList
      (literalBytes (encodedOperation height.val (operation kind (0#32)))) = true := by
  native_decide

theorem words_encode_operation {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (holds : SlotRow.FieldHolds ctx.get) (kind : Fin 10) (height : Fin 9)
    (valid : SlotShape.valid kind.val height.val = true) :
    (SlotRow.words kind.val height.val).toList.map (evalField ctx.get) =
      (encodedOperation height.val (operation kind (SlotImmediate.immediate ctx.get))).map
        (fun byte => (byte.toNat : F)) := by
  by_cases constant : kind.val = 3
  · have heightBound : height.val < 8 := by
      have notEight : height.val ≠ 8 := by
        simpa [constant, SlotShape.valid, SlotShape.pushes, SlotShape.binary] using valid
      have bound := height.isLt
      omega
    have result := constant_words ctx holds ⟨height.val, heightBound⟩
    have sameKind : kind = (⟨3, by decide⟩ : Fin 10) := Fin.ext constant
    simpa only [sameKind, operation, SlotProgram.operationKind, SlotProgram.withImmediate] using result
  · have result := RowMatrix.polynomial_list_sound ctx _ _ (other_template_certificate kind height constant valid)
    rw [result, other_operation kind constant (SlotImmediate.immediate ctx.get)]
    simp only [literalBytes, List.map_map, Function.comp_def, eval_literal]

theorem native_row_bytes {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (holds : SlotRow.FieldHolds ctx.get) (kind : Fin 10) (height : Fin 9)
    (prior : ∀ i, i < 9 → ctx.get i = if i = height.val then 1 else 0)
    (selected : ∀ i, i < 10 → ctx.get (9+i) = if i = kind.val then 1 else 0)
    (valid : SlotShape.valid kind.val height.val = true) :
    SlotRow.nativeBytes.map (evalField ctx.get) =
      (encodedOperation height.val (operation kind (SlotImmediate.immediate ctx.get))).map
        (fun byte => (byte.toNat : F)) := by
  rw [SlotBytes.native_selected ctx kind height prior selected valid]
  exact words_encode_operation ctx holds kind height valid

#print axioms constant_encoding
#print axioms constant_words
#print axioms native_row_bytes

end ZkBuild.SlotNative
