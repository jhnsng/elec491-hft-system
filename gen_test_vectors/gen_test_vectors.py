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
    
    def get_decoder(self):
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
        return decoder_class(self.config, self.output_dir)
    
    def generate(self):
        """Main generation workflow."""
        print(f"=== Test Vector Generator ===")
        print(f"Config: {self.config_path}")
        print(f"Input:  {self.input_path}")
        print(f"Layer:  {self.config['layer']}")
        print()
        
        # Step 1: Parse Excel file
        print("Step 1: Parsing Excel file...")
        json_data = self.parser.parse()
        print(f"  Parsed {len(json_data)} rows")
        
        # Step 2: Get appropriate decoder
        print("\nStep 2: Initializing decoder...")
        decoder = self.get_decoder()
        print(f"  Using {decoder.__class__.__name__}")
        
        # Step 3: Decode and generate output
        print("\nStep 3: Generating output files...")
        output_files = decoder.decode(json_data)
        
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
