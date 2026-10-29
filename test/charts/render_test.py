"""Exercise the pinned native renderer, fonts, and denial of remote data."""

import importlib.util
from pathlib import Path
import struct
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE = importlib.util.spec_from_file_location("chart_renderer", ROOT / "priv/charts/render.py")
renderer = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(renderer)


class RenderTest(unittest.TestCase):
    def spec(self):
        return {
            "title": {"text": "A chart with locally bundled fonts"},
            "width": 680,
            "height": 340,
            "data": {"values": [{"x": "A", "y": 3}, {"x": "B", "y": 5}]},
            "mark": "bar",
            "encoding": {
                "x": {"field": "x", "type": "nominal"},
                "y": {"field": "y", "type": "quantitative"},
            },
            "config": {"font": "IBM Plex Sans"},
        }

    def test_renders_real_png_at_twice_the_chart_resolution(self):
        png = renderer.render(self.spec())
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", png[16:24])
        self.assertGreaterEqual(width, 1360)
        self.assertGreaterEqual(height, 680)
        self.assertLess(len(png), 8 * 1024 * 1024)

    def test_cannot_fetch_data_from_the_network_or_filesystem(self):
        for url in ["http://127.0.0.1:1/private", "file:///etc/passwd"]:
            spec = self.spec()
            spec["data"] = {"url": url}
            with self.assertRaises(ValueError):
                renderer.render(spec)

    def test_font_bytes_are_the_unmodified_bundled_fonts(self):
        import hashlib

        for name, digest in [
            ("IBMPlexSans-Regular.ttf", "975dcda37d80f038dcd143c22e33ca2d97a0cc5a929aace1c749153b0fe1afa5"),
            ("IBMPlexSans-SemiBold.ttf", "a20caf8286023a6a7a85e40b1d2a4ae9fc3e3b1f9eda8f4c542dd4986af67bb1"),
        ]:
            data = (ROOT / "priv/charts/fonts" / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)


if __name__ == "__main__":
    unittest.main()
