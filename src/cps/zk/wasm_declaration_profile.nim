## Capacity limits for reusable declaration/source tables. Zero is an exact
## empty budget when enabled, not an instruction to infer a module's size.
type DeclarationProfile* = object
  enabled*: bool
  types*, functions*, parameters*, results*, tags*: int
  localGroups*, localRanges*: int

proc validate*(profile: DeclarationProfile) =
  if not profile.enabled: return
  for capacity in [profile.types,profile.functions,profile.parameters,profile.results,
      profile.tags,profile.localGroups,profile.localRanges]:
    if capacity < 0 or uint64(capacity) > uint64(high(uint32)):
      raise newException(ValueError,"invalid declaration profile capacity")
  let limit = min(uint64(high(int)),uint64(high(uint32)))
  if uint64(profile.parameters)+uint64(profile.results) > (limit-7) div 2 or
      uint64(profile.types) > (limit-8) div 4:
    raise newException(ValueError,"declaration profile derived capacity overflow")

proc padDeclarations*[T](values: var seq[T], capacity: int) =
  if capacity < 0 or values.len > capacity:
    raise newException(ValueError,"declaration profile capacity exceeded")
  values.setLen(capacity)

func nodeCapacity*(profile: DeclarationProfile): int = 2*(profile.parameters+profile.results)+7
func headCapacity*(profile: DeclarationProfile): int = 4*profile.types+8
func memberCapacity*(profile: DeclarationProfile): int = 2*(profile.parameters+profile.results)+7
