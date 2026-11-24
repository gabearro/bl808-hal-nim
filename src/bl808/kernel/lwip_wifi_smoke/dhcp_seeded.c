#include <stdint.h>
#include "lwip/sys.h"

/* Only the DHCP translation unit uses this seed. Keep the SDK's sequential
 * allocation for new transactions and its reuse rules for retransmissions. */
extern uint32_t bl808_lwip_dhcp_xid_seed(void);
extern uint16_t bl808_lwip_dhcp_retry_ms(uint32_t xid, uint32_t now_ms,
                                       uint8_t tries, uint8_t state);
#define DHCP_CREATE_RAND_XID 0
#define DHCP_GLOBAL_XID bl808_lwip_dhcp_xid_seed()
#define BL808_LWIP_DHCP_RETRY_MS(client) \
  bl808_lwip_dhcp_retry_ms((client)->xid, sys_now(), (client)->tries, (client)->state)
#include "../../../../build/bl_iot_sdk_b773b3f/components/network/lwip/src/core/ipv4/dhcp.c"

#ifndef BL808_LWIP_DHCP_POLICY_PRESENT
#error "Apply tools/bl808_lwip_dhcp_policy.patch to the pinned BL808 SDK"
#endif
