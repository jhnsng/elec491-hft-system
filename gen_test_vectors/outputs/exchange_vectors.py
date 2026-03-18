# ITCH 5.0 Exchange Binary Test Vectors
# Auto-generated from Excel test vectors
# Format per frame: [2-byte BE length][ITCH message body] (ITCHStream wire format)

# Row 2: Add Order ID 1, Side B, Qty 100, AAPL, Price 280.0
FRAME_2 = bytes.fromhex("00 24 41 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 42 00 00 00 64 41 41 50 4C 20 20 20 20 00 2A B9 80")

# Row 3: Cancel Order ID 1, Qty 100
FRAME_3 = bytes.fromhex("00 17 58 00 00 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00 01 00 00 00 64")

# Row 4: Add Order ID 2, Side B, Qty 200, AAPL, Price 281.0
FRAME_4 = bytes.fromhex("00 24 41 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00 02 42 00 00 00 C8 41 41 50 4C 20 20 20 20 00 2A E0 90")

# Row 5: Cancel Order ID 2, Qty 200
FRAME_5 = bytes.fromhex("00 17 58 00 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 02 00 00 00 C8")
