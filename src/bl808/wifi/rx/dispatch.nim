proc rxHandlerFor(id: uint16): MsgCbProc =
  let task = msgTask(id)
  let index = msgIndex(id)
  case task
  of TaskMM:
    case index
    of MmChannelSwitchI: blRxChanSwitchInd
    of MmChannelPreSwitchI, MmRemainOnChannelExpI, MmPsChangeI,
       MmTrafficReqI, MmChannelSurveyI: blCommonInd
    of MmRssiStatusI: blRxRssiStatusInd
    else: nil
  of TaskScanu:
    case index
    of ScanuStartCfmI: blRxScanuStartCfm
    of ScanuJoinCfmI: blRxScanuJoinCfm
    of ScanuResultI: blRxScanuResultInd
    else: nil
  of TaskMe:
    case index
    of MeTkipMicFailureI, MeTxCreditsUpdateI: blCommonInd
    else: nil
  of TaskSm:
    case index
    of SmConnectI: blRxSmConnectInd
    of SmDisconnectI: blRxSmDisconnectInd
    of SmStaAddI: blRxSmStaAddInd
    else: nil
  of TaskApm:
    case index
    of ApmStaAddI: blRxApmStaAddInd
    of ApmStaDelI: blRxApmStaDelInd
    else: nil
  of TaskCfg:
    nil
  else:
    nil

proc dispatchMsg(blHw, msg: pointer) =
  let cmdMgr = ptrAt(blHw, BlHwCmdMgrOff)
  let msgind = cast[CmdMsgindProc](loadPtr(cmdMgr, CmdMgrMsgindOff))
  if msgind != nil:
    let cb = rxHandlerFor(loadU16(msg, IpcMsgIdOff))
    discard msgind(cmdMgr, msg, cb)

proc bl_rx_handle_msg*(blHw: ptr BlHw; msg: pointer) {.exportc, cdecl.} =
  dispatchMsg(cast[pointer](blHw), msg)

proc bl_rx_e2a_handler*(arg: pointer) {.exportc, cdecl.} =
  dispatchMsg(hwRaw(), arg)
