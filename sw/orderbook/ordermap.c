#include <stdint.h>
#include <stdbool.h>

// Manual byte order conversions for Windows/MinGW compatibility
static inline uint32_t ntohl_manual(uint32_t x) {
    return ((x & 0xFF000000) >> 24) |
           ((x & 0x00FF0000) >> 8)  |
           ((x & 0x0000FF00) << 8)  |
           ((x & 0x000000FF) << 24);
}

// htonl is the same operation as ntohl (both swap bytes)
static inline uint32_t htonl_manual(uint32_t x) {
    return ntohl_manual(x);
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

static order_entry_t order_map[MAX_ORDERS];

ob_update order_add(uint64_t id, uint32_t price,
                    uint32_t qty, uint8_t side)
{
    // Convert from network byte order (little-endian) to host byte order
    id = be64toh_manual(id);
    price = ntohl_manual(price) / 100;
    qty = ntohl_manual(qty);
    
    order_entry_t *e = &order_map[id];
    e->price = price;
    e->qty   += qty;
    e->side  = (side == 'S');  // 'B' = 0 (buy), 'S' = 1 (sell)
    e->valid = 1;

    qty = htonl_manual(qty);
    // Pack into 64 bits: [side(1bit)][price>>2(31bits)][qty(32bits)]
    return ((uint64_t)e->side << 63) | ((uint64_t)price << 32) | qty;
}

ob_update order_cancel_execute(uint64_t id, uint32_t qty)
{
    // Convert from network byte order (little-endian) to host byte order
    id = be64toh_manual(id);
    qty = ntohl_manual(qty);
    
    order_entry_t *e = &order_map[id];
    uint64_t packed;

    if (qty >= e->qty) {
        // fully canceled/executed

        // Return NEGATIVE quantity for cancel/execute using two's complement: ~qty + 1
        uint32_t negated_qty = ~(e->qty) + 1;
    
        // Convert back to little-endian for transmission
        negated_qty = htonl_manual(negated_qty);
    
        // Pack into 64 bits: [side(1bit)][price>>2(31bits)][negated_qty(32bits)]
        packed = ((uint64_t)e->side << 63) | ((uint64_t)e->price << 32) | negated_qty;
        
        e->qty   = 0;
        e->valid = 0;
    } else {
        // partial cancel/execute

        // Return NEGATIVE quantity for cancel/execute using two's complement: ~qty + 1
        uint32_t negated_qty = ~qty + 1;
    
        // Convert back to little-endian for transmission
        negated_qty = htonl_manual(negated_qty);
    
        // Pack into 64 bits: [side(1bit)][price>>2(31bits)][negated_qty(32bits)]
        packed = ((uint64_t)e->side << 63) | ((uint64_t)e->price << 32) | negated_qty;
        
        e->qty -= qty;
    }
    
    return packed;
}

ob_update order_delete(uint64_t id) {
    // Convert from network byte order (little-endian) to host byte order
    id = be64toh_manual(id);
    
    order_entry_t *e = &order_map[id];
    
    // Return NEGATIVE quantity for delete using two's complement: ~qty + 1
    uint32_t negated_qty = ~(e->qty) + 1;
    
    // Convert back to little-endian for transmission
    negated_qty = htonl_manual(negated_qty);
    
    // Pack into 64 bits: [side(1bit)][price>>2(31bits)][negated_qty(32bits)]
    uint64_t packed = ((uint64_t)e->side << 63) | ((uint64_t)e->price << 32) | negated_qty;
    
    if (!e->valid) return packed;

    e->qty   = 0;
    e->valid = 0;
    
    return packed;
}

typedef struct {
    ob_update del_upd;  // delete old order
    ob_update add_upd;  // add new order
} ob_replace_updates;

ob_replace_updates order_replace(uint64_t old_id,
                                 uint64_t new_id,
                                 uint32_t new_price,
                                 uint32_t new_qty)
{
    ob_update del_upd = order_delete(old_id);

    old_id = be64toh_manual(old_id);
    order_entry_t *old_e = &order_map[old_id];
    uint8_t side_char = old_e->side ? 'S' : 'B';

    ob_update add_upd = order_add(new_id, new_price, new_qty, side_char);

    ob_replace_updates res = { del_upd, add_upd };
    return res;
}