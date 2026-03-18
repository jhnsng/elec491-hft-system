"""
Exchange Decoder

Decodes JSON data into exchange-layer ITCH 5.0 binary test vectors.

Produces the length-prefixed binary stream format consumed by ITCHStream:
    [2-byte big-endian length][ITCH message body]
where ITCH message body = [1-byte type][payload fields...]

Supports message types: A (Add Order), F (Add Order MPID), X (Cancel),
D (Delete), E (Execute)
"""

from pathlib import Path
from typing import Dict, Any, List
import struct
from decimal import Decimal, ROUND_HALF_UP

from base_decoder import BaseDecoder


class ExchangeDecoder(BaseDecoder):
    """Decoder for exchange layer ITCH 5.0 binary stream test vectors."""

    def __init__(self, config: Dict[str, Any], output_dir: Path):
        super().__init__(config, output_dir)
        self._match_counter = 0

    def _encode_price_4(self, price: Any) -> int:
        """Convert human-readable price to ITCH Price(4) fixed-point integer."""
        price_dec = Decimal(str(price)).quantize(Decimal('0.0001'), rounding=ROUND_HALF_UP)
        return int(price_dec * Decimal('10000'))

    def _get_attribution(self, row: Dict[str, Any]) -> str:
        """Resolve F-message attribution from sheet data; default to a placeholder."""
        attribution_raw = row.get('Attribution')
        if attribution_raw is None:
            return 'NSDQ'

        attribution = str(attribution_raw).strip()
        if not attribution or attribution.lower() == 'nan':
            return 'NSDQ'

        return attribution[:4].ljust(4)

    # ------------------------------------------------------------------
    # ITCH message body encoders (1-byte type + payload, NO length prefix)
    # ------------------------------------------------------------------

    def encode_add_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Add Order message body (Type 'A').
        Total: 36 bytes
          Message Type      (1 byte)
          Stock Locate      (2 bytes BE)
          Tracking Number   (2 bytes BE)
          Timestamp         (6 bytes BE)
          Order Ref Number  (8 bytes BE)
          Buy/Sell          (1 byte)  'B' or 'S'
          Shares            (4 bytes BE)
          Stock             (8 bytes ASCII, space-padded)
          Price             (4 bytes BE, Price(4): price * 10000)
        """
        return struct.pack(
            '>B H H 6s Q B I 8s I',
            ord(row['Message Type']),
            0,
            0,
            int(row['Timestamp']).to_bytes(6, 'big'),
            int(row['Order ID']),
            ord(row['Side']),
            int(row['Shares']),
            row['Stock'].ljust(8)[:8].encode('ascii'),
            self._encode_price_4(row['Price']),
        )

    def encode_add_order_mpid(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Add Order with MPID Attribution message body (Type 'F').
        Total: 40 bytes
          Message Type      (1 byte)
          Stock Locate      (2 bytes BE)
          Tracking Number   (2 bytes BE)
          Timestamp         (6 bytes BE)
          Order Ref Number  (8 bytes BE)
          Buy/Sell          (1 byte)  'B' or 'S'
          Shares            (4 bytes BE)
          Stock             (8 bytes ASCII, space-padded)
          Price             (4 bytes BE, Price(4): price * 10000)
          Attribution       (4 bytes ASCII, space-padded)
        """
        attribution = self._get_attribution(row)
        return struct.pack(
            '>B H H 6s Q B I 8s I 4s',
            ord(row['Message Type']),
            0,
            0,
            int(row['Timestamp']).to_bytes(6, 'big'),
            int(row['Order ID']),
            ord(row['Side']),
            int(row['Shares']),
            row['Stock'].ljust(8)[:8].encode('ascii'),
            self._encode_price_4(row['Price']),
            attribution.encode('ascii'),
        )

    def encode_cancel_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Cancel Order message body (Type 'X').
        Total: 23 bytes
          Message Type      (1 byte)
          Stock Locate      (2 bytes BE)
          Tracking Number   (2 bytes BE)
          Timestamp         (6 bytes BE)
          Order Ref Number  (8 bytes BE)
          Shares Cancelled  (4 bytes BE)
        """
        return struct.pack(
            '>B H H 6s Q I',
            ord(row['Message Type']),
            0,
            0,
            int(row['Timestamp']).to_bytes(6, 'big'),
            int(row['Order ID']),
            int(row['Shares']),
        )

    def encode_delete_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Delete Order message body (Type 'D').
        Total: 19 bytes
          Message Type      (1 byte)
          Stock Locate      (2 bytes BE)
          Tracking Number   (2 bytes BE)
          Timestamp         (6 bytes BE)
          Order Ref Number  (8 bytes BE)
        """
        return struct.pack(
            '>B H H 6s Q',
            ord(row['Message Type']),
            0,
            0,
            int(row['Timestamp']).to_bytes(6, 'big'),
            int(row['Order ID']),
        )

    def encode_execute_order(self, row: Dict[str, Any]) -> bytes:
        """
        Encode Execute Order message body (Type 'E').
        Total: 31 bytes
          Message Type      (1 byte)
          Stock Locate      (2 bytes BE)
          Tracking Number   (2 bytes BE)
          Timestamp         (6 bytes BE)
          Order Ref Number  (8 bytes BE)
          Executed Shares   (4 bytes BE)
          Match Number      (8 bytes BE)
        """
        body = struct.pack(
            '>B H H 6s Q I Q',
            ord(row['Message Type']),
            0,
            0,
            int(row['Timestamp']).to_bytes(6, 'big'),
            int(row['Order ID']),
            int(row['Shares']),
            self._match_counter,
        )
        return body

    # ------------------------------------------------------------------
    # Length-prefix framing
    # ------------------------------------------------------------------

    def frame_message(self, body: bytes) -> bytes:
        """Prepend 2-byte big-endian length to produce ITCHStream wire format."""
        return struct.pack('>H', len(body)) + body

    # ------------------------------------------------------------------
    # Main decode entry point
    # ------------------------------------------------------------------

    def decode(self, json_data: List[Dict[str, Any]]) -> List[Path]:
        """
        Decode JSON data and generate exchange-layer test files.

        Outputs:
          exchange_vectors.bin  — binary ITCH stream (length-prefixed frames)
          exchange_vectors.py   — FRAME_N hex literals for each message
          exchange_vectors.json — raw parsed Excel data

        Args:
            json_data: List of dictionaries with exchange-related fields

        Returns:
            List of paths to generated output files
        """
        output_files = []
        binary_frames = bytearray()
        py_lines = [
            '# ITCH 5.0 Exchange Binary Test Vectors',
            '# Auto-generated from Excel test vectors',
            '# Format per frame: [2-byte BE length][ITCH message body] (ITCHStream wire format)',
            '',
        ]

        for row in json_data:
            msg_type = row.get('Message Type', '').upper()
            row_num = row['row_number']

            if msg_type == 'A':
                body = self.encode_add_order(row)
                desc = (
                    f"Row {row_num}: Add Order "
                    f"ID {row.get('Order ID')}, Side {row.get('Side', 'N/A')}, "
                    f"Qty {row.get('Shares')}, {row.get('Stock', 'N/A')}, "
                    f"Price {row.get('Price', 0.0)}"
                )
            elif msg_type == 'F':
                body = self.encode_add_order_mpid(row)
                desc = (
                    f"Row {row_num}: Add Order MPID "
                    f"ID {row.get('Order ID')}, Side {row.get('Side', 'N/A')}, "
                    f"Qty {row.get('Shares')}, {row.get('Stock', 'N/A')}, "
                    f"Price {row.get('Price', 0.0)}, MPID {self._get_attribution(row)}"
                )
            elif msg_type == 'X':
                body = self.encode_cancel_order(row)
                desc = (
                    f"Row {row_num}: Cancel Order "
                    f"ID {row.get('Order ID')}, Qty {row.get('Shares')}"
                )
            elif msg_type == 'D':
                body = self.encode_delete_order(row)
                desc = (
                    f"Row {row_num}: Delete Order "
                    f"ID {row.get('Order ID')}"
                )
            elif msg_type == 'E':
                body = self.encode_execute_order(row)
                desc = (
                    f"Row {row_num}: Execute Order "
                    f"ID {row.get('Order ID')}, Qty {row.get('Shares')}"
                )
                self._match_counter += 1
            else:
                print(f"  Warning: Unsupported message type '{msg_type}' in row {row_num}")
                continue

            frame = self.frame_message(body)
            binary_frames.extend(frame)

            hex_str = ' '.join(f'{b:02X}' for b in frame)
            py_lines.append(f'# {desc}')
            py_lines.append(f'FRAME_{row_num} = bytes.fromhex("{hex_str}")')
            py_lines.append('')

        # Write JSON output (parsed Excel data)
        json_output_path = self.output_dir / 'exchange_vectors.json'
        self.write_json(json_output_path, json_data)
        output_files.append(json_output_path)

        # Write Python hex-literal output
        py_output_path = self.output_dir / 'exchange_vectors.py'
        self.write_file(py_output_path, '\n'.join(py_lines))
        output_files.append(py_output_path)

        # Write binary stream output
        bin_output_path = self.output_dir / 'exchange_vectors.bin'
        with open(bin_output_path, 'wb') as f:
            f.write(binary_frames)
        print(f'  Generated: {bin_output_path}')
        output_files.append(bin_output_path)

        return output_files


