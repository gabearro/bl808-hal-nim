# =============================================================================
# Task IDs (from bl60x_fw_api.h)
# =============================================================================
const
  TASK_NONE* = 0xFF'u8
  TASK_MM*   = 0'u8
  TASK_SCAN* = 1'u8
  TASK_SCANU* = 2'u8
  TASK_ME*   = 3'u8
  TASK_SM*   = 4'u8
  TASK_APM*  = 5'u8
  TASK_BAM*  = 6'u8
  TASK_RXU*  = 7'u8
  TASK_CFG*  = 8'u8
  TASK_LAST_EMB* = TASK_CFG
  TASK_API*  = 9'u8
  TASK_MAX*  = 10'u8

template KE_FIRST_MSG*(task: uint16): uint16 = (task shl 10)
