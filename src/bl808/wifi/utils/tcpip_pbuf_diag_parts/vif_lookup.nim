## Resolve RX station metadata back to a usable VIF.

proc rxVif(blHw: pointer; staIdx: uint32): pointer =
  if blHw == nil or staIdx >= NxRemoteStaStoreMax.uint32:
    return nil
  let sta = ptrAt(ptrAt(blHw, BlHwStaTableOff), uint(staIdx) * BlStaSize)
  let vifIdx = loadU8(sta, BlStaVifIdxOff).uint
  if vifIdx >= 2'u:
    return nil
  let vif = ptrAt(ptrAt(blHw, BlHwVifTableOff), vifIdx * BlVifSize)
  if loadU8(vif, BlVifUpOff) == 0'u8:
    return nil
  vif
