#include <stdint.h>
#include <stdbool.h>

// Manual byte order conversions for Windows/MinGW compatibility
static inline uint32_t ntohl_manual(uint32_t x) {
    return ((x & 0xFF000000) >> 24) |
           ((x & 0x00FF0000) >> 8)  |
           ((x & 0x0000FF00) << 8)  |
           ((x & 0x000000FF) << 24);
}

static inline uint64_t be64toh_manual(uint64_t x) {
    return ((x & 0xFF00000000000000ULL) >> 56) |
           ((x & 0x00FF000000000000ULL) >> 40) |
           ((x & 0x0000FF0000000000ULL) >> 24) |
           ((x & 0x000000FF00000000ULL) >> 8)  |
           ((x & 0x00000000FF000000ULL) << 8)  |
           ((x & 0x0000000000FF0000ULL) << 24) |
           ((x & 0x000000000000FF00ULL) << 40) |
           ((x & 0x00000000000000FFULL) << 56);
}

// ob_update packed into 64 bits:
// Bit 63: side (0=buy, 1=sell)
// Bits 32-62: price >> 2 (31 bits, divide by 4 using fast bit shift)
// Bits 0-31: delta_qty (32 bits)
typedef uint64_t ob_update;

typedef struct {
    uint32_t price;
    uint32_t qty;        
    bool     side;  // 0 = buy, 1 = sell  
    bool     valid;      
    uint16_t _pad;       
} order_entry_t;

#define MAX_ORDERS 964236

extern order_entry_t order_map[MAX_ORDERS];
order_entry_t order_map[MAX_ORDERS];

ob_update order_add(uint64_t id, uint32_t price,
                    uint32_t qty, uint8_t side)
{
    // Convert from network byte order (big-endian) to host byte order
    id = be64toh_manual(id);
    price = ntohl_manual(price);
    qty = ntohl_manual(qty);
    
    order_entry_t *e = &order_map[id];
    e->price = price;
    e->qty   = qty;
    e->side  = (side == 'S');  // 'B' = 0 (buy), 'S' = 1 (sell)
    e->valid = 1;
    
    // Pack into 64 bits: [side(1bit)][price>>2(31bits)][qty(32bits)]
    return ((uint64_t)e->side << 63) | ((uint64_t)(price >> 2) << 32) | qty;
}

ob_update order_cancel_execute(uint64_t id, uint32_t qty)
{
    // Convert from network byte order (big-endian) to host byte order
    id = be64toh_manual(id);
    qty = ntohl_manual(qty);
    
    order_entry_t *e = &order_map[id];
    
    // Pack into 64 bits: [side(1bit)][price>>2(31bits)][qty(32bits)]
    uint64_t packed = ((uint64_t)e->side << 63) | ((uint64_t)(e->price >> 2) << 32) | qty;
    
    if (!e->valid) return packed;

    if (qty >= e->qty) {
        // fully canceled/executed
        e->qty   = 0;
        e->valid = 0;
    } else {
        // partial cancel/execute
        e->qty -= qty;
    }
    
    return packed;
}