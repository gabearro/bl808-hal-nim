/*
 * lwIP options for BL808 bare-metal CPS kernel.
 *
 * NO_SYS=1: polling mode, no OS threads, raw API only.
 * Sized for M0's 224KB RAM with ~50KB allocated to lwIP.
 */

#ifndef LWIPOPTS_H
#define LWIPOPTS_H

/* ---------- NO_SYS: bare-metal polling mode ---------- */
#define NO_SYS                      1
#define LWIP_TIMERS                 1
#define SYS_LIGHTWEIGHT_PROT        0   /* Single-core, no locking needed */
#define LWIP_TIMERS_CUSTOM          0

/* ---------- Memory ---------- */
#define MEM_ALIGNMENT               4
#define MEM_SIZE                    (24 * 1024)  /* 24KB lwIP heap */
#define MEM_LIBC_MALLOC             1   /* Use our TLSF malloc */
#define MEMP_MEM_MALLOC             1   /* Pool allocations via malloc too */

/* ---------- Packet buffers ---------- */
#define PBUF_POOL_SIZE              12
/*
 * The BL808 WiFi TX path reserves this encapsulation space for struct bl_txhdr
 * and alignment before handing a pbuf to the MAC. Keep this in sync with the
 * Bouffalo WiFi driver contract; PBUF_RAW_TX allocations depend on it.
 */
#define PBUF_LINK_ENCAPSULATION_HLEN 48
#define PBUF_POOL_BUFSIZE           1600  /* Ethernet MTU plus WiFi headroom */

/* ---------- Protocol control blocks ---------- */
#define MEMP_NUM_TCP_PCB            4
#define MEMP_NUM_TCP_PCB_LISTEN     2
#define MEMP_NUM_UDP_PCB            4
#define MEMP_NUM_PBUF               16
#define MEMP_NUM_NETBUF             4
#define MEMP_NUM_NETCONN            0   /* No netconn API */

/* ---------- IPv4 ---------- */
#define LWIP_IPV4                   1
#define LWIP_ARP                    1
#define LWIP_ETHERNET               1
#define LWIP_ICMP                   1

/* ---------- Transport ---------- */
#define LWIP_TCP                    1
#define TCP_MSS                     1460
#define TCP_WND                     (4 * TCP_MSS)
#define TCP_SND_BUF                 (4 * TCP_MSS)
#define TCP_SND_QUEUELEN            (4 * TCP_SND_BUF / TCP_MSS)
#define TCP_QUEUE_OOSEQ             0   /* Save memory: don't queue out-of-order */

#define LWIP_UDP                    1

/* ---------- DHCP ---------- */
#define LWIP_DHCP                   1

/* ---------- DNS ---------- */
#define LWIP_DNS                    1

/* ---------- Disabled features ---------- */
#define LWIP_IPV6                   0
#define LWIP_NETCONN                0
#define LWIP_SOCKET                 0
#define LWIP_IGMP                   0
#define LWIP_AUTOIP                 0
#define LWIP_SNMP                   0
#define LWIP_PPP                    0
#define LWIP_RAW                    1   /* Raw sockets for ping etc. */
#define LWIP_STATS                  0
#define LWIP_NETIF_HOSTNAME         1

/* ---------- Checksum ---------- */
#define CHECKSUM_GEN_IP             1
#define CHECKSUM_GEN_TCP            1
#define CHECKSUM_GEN_UDP            1
#define CHECKSUM_GEN_ICMP           1
#define CHECKSUM_CHECK_IP           1
#define CHECKSUM_CHECK_TCP          1
#define CHECKSUM_CHECK_UDP          1
#define CHECKSUM_CHECK_ICMP         1

/* ---------- Misc ---------- */
#define LWIP_NETIF_STATUS_CALLBACK  1
#define LWIP_NETIF_LINK_CALLBACK    1
#define LWIP_ERRNO_STDINCLUDE       0
#define LWIP_PROVIDE_ERRNO          1   /* lwIP provides its own errno */

/* ---------- Debug (disabled for production) ---------- */
#define LWIP_DEBUG                  0

#endif /* LWIPOPTS_H */
