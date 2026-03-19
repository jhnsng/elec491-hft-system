"""
Excel to JSON Parser

Handles parsing Excel files based on YAML configuration files.
"""

from pathlib import Path
from typing import Dict, Any, List

import pandas as pd
import yaml


class ExcelToJsonParser:
    """Parser for converting Excel files to JSON based on YAML configuration."""
    
    def __init__(self, config_path: str, input_path: str):
        """
        Initialize the parser.
        
        Args:
            config_path: Path to YAML configuration file
            input_path: Path to input Excel file
        """
        self.config_path = Path(config_path)
        self.input_path = Path(input_path)
        self.config = self._load_config()
        
    def _load_config(self) -> Dict[str, Any]:
        """Load and parse YAML configuration file."""
        if not self.config_path.exists():
            raise FileNotFoundError(f"Configuration file not found: {self.config_path}")
        
        with open(self.config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        # Validate required fields
        required_fields = ['layer', 'columns']
        for field in required_fields:
            if field not in config:
                raise ValueError(f"Missing required field in config: {field}")
        
        return config
    
    def parse(self) -> List[Dict[str, Any]]:
        """
        Parse Excel file and convert to JSON based on YAML column specifications.
        
        Returns:
            List of dictionaries, each representing a row with specified columns
        """
        sheet_results = self.parse_all_sheets()
        if not sheet_results:
            return []
        return sheet_results[0]["rows"]

    def get_sheet_names_in_order(self) -> List[str]:
        """Return sheet names to parse in the order specified by config."""
        if "sheet_names" in self.config:
            sheet_names = self.config["sheet_names"]
            if not isinstance(sheet_names, list) or not sheet_names:
                raise ValueError("'sheet_names' must be a non-empty list when provided")
            return [str(name) for name in sheet_names]

        if "sheet_name" in self.config:
            return [str(self.config["sheet_name"])]

        return [0]

    def parse_all_sheets(self) -> List[Dict[str, Any]]:
        """
        Parse all configured sheets in order.

        Returns:
            List of sheet parse results in order:
            [
              {
                "sheet_name": "...",
                "sheet_index": 1,
                "rows": [...]
              },
              ...
            ]
        """
        if not self.input_path.exists():
            raise FileNotFoundError(f"Input Excel file not found: {self.input_path}")

        # Get column specifications from config
        columns_config = self.config['columns']

        # Extract only the columns specified in the config
        column_names = []
        column_mappings = {}

        for col_spec in columns_config:
            if isinstance(col_spec, dict):
                # Format: {original_name: mapped_name}
                orig_name = list(col_spec.keys())[0]
                mapped_name = col_spec[orig_name]
                column_names.append(orig_name)
                column_mappings[orig_name] = mapped_name
            else:
                # Simple string column name
                column_names.append(col_spec)
                column_mappings[col_spec] = col_spec

        results: List[Dict[str, Any]] = []
        sheet_names = self.get_sheet_names_in_order()

        for idx, sheet_name in enumerate(sheet_names, start=1):
            df = pd.read_excel(self.input_path, sheet_name=sheet_name)

            # Verify columns exist per sheet
            missing_cols = set(column_names) - set(df.columns)
            if missing_cols:
                raise ValueError(f"Columns not found in sheet '{sheet_name}': {missing_cols}")

            # Select and rename columns
            df_selected = df[column_names].copy()
            df_selected = df_selected.rename(columns=column_mappings)

            # Add row number (1-indexed to match Excel)
            df_selected.insert(0, 'row_number', range(2, len(df_selected) + 2))

            # Convert to list of dictionaries (JSON-serializable)
            json_data = df_selected.to_dict('records')

            # Apply any data type conversions specified in config
            if 'data_types' in self.config:
                json_data = self._apply_data_types(json_data, self.config['data_types'])

            results.append(
                {
                    "sheet_name": sheet_name,
                    "sheet_index": idx,
                    "rows": json_data,
                }
            )

        return results
    
    def _apply_data_types(self, data: List[Dict], type_specs: Dict[str, str]) -> List[Dict]:
        """Apply data type conversions to JSON data."""
        def _to_numeric(value: Any) -> float:
            if isinstance(value, str):
                cleaned = value.replace("$", "").replace(",", "").strip()
                return float(cleaned)
            return float(value)

        for row in data:
            for field, dtype in type_specs.items():
                if field in row and pd.notna(row[field]):
                    if dtype == 'int':
                        row[field] = int(_to_numeric(row[field]))
                    elif dtype == 'float':
                        row[field] = _to_numeric(row[field])
                    elif dtype == 'str':
                        row[field] = str(row[field])
                    elif dtype == 'bool':
                        row[field] = bool(row[field])
        return data
    
    def get_config(self) -> Dict[str, Any]:
        """Get the loaded configuration."""
        return self.config
