"""
Test Vector Generator

This script generates test vectors for different hardware layers (exchange, netio, orderbook)
by parsing an Excel file based on YAML configuration files and using layer-specific decoders.

Usage:
    python gen_test_vectors.py --config config/exchange.yaml --input test_vectors.xlsx
    python gen_test_vectors.py --config config/netio.yaml --input test_vectors.xlsx
    python gen_test_vectors.py --config config/orderbook.yaml --input test_vectors.xlsx
"""

import argparse
import sys
from pathlib import Path
import re
from typing import Dict, Any, List

from excel_to_json import ExcelToJsonParser
from decoders.exchange_decoder import ExchangeDecoder
from decoders.netio_decoder import NetioDecoder
from decoders.orderbook_decoder import OrderbookDecoder


class TestVectorGenerator:
    """Main class for generating test vectors from Excel files."""
    
    def __init__(self, config_path: str, input_path: str):
        """
        Initialize the test vector generator.
        
        Args:
            config_path: Path to YAML configuration file
            input_path: Path to input Excel file
        """
        self.config_path = Path(config_path)
        self.input_path = Path(input_path)
        self.parser = ExcelToJsonParser(config_path, input_path)
        self.config = self.parser.get_config()
        self.output_dir = Path(__file__).parent / "outputs"
        self.output_dir.mkdir(exist_ok=True)

    def _sanitize_sheet_name(self, sheet_name: str) -> str:
        """Create a filesystem-safe folder name from a sheet name."""
        sanitized = re.sub(r"[^A-Za-z0-9._-]", "_", str(sheet_name).strip())
        return sanitized or "sheet"

    def _should_combine_sheets(self) -> bool:
        """Return whether configured sheets should be decoded into one combined output."""
        return bool(self.config.get("output", {}).get("combine_sheets", False))

    def _summary_filename(self) -> str:
        """Resolve summary filename from config with a sensible default."""
        return str(self.config.get("output", {}).get("summary_filename", "sheet_message_counts.txt"))

    def _write_sheet_summary(self, sheet_results: List[Dict[str, Any]], output_dir: Path) -> Path:
        """
        Write a text summary with per-sheet row counts and cumulative message ranges.

        This helps locate approximate breakpoints at sheet boundaries in combined outputs.
        """
        summary_path = output_dir / self._summary_filename()
        lines: List[str] = []
        running_total = 0

        for sheet in sheet_results:
            sheet_name = str(sheet["sheet_name"])
            row_count = len(sheet["rows"])
            start_idx = running_total + 1 if row_count > 0 else running_total
            end_idx = running_total + row_count

            lines.append(sheet_name)
            lines.append(f"rows/messages: {row_count}")
            lines.append(f"start_message_index: {start_idx}")
            lines.append(f"end_message_index: {end_idx}")
            lines.append("")

            running_total = end_idx

        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
        return summary_path
    
    def get_decoder(self, output_dir: Path):
        """
        Instantiate the appropriate decoder based on the layer specified in config.
        
        Returns:
            Decoder instance for the specified layer
        """
        layer = self.config['layer'].lower()
        
        decoder_map = {
            'exchange': ExchangeDecoder,
            'netio': NetioDecoder,
            'orderbook': OrderbookDecoder,
        }
        
        if layer not in decoder_map:
            raise ValueError(f"Unknown layer: {layer}. Valid layers: {list(decoder_map.keys())}")
        
        decoder_class = decoder_map[layer]
        return decoder_class(self.config, output_dir)
    
    def generate(self):
        """Main generation workflow."""
        print(f"=== Test Vector Generator ===")
        print(f"Config: {self.config_path}")
        print(f"Input:  {self.input_path}")
        print(f"Layer:  {self.config['layer']}")
        print()
        
        # Step 1: Parse configured sheets in order
        print("Step 1: Parsing Excel sheets...")
        sheet_results = self.parser.parse_all_sheets()
        print(f"  Parsed {len(sheet_results)} sheet(s)")

        # Step 2: Decode sheets in configured output mode.
        combine_sheets = self._should_combine_sheets()
        output_files = []

        if combine_sheets:
            print("\nStep 2: Generating combined output across all sheets...")
            for sheet_result in sheet_results:
                print(
                    f"  - Sheet {sheet_result['sheet_index']}: "
                    f"{sheet_result['sheet_name']} ({len(sheet_result['rows'])} rows)"
                )

            decoder = self.get_decoder(self.output_dir)
            combined_rows: List[Dict[str, Any]] = []
            for sheet_result in sheet_results:
                combined_rows.extend(sheet_result["rows"])

            output_files.extend(decoder.decode(combined_rows))
        else:
            print("\nStep 2: Generating output files per sheet...")
            for sheet_result in sheet_results:
                sheet_name = sheet_result["sheet_name"]
                sheet_index = sheet_result["sheet_index"]
                json_data = sheet_result["rows"]

                sheet_output_dir = self.output_dir / self._sanitize_sheet_name(sheet_name)
                sheet_output_dir.mkdir(parents=True, exist_ok=True)

                decoder = self.get_decoder(sheet_output_dir)

                # Optional context hook for decoders that need sheet metadata.
                if hasattr(decoder, "set_sheet_context"):
                    decoder.set_sheet_context(sheet_name=sheet_name, sheet_index=sheet_index)

                print(f"  - Sheet {sheet_index}: {sheet_name} ({len(json_data)} rows)")
                output_files.extend(decoder.decode(json_data))

        # Step 3: Always emit sheet row/message summary for debug breakpoint planning.
        print("\nStep 3: Writing per-sheet message summary...")
        summary_path = self._write_sheet_summary(sheet_results, self.output_dir)
        output_files.append(summary_path)
        print(f"  Generated: {summary_path}")

        print("\n=== Generation Complete ===")
        print("Output files:")
        for output_file in output_files:
            print(f"  - {output_file}")


def main():
    """Command-line entry point."""
    parser = argparse.ArgumentParser(
        description="Generate test vectors for hardware layers from Excel input"
    )
    parser.add_argument(
        '--config', '-c',
        required=True,
        help='Path to YAML configuration file'
    )
    parser.add_argument(
        '--input', '-i',
        required=True,
        help='Path to input Excel file'
    )
    
    args = parser.parse_args()
    
    try:
        generator = TestVectorGenerator(args.config, args.input)
        generator.generate()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
