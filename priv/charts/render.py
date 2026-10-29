"""One locally built Vega-Lite specification in, one PNG out. No data fetches."""

import json
from pathlib import Path
import sys
import textwrap

import vl_convert


def render(spec):
    if set(spec["data"]) != {"values"}:
        raise ValueError("only inline observations may be rendered")
    vl_convert.register_font_directory(str(Path(__file__).parent / "fonts"))
    spec["title"]["text"] = textwrap.wrap(spec["title"]["text"], width=48)
    return vl_convert.vegalite_to_png(
        spec, vl_version="6.4", scale=2, allowed_base_urls=[]
    )


if __name__ == "__main__":
    try:
        line = sys.stdin.buffer.readline(256 * 1024 + 2)
        if not line.endswith(b"\n") or len(line) > 256 * 1024 + 1:
            raise ValueError("input bound")
        sys.stdout.buffer.write(render(json.loads(line)))
    except Exception:
        # Neither observations nor renderer diagnostics belong in process logs.
        sys.exit(1)
