package _pkg;
    parameter PRICE_WIDTH = 32;
    parameter QTY_WIDTH = 32;

typedef enum logic {
    SIDE_BID = 1'b0,
    SIDE_ASK = 1'b1
} side_t;

typedef struct packed {
    side_t side;
    logic [PRICE_WIDTH-1:0] price;
    logic [QTY_WIDTH-1:0] delta_qty;
    logic valid;
} order_info_t;

endpackage: _pkg