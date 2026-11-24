/* RV32E M-mode atomics for core-local CPS futures on the LP core.
 *
 * E902 has no A extension and this bare-metal toolchain has no ilp32e
 * libatomic. CPS futures are private to LP; disabling local interrupts makes
 * their read/modify/write operations indivisible against LP IRQ callbacks.
 * These functions must not be used for memory concurrently written by M0 or
 * D0. XRAM ownership transfer still uses the IPC bridge's explicit handoff.
 */
#include <stdbool.h>
#include <stdint.h>

static inline uint32_t irq_save(void) {
  uint32_t old;
  __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(old) :: "memory");
  return old;
}

static inline void irq_restore(uint32_t old) {
  if (old & 8u)
    __asm__ volatile("csrsi mstatus, 8" ::: "memory");
  else
    __asm__ volatile("" ::: "memory");
}

bool __atomic_compare_exchange_4(volatile void *ptr, void *expected,
                                 uint32_t desired, int success_order,
                                 int failure_order) {
  (void)success_order;
  (void)failure_order;
  uint32_t old = irq_save();
  uint32_t current = *(volatile uint32_t *)ptr;
  bool matched = current == *(uint32_t *)expected;
  if (matched)
    *(volatile uint32_t *)ptr = desired;
  else
    *(uint32_t *)expected = current;
  irq_restore(old);
  return matched;
}

uint64_t __atomic_fetch_add_8(volatile void *ptr, uint64_t value, int order) {
  (void)order;
  uint32_t old = irq_save();
  uint64_t previous = *(volatile uint64_t *)ptr;
  *(volatile uint64_t *)ptr = previous + value;
  irq_restore(old);
  return previous;
}
