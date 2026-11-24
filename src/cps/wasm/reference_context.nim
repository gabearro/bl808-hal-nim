## Function indices declared outside function bodies. Imports, the start
## function and calls inside code do not themselves declare a reference.
import std/algorithm
import ./types

proc declaredFunctionReferences*(module: WasmModule): seq[uint32] =
  var references: seq[uint32]
  template scan(expr: Expr) =
    for instruction in expr.code:
      if instruction.op == opRefFunc: references.add instruction.imm1
  for global in module.globals: scan(global.init)
  for segment in module.elements:
    scan(segment.offset)
    for expr in segment.init: scan(expr)
  for item in module.exports:
    if item.kind == ekFunc: references.add item.idx
  references.sort()
  for index in references:
    if result.len == 0 or result[^1] != index: result.add index

func hasDeclaredReference*(references: openArray[uint32], index: uint32): bool =
  binarySearch(references, index) >= 0
