## Hardware, MAC management, and firmware task state identifiers.

const
  HW_IDLE*     = 0'u8
  HW_RESERVED* = 1'u8
  HW_DOZE*     = 2'u8
  HW_ACTIVE*   = 3'u8

  MM_IDLE*          = 0'u8
  MM_ACTIVE_STATE*  = 1'u8
  MM_GOING_TO_IDLE* = 2'u8
  MM_HOST_BYPASSED* = 3'u8

  # WiFi firmware task states. These values match the blob task tables and
  # state-specific handlers used by ke_task_init.
  TaskIdleState* = 0'u16
  TaskActiveState* = 1'u16
  TaskGoingIdleState* = 2'u16
  ScanIdleState* = 0'u16
  ScanActiveState* = 1'u16
  ScanChannelPendingState* = 2'u16
  ScanChannelRunningState* = 3'u16
  ScanuIdleState* = 0'u16
  ScanuScanningState* = 1'u16
  ScanuJoiningState* = 2'u16
  MeIdleState* = 0'u16
  MeBusyState* = 1'u16
  MeGoingIdleState* = 2'u16
  SmIdleState* = 0'u16
  SmScanningState* = 1'u16
  SmWaitingState* = 2'u16
  SmAddingChanState* = 3'u16
  SmSettingBssState* = 4'u16
  SmAuthStartingState* = 5'u16
  SmAuthenticatingState* = 6'u16
  SmAssociatingState* = 7'u16
  SmAssocRspState* = 8'u16
  SM_ACTIVATING_STATE* = 9'u16
  SmDisconnectingState* = 10'u16
  ApmIdleState* = 0'u16
  ApmActiveState* = 1'u16
  ApmStartingState* = 2'u16
  BamIdleState* = 0'u16

  VIF_TYPE_STA* = 0'u8
  VIF_TYPE_IBSS* = 1'u8
  VIF_TYPE_AP*  = 2'u8
  VIF_TYPE_MESH_POINT* = 3'u8
  VIF_TYPE_FREE* = 4'u8
