"""
Base Decoder Classes

Abstract base classes for layer-specific decoders.
"""

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Dict, Any, List
import json


class BaseDecoder(ABC):
    """
    Abstract base class for all test vector decoders.
    
    Each layer (exchange, algorithm, orderbook) should implement this interface
    to decode JSON data into layer-specific output files.
    """
    
    def __init__(self, config: Dict[str, Any], output_dir: Path):
        """
        Initialize the decoder.
        
        Args:
            config: Full configuration dictionary from YAML file
            output_dir: Directory where output files should be written
        """
        self.config = config
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        
    @abstractmethod
    def decode(self, json_data: List[Dict[str, Any]]) -> List[Path]:
        """
        Decode JSON data and generate output files.
        
        Args:
            json_data: List of dictionaries, each representing a row from Excel
                      Each dictionary includes a 'row_number' field
        
        Returns:
            List of paths to generated output files
        """
        pass
    
    def write_file(self, filepath: Path, content: str):
        """
        Write content to a file.
        
        Args:
            filepath: Path to the file
            content: Content to write
        """
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"  Generated: {filepath}")
    
    def write_json(self, filepath: Path, data: Any):
        """
        Write JSON data to a file.
        
        Args:
            filepath: Path to the file
            data: Data to serialize as JSON
        """
        with open(filepath, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"  Generated: {filepath}")
