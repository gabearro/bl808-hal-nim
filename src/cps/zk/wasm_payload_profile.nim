## Fixed budgets for all non-code payloads. Globals/tables/memories include
## imports; elementItems and nameBytes are module-wide, not per-parent maxima.
import wasm_declaration_profile
export wasm_declaration_profile

type PayloadProfile* = object
  enabled*: bool
  imports*, globals*, tables*, memories*, exports*, elements*, datas*: int
  elementItems*, customSections*, nameBytes*: int

proc validate*(p: PayloadProfile) =
  if not p.enabled: return
  let limit = min(uint64(high(int)), uint64(high(uint32)))
  for n in [p.imports,p.globals,p.tables,p.memories,p.exports,p.elements,
      p.datas,p.elementItems,p.customSections,p.nameBytes]:
    if n < 0 or uint64(n) > limit:
      raise newException(ValueError,"invalid payload profile capacity")
  if uint64(p.exports)+2*uint64(p.imports)+uint64(p.customSections) > limit or
      uint64(p.globals)+uint64(p.tables) > limit:
    raise newException(ValueError,"payload profile derived capacity overflow")

func nameCapacity*(p: PayloadProfile): int = p.exports+2*p.imports+p.customSections
