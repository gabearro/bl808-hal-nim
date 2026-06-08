## WiFi firmware task and kernel message identifiers.
##
## These values mirror the BL60x/BL808 firmware API message space and are kept
## separate from the firmware implementation so command dispatch code can share
## them without depending on the full firmware body.

include fw_messages/tasks
include fw_messages/mm
include fw_messages/task_groups
