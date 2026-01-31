#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint32_t price;
    uint32_t delta_qty;
    bool     side;  // 0 = buy, 1 = sell
} ob_update;

typedef struct {
    uint32_t price;
    uint32_t qty;        
    bool     side;  // 0 = buy, 1 = sell  
    bool     valid;      
    uint16_t _pad;       
} order_entry_t;

#define MAX_ORDERS 964236

order_entry_t order_map[MAX_ORDERS];

ob_update order_add(uint64_t id, uint32_t price,
                    uint32_t qty, uint8_t side)
{
    order_entry_t *e = &order_map[id];
    e->price = price;
    e->qty   = qty;
    e->side  = (side == 'S') ? 1 : 0;  // 'B' = 0 (buy), 'S' = 1 (sell)
    e->valid = 1;
    
    ob_update upd;
    upd.price = price;
    upd.delta_qty = qty;
    upd.side = e->side;
    return upd;
}

ob_update order_cancel_execute(uint64_t id, uint32_t qty)
{
    order_entry_t *e = &order_map[id];
    ob_update upd;
    upd.price = e->price;
    upd.delta_qty = qty;
    upd.side = e->side;
    
    if (!e->valid) return upd;

    if (qty >= e->qty) {
        // fully canceled/executed
        e->qty   = 0;
        e->valid = 0;
    } else {
        // partial cancel/execute
        e->qty -= qty;
    }
    
    return upd;
}