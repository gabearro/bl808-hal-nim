#include <stdint.h>

extern uint8_t __real_sch_arb_insert(void *elt);
extern void __real_sch_prog_push(void *prog);

volatile uint32_t ble_vendor_wrap_arb_insert_count;
volatile uint32_t ble_vendor_wrap_arb_insert_status;
volatile uintptr_t ble_vendor_wrap_arb_insert_last;
volatile uint32_t ble_vendor_wrap_prog_push_count;
volatile uintptr_t ble_vendor_wrap_prog_push_last;

uint8_t __wrap_sch_arb_insert(void *elt)
{
    uint8_t status;

    ble_vendor_wrap_arb_insert_count++;
    ble_vendor_wrap_arb_insert_last = (uintptr_t)elt;
    status = __real_sch_arb_insert(elt);
    ble_vendor_wrap_arb_insert_status = status;
    return status;
}

void __wrap_sch_prog_push(void *prog)
{
    ble_vendor_wrap_prog_push_count++;
    ble_vendor_wrap_prog_push_last = (uintptr_t)prog;
    __real_sch_prog_push(prog);
}
