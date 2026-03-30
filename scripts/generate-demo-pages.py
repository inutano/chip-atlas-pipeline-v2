#!/usr/bin/env python3
"""
Generate self-contained demo HTML pages with embedded JSON data.
Each page is a standalone file — no external data fetch needed.

Usage:
  python3 generate-demo-pages.py <template.html> <data.json> <output.html>
  python3 generate-demo-pages.py --batch <template.html> <json_dir> <output_dir>
"""

import sys
import os
import json
import argparse
from pathlib import Path


def embed_data(template_html, json_data, title_suffix=""):
    """Embed JSON data into HTML template, replacing fetch() with inline data."""
    # Insert embedded data script before the closing </body>
    data_script = f'<script id="embedded-data" type="application/json">\n{json.dumps(json_data)}\n</script>'

    # Replace the fetch-based init with embedded data init
    # Find the init() function and modify it
    modified = template_html.replace(
        "document.getElementById('loading').textContent = 'Loading...';",
        "// Loading embedded data..."
    )

    # Add embedded data loading at the start of init()
    modified = modified.replace(
        "function init() {",
        f"""function init() {{
  // Load from embedded data
  const embedded = document.getElementById('embedded-data');
  if (embedded) {{
    data = JSON.parse(embedded.textContent);
    try {{ render(); }} catch(e) {{ showError('Error: ' + e.message); console.error(e); }}
    return;
  }}"""
    )

    # Insert the data script before </body>
    modified = modified.replace("</body>", f"{data_script}\n</body>")

    return modified


def main():
    parser = argparse.ArgumentParser(description="Generate self-contained demo HTML pages")
    parser.add_argument("template", help="HTML template file")
    parser.add_argument("data", help="JSON data file or directory (with --batch)")
    parser.add_argument("output", help="Output HTML file or directory (with --batch)")
    parser.add_argument("--batch", action="store_true", help="Process all JSON files in directory")
    args = parser.parse_args()

    template = Path(args.template).read_text()

    if args.batch:
        os.makedirs(args.output, exist_ok=True)
        json_dir = Path(args.data)
        for json_file in sorted(json_dir.glob("*.json")):
            data = json.loads(json_file.read_text())
            html = embed_data(template, data)
            out_name = json_file.stem + ".html"
            out_path = os.path.join(args.output, out_name)
            Path(out_path).write_text(html)
            size_kb = os.path.getsize(out_path) / 1024
            print(f"  {out_name}: {size_kb:.0f} KB")
    else:
        data = json.loads(Path(args.data).read_text())
        html = embed_data(template, data)
        Path(args.output).write_text(html)
        size_kb = os.path.getsize(args.output) / 1024
        print(f"  {args.output}: {size_kb:.0f} KB")


if __name__ == "__main__":
    main()
