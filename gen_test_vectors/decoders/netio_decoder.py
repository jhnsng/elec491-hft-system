"""
NetIO Decoder

Decodes JSON data into ITCH 5.0 protocol netio-layer test vectors.
Supports message types: A (Add Order), F (Add Order MPID), X (Cancel), D (Delete), E (Execute)
"""

from pathlib import Path
from typing import Dict, Any, List
import struct

from base_decoder import BaseDecoder


class NetioDecoder(BaseDecoder):
    """Decoder for ITCH 5.0 netio layer test vectors."""
    
    def __init__(self, config: Dict[str, Any], output_dir: Path):
        super().__init__(config, output_dir)
        self.packet_counter = 0
        self.stock_locate_counter = 1
    
    def encode_add_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Add Order message (Type 'A' or 'F').
        Format: 36 bytes total
        - Message Type (1 byte)
        - Stock Locate (2 bytes, big endian)
        - Tracking Number (2 bytes, big endian)
        - Timestamp (6 bytes, big endian)
        - Order Reference Number (8 bytes, big endian) - using Order ID
        - Buy/Sell Indicator (1 byte) 'B' or 'S'
        - Shares (4 bytes, big endian)
        - Stock (8 bytes, ASCII space-padded)
        - Price (4 bytes, big endian)
        """
        msg_type = ord(row['Message Type'])
        stock_locate = 0
        tracking_num = 0
        
        timestamp = int(row['Timestamp'])  # Use parsed timestamp from Excel
        order_id = int(row['Order ID'])
        side = ord(row['Side'])  # 'B' or 'S'
        shares = int(row['Shares'])
        stock = row['Stock'].ljust(8)[:8]  # Pad/truncate to 8 chars
        price = float(row['Price'])
        
        # Convert price to integer representation (price * 100 for 2 decimal places)
        # Example: 280.00 -> 28000 (0x6D60), 281.00 -> 28100 (0x6DC4)
        price_encoded = int(price * 100)
        
        packet = struct.pack(
            '>B H H 6s Q B I 8s I',
            msg_type,           # 1 byte: Message Type
            stock_locate,       # 2 bytes: Stock Locate
            tracking_num,       # 2 bytes: Tracking Number
            timestamp.to_bytes(6, 'big'),  # 6 bytes: Timestamp
            order_id,           # 8 bytes: Order Reference Number
            side,               # 1 byte: Buy/Sell
            shares,             # 4 bytes: Shares
            stock.encode('ascii'),  # 8 bytes: Stock
            price_encoded       # 4 bytes: Price
        )
        
        return packet
    
    def encode_cancel_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Cancel/Delete Order message (Type 'X' or 'D').
        Format: 23 bytes total
        - Message Type (1 byte)
        - Stock Locate (2 bytes, big endian)
        - Tracking Number (2 bytes, big endian)
        - Timestamp (6 bytes, big endian)
        - Order Reference Number (8 bytes, big endian) - using Order ID
        - Shares Cancelled (4 bytes, big endian)
        """
        msg_type = ord(row['Message Type'])
        stock_locate = 0
        tracking_num = 0
        
        timestamp = int(row['Timestamp'])  # Use parsed timestamp from Excel
        order_id = int(row['Order ID'])
        shares = int(row['Shares'])
        
        packet = struct.pack(
            '>B H H 6s Q I',
            msg_type,           # 1 byte: Message Type
            stock_locate,       # 2 bytes: Stock Locate
            tracking_num,       # 2 bytes: Tracking Number
            timestamp.to_bytes(6, 'big'),  # 6 bytes: Timestamp
            order_id,           # 8 bytes: Order Reference Number
            shares              # 4 bytes: Shares Cancelled
        )
        
        return packet
    
    def encode_execute_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Execute Order message (Type 'E').
        Format: 31 bytes total
        - Message Type (1 byte)
        - Stock Locate (2 bytes, big endian)
        - Tracking Number (2 bytes, big endian)
        - Timestamp (6 bytes, big endian)
        - Order Reference Number (8 bytes, big endian)
        - Executed Shares (4 bytes, big endian)
        - Match Number (8 bytes, big endian)
        """
        msg_type = ord(row['Message Type'])
        stock_locate = 0
        tracking_num = 0
        
        timestamp = int(row['Timestamp'])  # Use parsed timestamp from Excel
        order_id = int(row['Order ID'])
        shares = int(row['Shares'])
        match_number = self.packet_counter  # Use packet counter as match number
        
        packet = struct.pack(
            '>B H H 6s Q I Q',
            msg_type,           # 1 byte: Message Type
            stock_locate,       # 2 bytes: Stock Locate
            tracking_num,       # 2 bytes: Tracking Number
            timestamp.to_bytes(6, 'big'),  # 6 bytes: Timestamp
            order_id,           # 8 bytes: Order Reference Number
            shares,             # 4 bytes: Executed Shares
            match_number        # 8 bytes: Match Number
        )
        
        return packet
    
    def decode(self, json_data: List[Dict[str, Any]]) -> List[Path]:
        """
        Decode JSON data and generate ITCH 5.0 netio-layer test files.
        
        Args:
            json_data: List of dictionaries with netio-related fields
        
        Returns:
            List of paths to generated output files
        """
        output_files = []
        
        # Generate Python bytes file with encoded ITCH 5.0 packets
        py_lines = []
        py_lines.append("# ITCH 5.0 Test Vector Payloads")
        py_lines.append("# Auto-generated from Excel test vectors")
        py_lines.append("")
        
        for row in json_data:
            msg_type = row.get('Message Type', '').upper()
            order_id = row.get('Order ID')
            side = row.get('Side', 'N/A')
            shares = row.get('Shares')
            stock = row.get('Stock', 'N/A')
            price = row.get('Price', 0.0)
            row_num = row['row_number']
            
            # Generate packet based on message type
            if msg_type in ('A', 'F'):
                packet = self.encode_add_order(row)
                desc = f"Row {row_num}: Add Order ID {order_id}, Side {side}, Qty {shares}, {stock}, Price {price}"
            elif msg_type in ('X', 'D'):
                packet = self.encode_cancel_order(row)
                desc = f"Row {row_num}: Cancel Order ID {order_id}, Qty {shares}"
            elif msg_type == 'E':
                packet = self.encode_execute_order(row)
                desc = f"Row {row_num}: Execute Order ID {order_id}, Qty {shares}"
            else:
                print(f"  Warning: Unsupported message type '{msg_type}' in row {row_num}")
                continue
            
            # Convert to hex string
            hex_str = ' '.join(f'{b:02X}' for b in packet)
            
            # Add to Python output with row number as payload ID
            py_lines.append(f"# {desc}")
            py_lines.append(f'PAYLOAD_{row_num} = bytes.fromhex("{hex_str}")')
            py_lines.append("")
            
            self.packet_counter += 1
        
        # Write JSON output (parsed Excel data)
        json_output_path = self.output_dir / 'netio_vectors.json'
        self.write_json(json_output_path, json_data)
        output_files.append(json_output_path)
        
        # Write Python output (encoded ITCH 5.0 packets)
        py_output_path = self.output_dir / 'netio_vectors.py'
        py_content = '\n'.join(py_lines)
        self.write_file(py_output_path, py_content)
        output_files.append(py_output_path)
        
        return output_files
    

