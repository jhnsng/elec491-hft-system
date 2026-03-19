#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

// ob_update is packed into 64 bits
typedef uint64_t ob_update;

// Unpack macros
#define OB_UPDATE_GET_SIDE(x)     ((x) >> 63)
#define OB_UPDATE_GET_PRICE(x)    (((x) >> 32) & 0x7FFFFFFF) << 2
#define OB_UPDATE_GET_QTY(x)      ((x) & 0xFFFFFFFF)

typedef struct {
    uint32_t price;
    uint32_t qty;        
    bool     side;  // 0 = buy, 1 = sell  
    bool     valid;      
    uint16_t _pad;       
} order_entry_t;

#define MAX_ORDERS 964236
extern order_entry_t order_map[MAX_ORDERS];

extern ob_update order_add(uint64_t id, uint32_t price, uint32_t qty, uint8_t side);
extern ob_update order_cancel_execute(uint64_t id, uint32_t qty);

void test_order_add_buy() {
    printf("Test 1: Add buy order...\n");
    ob_update upd = order_add(100, 50000, 100, 'B');
    
    assert(OB_UPDATE_GET_PRICE(upd) == 50000);
    assert(OB_UPDATE_GET_QTY(upd) == 100);
    assert(OB_UPDATE_GET_SIDE(upd) == 0);  // Buy = 0
    assert(order_map[100].valid == 1);
    assert(order_map[100].side == 0);
    
    printf("  ✓ Buy order added correctly\n");
}

void test_order_add_sell() {
    printf("Test 2: Add sell order...\n");
    ob_update upd = order_add(200, 51000, 250, 'S');
    
    assert(OB_UPDATE_GET_PRICE(upd) == 51000);
    assert(OB_UPDATE_GET_QTY(upd) == 250);
    assert(OB_UPDATE_GET_SIDE(upd) == 1);  // Sell = 1
    assert(order_map[200].valid == 1);
    assert(order_map[200].side == 1);
    
    printf("  ✓ Sell order added correctly\n");
}

void test_partial_cancel() {
    printf("Test 3: Partial cancel/execute...\n");
    // First add an order
    order_add(300, 49500, 500, 'B');
    
    // Partial cancel/execute 200 units
    ob_update upd = order_cancel_execute(300, 200);
    
    assert(OB_UPDATE_GET_PRICE(upd) == 49500);
    assert(OB_UPDATE_GET_QTY(upd) == 200);
    assert(OB_UPDATE_GET_SIDE(upd) == 0);
    assert(order_map[300].qty == 300);  // 500 - 200 = 300
    assert(order_map[300].valid == 1);  // Still valid
    
    printf("  ✓ Partial cancel works correctly\n");
}

void test_full_cancel() {
    printf("Test 4: Full cancel/execute...\n");
    // First add an order
    order_add(400, 52000, 150, 'S');
    
    // Fully cancel/execute
    ob_update upd = order_cancel_execute(400, 150);
    
    assert(OB_UPDATE_GET_PRICE(upd) == 52000);
    assert(OB_UPDATE_GET_QTY(upd) == 150);
    assert(OB_UPDATE_GET_SIDE(upd) == 1);
    assert(order_map[400].qty == 0);
    assert(order_map[400].valid == 0);  // No longer valid
    
    printf("  ✓ Full cancel works correctly\n");
}

void test_over_cancel() {
    printf("Test 5: Over-cancel (cancel more than available)...\n");
    // First add an order
    order_add(500, 48000, 100, 'B');
    
    // Try to cancel more than available
    ob_update upd = order_cancel_execute(500, 200);
    
    assert(OB_UPDATE_GET_PRICE(upd) == 48000);
    assert(OB_UPDATE_GET_QTY(upd) == 200);
    assert(order_map[500].qty == 0);
    assert(order_map[500].valid == 0);  // Should be invalidated
    
    printf("  ✓ Over-cancel handled correctly\n");
}

void test_memory_size() {
    printf("Test 6: Memory size calculation...\n");
    size_t entry_size = sizeof(order_entry_t);
    size_t total_size = entry_size * MAX_ORDERS;
    
    printf("  Size per entry: %zu bytes\n", entry_size);
    printf("  Total entries: %d\n", MAX_ORDERS);
    printf("  Total memory: %zu bytes (%.2f MB)\n", total_size, total_size / (1024.0 * 1024.0));
}

void test_specific_order() {
    printf("Test 7: Specific order (ID=1, Buy, Price=28000, Qty=100)...\n");
    ob_update upd = order_add(1, 28000, 100, 'B');

    // Expected: side=0, price>>2=7000(0x1B58), qty=100(0x64)
    // Full 64-bit: 0x00001B5800000064

    assert(OB_UPDATE_GET_PRICE(upd) == 28000);
    assert(OB_UPDATE_GET_QTY(upd) == 100);
    assert(OB_UPDATE_GET_SIDE(upd) == 0);  // Buy = 0
    assert(order_map[1].price == 28000);
    assert(order_map[1].qty == 100);
    assert(order_map[1].side == 0);
    assert(order_map[1].valid == 1);

    printf("  Price: 28000 (0x6D60)\n");
    printf("  Price >> 2: 7000 (0x1B58)\n");
    printf("  Quantity: 100 (0x64)\n");
    printf("  Packed value: 0x%016llX\n", upd);
    printf("  Expected:     0x00001B5800000064\n");
    assert(upd == 0x00001B5800000064ULL);

    printf("  ✓ Specific order matches expected values\n");
}

int main() {
    printf("=== OrderMap Test Suite ===\n\n");
    
    test_order_add_buy();
    test_order_add_sell();
    test_partial_cancel();
    test_full_cancel();
    test_over_cancel();
    test_memory_size();
    test_specific_order();
    
    printf("\n✓ All tests passed!\n");
    return 0;
}
