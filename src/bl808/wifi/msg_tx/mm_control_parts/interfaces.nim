proc bl_send_add_if*(blHw: ptr BlHw; mac: ptr uint8; iftype: cint; p2p: bool;
                     cfm: ptr MmAddIfCfmObj): cint {.exportc, cdecl.} =
  if iftype == NL80211_IFTYPE_AP_VLAN:
    return -1
  let req = blMsgZalloc(MM_ADD_IF_REQ, TASK_MM, DRV_TASK_ID, SizeMmAddIfReq)
  if req == nil: return -Enomem
  copyMem(ptrAt(req, MmAddIfAddrOff), mac, 6)
  case iftype
  of NL80211_IFTYPE_STATION:
    storeU8(req, MmAddIfTypeOff, MM_STA)
  of NL80211_IFTYPE_ADHOC:
    storeU8(req, MmAddIfTypeOff, MM_IBSS)
  of NL80211_IFTYPE_AP:
    storeU8(req, MmAddIfTypeOff, MM_AP)
  of NL80211_IFTYPE_MESH_POINT:
    storeU8(req, MmAddIfTypeOff, MM_MESH_POINT)
  else:
    storeU8(req, MmAddIfTypeOff, MM_STA)
  if p2p:
    storeU8(req, MmAddIfP2pOff, 1)
  blSendMsg(blHw, req, 1, MM_ADD_IF_CFM, cfm)

proc bl_send_remove_if*(blHw: ptr BlHw; instNbr: uint8): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(MM_REMOVE_IF_REQ, TASK_MM, DRV_TASK_ID, SizeMmRemoveIfReq)
  if req == nil: return -Enomem
  storeU8(req, MmRemoveIfInstOff, instNbr)
  blSendMsg(blHw, req, 1, MM_REMOVE_IF_CFM, nil)
