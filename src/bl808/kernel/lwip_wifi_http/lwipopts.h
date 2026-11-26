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

/* TIME_WAIT lifetime = 2*TCP_MSL. The default MSL (60000 ms) keeps a ~176-byte
 * tcp_pcb alive for 120 s after every Connection:close request. Because this
 * build uses MEMP_MEM_MALLOC=1, the MEMP_NUM_TCP_PCB pool cap is NOT enforced
 * (pcbs come from the shared TLSF heap, not a fixed pool), so TIME_WAIT pcbs
 * accumulate on the heap under request load faster than they expire and
 * eventually exhaust it (measured: ~208 pcbs, ~36 KB, wedge at ~430 s). On a
 * LAN embedded server a short MSL is safe and standard; 500 ms -> 1 s TIME_WAIT
 * so closed-connection pcbs are reclaimed promptly. */
#define TCP_MSL                        500
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

/* The window and send-buffer sizes below suit the single-connection HTTP
 * server. A TCP client (a stream, a download) can raise them without editing
 * this file: this header is force-included, so pass the value to the C
 * compiler, e.g. `--passC:-DTCP_WND=16384` (a plain number: Nim hands the
 * flag to a shell). init.c rejects inconsistent values at compile time; a
 * window above 65535 also needs LWIP_WND_SCALE and TCP_RCV_SCALE. Options
 * this file does not define (TCP_QUEUE_OOSEQ, DNS_TABLE_SIZE, ...) take the
 * same kind of -D. */
#ifndef TCP_WND
#define TCP_WND                        (2 * TCP_MSS)
#endif
#ifndef TCP_SND_BUF
#define TCP_SND_BUF                    (2 * TCP_MSS)
#endif
#ifndef TCP_SND_QUEUELEN
#define TCP_SND_QUEUELEN               (4 * TCP_SND_BUF / TCP_MSS)
#endif

/* lwIP's resolver is off unless the image is built with
 * -d:bl808WifiRealLwipDns: lwipcore.nim then passes -DLWIP_DNS=1 and compiles
 * dns.c, and DHCP hands the servers it is given to dns_setserver(). Use the
 * Nim define, not a bare -DLWIP_DNS=1, which would leave dns.c out. */
#ifndef LWIP_DNS
#define LWIP_DNS                       0
#endif
#if LWIP_DNS && !defined(DNS_RAND_TXID)
/* Query ids and source ports come from the TRNG only (lwipcore.nim): unlike
 * the DHCP transaction id, they must not be guessable, so there is no
 * time-and-address fallback. This profile has no LWIP_RAND. */
#ifndef __ASSEMBLER__
#include <stdint.h>
extern uint32_t bl808_lwip_dns_txid(void);
#endif
#define DNS_RAND_TXID()                bl808_lwip_dns_txid()
#endif
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
