# =============================================================================
# MM lifecycle and basic interface messages.
# =============================================================================
const
  MM_RESET_REQ*             = KE_FIRST_MSG(TASK_MM.uint16) + 0
  MM_RESET_CFM*             = KE_FIRST_MSG(TASK_MM.uint16) + 1
  MM_START_REQ*             = KE_FIRST_MSG(TASK_MM.uint16) + 2
  MM_START_CFM*             = KE_FIRST_MSG(TASK_MM.uint16) + 3
  MM_VERSION_REQ*           = KE_FIRST_MSG(TASK_MM.uint16) + 4
  MM_VERSION_CFM*           = KE_FIRST_MSG(TASK_MM.uint16) + 5
  MM_ADD_IF_REQ*            = KE_FIRST_MSG(TASK_MM.uint16) + 6
  MM_ADD_IF_CFM*            = KE_FIRST_MSG(TASK_MM.uint16) + 7
  MM_REMOVE_IF_REQ*         = KE_FIRST_MSG(TASK_MM.uint16) + 8
  MM_REMOVE_IF_CFM*         = KE_FIRST_MSG(TASK_MM.uint16) + 9
  MM_STA_ADD_REQ*           = KE_FIRST_MSG(TASK_MM.uint16) + 10
  MM_STA_ADD_CFM*           = KE_FIRST_MSG(TASK_MM.uint16) + 11
  MM_STA_DEL_REQ*           = KE_FIRST_MSG(TASK_MM.uint16) + 12
  MM_STA_DEL_CFM*           = KE_FIRST_MSG(TASK_MM.uint16) + 13
