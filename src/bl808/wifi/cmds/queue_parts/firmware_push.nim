proc pushCmdToFirmware(cmdMgr, cmd: pointer) =
  let blHw = cmdMgr
  let a2e = loadPtr(cmd, CmdA2eMsgOff)
  if a2e == nil:
    return
  let len = LmacMsgHeaderLen + loadU32(a2e, LmacMsgParamLenOff).uint16
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] push cmd=%p id=0x%x req=0x%x tkn=%u flags=0x%x len=%u env=%p\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU32(cmd, CmdTknOff).cuint, loadU16(cmd, CmdFlagsOff).cuint,
             len.cuint, loadPtr(blHw, BlHwIpcEnvOff))
  let rc = ipc_host_msg_push(loadPtr(blHw, BlHwIpcEnvOff), cmd, len)
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] push rc=%d cmd=%p\r\n", rc.cint, cmd)
  osFree(a2e)
