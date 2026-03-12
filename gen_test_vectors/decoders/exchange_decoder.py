"""
Exchange Decoder

Decodes JSON data into exchange-layer test vectors.
"""

from pathlib import Path
from typing import Dict, Any, List

from base_decoder import BaseDecoder


class ExchangeDecoder(BaseDecoder):
    """Decoder for exchange layer test vectors."""
    
    def decode(self, json_data: List[Dict[str, Any]]) -> List[Path]:
        """
        Decode JSON data and generate exchange-layer test files.
        
        Args:
            json_data: List of dictionaries with exchange-related fields
        
        Returns:
            List of paths to generated output files
        """
        output_files = []
        
        # Write JSON output (parsed Excel data)
        json_output_path = self.output_dir / 'exchange_vectors.json'
        self.write_json(json_output_path, json_data)
        output_files.append(json_output_path)
        
        return output_files
    

