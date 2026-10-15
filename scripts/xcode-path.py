#!/usr/bin/env python3
"""Read product paths from Xcode so command-line builds share GUI DerivedData."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("configuration", choices=("Debug", "Release"))
parser.add_argument("--derived-data", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
project = repo / 'Kit.xcodeproj'
command = ["xcodebuild", "-project", str(project), "-scheme", 'Kit',
           "-configuration", args.configuration, "-destination", "generic/platform=macOS",
           "-showBuildSettings", "-json"]
result = subprocess.run(command, capture_output=True, text=True)
if result.returncode:
    sys.stderr.write(result.stdout + result.stderr)
    raise SystemExit(result.returncode)
settings = [entry["buildSettings"] for entry in json.loads(result.stdout)
            if entry["target"] == 'Kit']
if len(settings) != 1:
    raise SystemExit("Expected one app target in Xcode build settings")
settings = settings[0]
derived_data = Path(settings["BUILD_DIR"]).parent.parent
expected_root = Path.home() / "Library/Developer/Xcode/DerivedData"
if not derived_data.is_relative_to(expected_root):
    raise SystemExit(f"Xcode uses a nondefault build location: {derived_data}")
print(derived_data if args.derived_data else
      Path(settings["BUILT_PRODUCTS_DIR"]) / settings["FULL_PRODUCT_NAME"])
