proc cmdMgrMsgind(cmdMgr, msg, cbPtr: pointer): cint {.cdecl.} =
  let cb = cast[MsgCbProc](cbPtr)
  let blHw = cmdMgr
  var found = false
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] msg enter msg=%p id=0x%x len=%u cb=%p\r\n",
             msg, loadU16(msg, IpcE2aMsgIdOff).cuint,
             loadU32(msg, IpcE2aMsgParamLenOff).cuint, cbPtr)

  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var cmd = listNext(head)
  while cmd != head:
    if loadU16(cmd, CmdReqidOff) == loadU16(msg, IpcE2aMsgIdOff) and
        (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagWaitCfm) != 0'u16:
      if cb == nil or cb(blHw, cmd, msg) == 0:
        found = true
        when defined(bl808WifiCmdTrace):
          c_printf("[WIFI-CMD] msg found cmd=%p msgid=0x%x flags=0x%x\r\n",
                   cmd, loadU16(msg, IpcE2aMsgIdOff).cuint,
                   loadU16(cmd, CmdFlagsOff).cuint)
        let flags = loadU16(cmd, CmdFlagsOff) and not RwnxCmdFlagWaitCfm
        storeU16(cmd, CmdFlagsOff, flags)
        let e2a = loadPtr(cmd, CmdE2aMsgOff)
        let paramLen = loadU32(msg, IpcE2aMsgParamLenOff)
        if e2a != nil and paramLen != 0'u32:
          discard c_memcpy(e2a, ptrAt(msg, IpcE2aMsgParamOff), paramLen.csize_t)
        if waitComplete(flags):
          cmdComplete(cmdMgr, cmd)
        break
    cmd = listNext(cmd)
  cmdMgrUnlock(cmdMgr)

  if not found and cb != nil:
    discard cb(blHw, nil, msg)
  0
