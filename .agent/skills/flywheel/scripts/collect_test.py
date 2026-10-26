#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("flywheel_collect", Path(__file__).with_name("collect.py"))
COLLECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECT)


class CollectionTest(unittest.TestCase):
    def setUp(self):
        self.window = {"from": "2026-10-01T00:00:00Z", "until": "2026-10-02T00:00:00Z", "cursor": None}

    def test_sentry_includes_resolved_issues_and_follows_only_real_next_pages(self):
        def fetch(_config, _path, parameters):
            self.assertEqual(parameters["query"], "")
            self.assertEqual(parameters["project"], [42])
            return [{"id": "issue", "status": "resolved", "count": "8"}], {
                "Link": '<https://sentry.example/api?cursor=next>; rel="next"; results="true"'}
        with patch.object(COLLECT, "fetch", fetch):
            page = COLLECT.collect({"kind": "sentry", "organization": "example", "projects": [42]}, self.window)
        self.assertFalse(page["complete"])
        self.assertEqual(page["next_cursor"], "next")
        self.assertEqual(page["records"][0]["data"]["status"], "resolved")

    def test_metrics_chunk_time_and_refuse_partial_results(self):
        body = {"status": "success", "data": {"resultType": "matrix", "result": []}}
        with patch.object(COLLECT, "fetch", return_value=(body, {})):
            page = COLLECT.collect({"kind": "prometheus", "queries": ["up"]}, self.window)
        self.assertEqual(json.loads(page["next_cursor"])["from"], "2026-10-01T06:00:00Z")
        self.assertFalse(page["complete"])
        body["warnings"] = ["partial response"]
        with patch.object(COLLECT, "fetch", return_value=(body, {})):
            with self.assertRaisesRegex(ValueError, "incomplete"):
                COLLECT.collect({"kind": "prometheus", "queries": ["up"]}, self.window)

    def test_jsonl_is_period_bounded_and_resume_detects_a_changed_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            rows = [{"at": "2026-10-01T12:00:00Z", "ref": str(index), "data": {"index": index}} for index in range(101)]
            rows.insert(0, {"at": "2026-09-30T12:00:00Z", "ref": "old", "data": {}})
            path.write_text("\n".join(map(json.dumps, rows)))
            config = {"kind": "jsonl", "path": str(path), "coverage_description": "All exported records"}
            page = COLLECT.collect(config, self.window)
            self.assertEqual(len(page["records"]), 100)
            self.assertEqual(page["records"][0]["ref"], "0")
            self.window["cursor"] = page["next_cursor"]
            last = COLLECT.collect(config, self.window)
            self.assertTrue(last["complete"])
            self.assertEqual(len(last["records"]), 1)
            path.write_text(path.read_text() + "\n{}")
            with self.assertRaisesRegex(ValueError, "changed"):
                COLLECT.collect(config, self.window)

    def test_metrics_pagination_preserves_series_and_refuses_mutated_samples(self):
        series = [{"metric": {"id": str(index)}, "values": [[1, "1"]]} for index in range(101)]
        body = {"status": "success", "data": {"resultType": "matrix", "result": series}}
        config = {"kind": "prometheus", "queries": ["up"]}
        with patch.object(COLLECT, "fetch", return_value=(body, {})):
            first = COLLECT.collect(config, self.window)
            self.window["cursor"] = first["next_cursor"]
            body["data"]["result"] = list(reversed(series))
            second = COLLECT.collect(config, self.window)
            identities = [record["ref"] for record in first["records"] + second["records"]]
            self.assertEqual(len(set(identities)), 101)
            series[0]["values"] = [[1, "2"]]
            with self.assertRaisesRegex(ValueError, "changed"):
                COLLECT.collect(config, self.window)

    def test_export_without_a_verified_end_leaves_a_coverage_gap(self):
        config = {"kind": "jsonl", "available_from": self.window["from"]}
        with patch.object(COLLECT, "jsonl", return_value=COLLECT.page([], None, None, "snapshot")):
            result = COLLECT.collect(config, self.window)
        self.assertEqual(result["coverage"], "partial")


if __name__ == "__main__":
    unittest.main()
