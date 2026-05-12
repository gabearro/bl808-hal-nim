/*
 * lwIP architecture-specific definitions for BL808 bare-metal.
 */
#ifndef LWIP_ARCH_CC_H
#define LWIP_ARCH_CC_H

#include <stdint.h>
#include <stddef.h>

/* Type definitions matching lwIP expectations */
typedef uint8_t   u8_t;
typedef int8_t    s8_t;
typedef uint16_t  u16_t;
typedef int16_t   s16_t;
typedef uint32_t  u32_t;
typedef int32_t   s32_t;
typedef uintptr_t mem_ptr_t;

/* Byte order: RISC-V is little-endian */
#ifndef BYTE_ORDER
#define BYTE_ORDER LITTLE_ENDIAN
#endif

/* Diagnostic output (disabled — no printf on bare metal) */
#define LWIP_PLATFORM_DIAG(x)   do { } while(0)
#define LWIP_PLATFORM_ASSERT(x) do { } while(0)

/* Structure packing */
#define PACK_STRUCT_FIELD(x)    x
#define PACK_STRUCT_STRUCT      __attribute__((packed))
#define PACK_STRUCT_BEGIN
#define PACK_STRUCT_END

/* Byte swap — inline for compile-time constant folding */
#define lwip_htons(x) ((u16_t)((((x) & 0xFF) << 8) | (((x) >> 8) & 0xFF)))
#define lwip_ntohs(x) lwip_htons(x)
#define lwip_htonl(x) ((u32_t)( \
    (((x) & 0x000000FFU) << 24) | \
    (((x) & 0x0000FF00U) <<  8) | \
    (((x) & 0x00FF0000U) >>  8) | \
    (((x) & 0xFF000000U) >> 24)))
#define lwip_ntohl(x) lwip_htonl(x)

/* Also provide the standard names as macros */
#ifndef htons
#define htons(x) lwip_htons(x)
#define ntohs(x) lwip_ntohs(x)
#define htonl(x) lwip_htonl(x)
#define ntohl(x) lwip_ntohl(x)
#endif

/* Random number (simple — not cryptographic) */
#define LWIP_RAND() ((u32_t)0xDEADBEEF)

#endif /* LWIP_ARCH_CC_H */
