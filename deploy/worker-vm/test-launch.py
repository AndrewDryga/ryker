"""Check the connection settings shared by the guest connector and firewall."""

import unittest

from launch import controller_environment


class ControllerSettingsTest(unittest.TestCase):
    def test_private_gateway_uses_the_deployed_host_and_port(self):
        self.assertEqual(
            controller_environment("https://fleet.internal:4322"),
            "RYKER_WORKER_CONTROLLER=https://fleet.internal:4322\n"
            "RYKER_WORKER_HOST=fleet.internal\n"
            "RYKER_WORKER_PORT=4322\n",
        )

    def test_default_https_port(self):
        self.assertIn(
            "RYKER_WORKER_PORT=443\n",
            controller_environment("https://192.0.2.5"),
        )

    def test_rejects_invalid_authorities_and_injection(self):
        for url in (
            "http://fleet.internal",
            "https://fleet.internal:0",
            "https://fleet.internal:65536",
            "https://fleet..internal",
            "https://user@fleet.internal",
            "https://fleet.internal/path",
            "https://fleet.internal:4322;accept",
            "https://fleet.internal\nPORT=22",
        ):
            with self.subTest(url=url), self.assertRaises(SystemExit):
                controller_environment(url)


if __name__ == "__main__":
    unittest.main()
