# MM power-save messages.
const
  MM_SET_PS_MODE_REQ*       = KE_FIRST_MSG(TASK_MM.uint16) + 31
  MM_SET_PS_OFF_INTERNAL_REQ* = KE_FIRST_MSG(TASK_MM.uint16) + 32
  MM_SET_PS_MODE_CFM*       = KE_FIRST_MSG(TASK_MM.uint16) + 33
  MM_PS_CHANGE_IND*         = KE_FIRST_MSG(TASK_MM.uint16) + 56
  # The BL808 vendor blob uses 0x39 for MM_SET_PS_OPTIONS_REQ and 0x3A
  # for its confirmation. Some upstream headers label 0x39 differently,
  # but mm_task.o dispatches 0x39 to mm_set_ps_options_req_handler and
  # that handler sends basic msg 0x3A.
  MM_SET_PS_OPTIONS_REQ*    = KE_FIRST_MSG(TASK_MM.uint16) + 57
  MM_SET_PS_OPTIONS_CFM*    = KE_FIRST_MSG(TASK_MM.uint16) + 58
  MM_P2P_VIF_PS_CHANGE_IND* = KE_FIRST_MSG(TASK_MM.uint16) + 59
  MM_TRAFFIC_REQ_IND*       = MM_SET_PS_OPTIONS_REQ
