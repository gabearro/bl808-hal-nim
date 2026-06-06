/*
 * Minimal lwIP options for the BL808 M0 WiFi HTTP server example.
 *
 * This keeps the same NO_SYS/raw API model as the DHCP/ICMP smoke image but
 * enables the small TCP surface needed for a single-connection HTTP/1.1 server.
 */

#ifndef __LWIPOPTS_H__
#define __LWIPOPTS_H__

/* config.nims keeps the DHCP/ICMP smoke include directory in the global C
 * flags. Define its guard here so lwip/opt.h cannot re-include that profile
 * after this TCP-enabled profile has already been forced in.
 */
#define BL808_LWIP_WIFI_SMOKE_OPTS_H

#include <stdbool.h>

#define NO_SYS                         1
#define SYS_LIGHTWEIGHT_PROT           0
#define LWIP_TIMERS                    1
#define LWIP_TIMERS_CUSTOM             0

#define MEM_ALIGNMENT                  4
#define MEM_LIBC_MALLOC                1
#define MEMP_MEM_MALLOC                1
#define MEM_SIZE                       (12 * 1024)

#define PBUF_POOL_SIZE                 28
#define PBUF_LINK_ENCAPSULATION_HLEN   48
#define PBUF_POOL_BUFSIZE              1600

#define MEMP_NUM_PBUF                  28
#define MEMP_NUM_RAW_PCB               2
#define MEMP_NUM_UDP_PCB               4
#define MEMP_NUM_TCP_PCB               2
#define MEMP_NUM_TCP_PCB_LISTEN        1
#define MEMP_NUM_TCP_SEG               8
#define MEMP_NUM_SYS_TIMEOUT           LWIP_NUM_SYS_TIMEOUT_INTERNAL
#define MEMP_NUM_NETBUF                0
#define MEMP_NUM_NETCONN               0

#define LWIP_IPV4                      1
#define LWIP_IPV6                      0
#define LWIP_ARP                       1
#define LWIP_ETHERNET                  1
#define LWIP_ICMP                      1
#define LWIP_RAW                       1
#define LWIP_UDP                       1
#define LWIP_DHCP                      1

#define LWIP_TCP                       1
#define TCP_MSS                        1460
#define TCP_WND                        (2 * TCP_MSS)
#define TCP_SND_BUF                    (2 * TCP_MSS)
#define TCP_SND_QUEUELEN               (4 * TCP_SND_BUF / TCP_MSS)
#define LWIP_DNS                       0
#define LWIP_NETCONN                   0
#define LWIP_SOCKET                    0
#define LWIP_IGMP                      0
#define LWIP_AUTOIP                    0
#define LWIP_SNMP                      0
#define LWIP_PPP                       0
#define LWIP_MDNS_RESPONDER            0
#define LWIP_ALTCP                     0
#define LWIP_ALTCP_TLS                 0
#define LWIP_STATS                     0

#define LWIP_NETIF_API                 0
#define LWIP_NETIF_HOSTNAME            1
#define LWIP_NETIF_STATUS_CALLBACK     1
#define LWIP_NETIF_LINK_CALLBACK       1

#define IP_REASSEMBLY                  0
#define IP_FRAG                        0
#define ARP_QUEUEING                   0

#define CHECKSUM_GEN_IP                1
#define CHECKSUM_GEN_UDP               1
#define CHECKSUM_GEN_TCP               1
#define CHECKSUM_GEN_ICMP              1
#define CHECKSUM_CHECK_IP              1
#define CHECKSUM_CHECK_UDP             1
#define CHECKSUM_CHECK_TCP             1
#define CHECKSUM_CHECK_ICMP            1

#define LWIP_ERRNO_STDINCLUDE          0
#define LWIP_PROVIDE_ERRNO             1
#define LWIP_DEBUG                     0

#endif /* __LWIPOPTS_H__ */
