#!/usr/bin/env python3
"""Read one external evidence page. Configuration is local; secrets are environment references."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Source redirected; configure its final origin explicitly")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def timestamp(value):
    at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if at.utcoffset() != timedelta(0):
        raise ValueError("The window must use UTC timestamps")
    return at


def iso(at):
    return at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def fetch(config, path, parameters):
    base = config["url"].rstrip("/")
    parsed = urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Put credentials in the referenced environment variable, never in a URL")
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1")):
        raise ValueError("External sources require HTTPS")
    headers = {"Accept": "application/json"}
    if config.get("token_env"):
        token = os.environ.get(config["token_env"])
        if not token:
            raise ValueError("The configured source credential is unavailable")
        headers["Authorization"] = "Bearer " + token
    request = Request(base + path + "?" + urlencode(parameters, doseq=True), headers=headers)
    with build_opener(NoRedirect()).open(request, timeout=30) as response:
        body = response.read(8_000_001)
        if len(body) > 8_000_000:
            raise ValueError("Source response exceeds 8 MB; narrow its scope or time window")
        return json.loads(body), response.headers


def page(records, cursor, following, query):
    return {"records": records, "cursor": cursor, "next_cursor": following,
            "complete": following is None, "query": query}


def sentry(config, window):
    projects = config.get("projects")
    if not projects:
        raise ValueError("Configure the Ryker Sentry project IDs explicitly")
    path = "/api/0/organizations/" + quote(config["organization"], safe="") + "/issues/"
    parameters = {"project": projects, "query": "", "start": window["from"], "end": window["until"], "limit": 100}
    if window.get("cursor"):
        parameters["cursor"] = window["cursor"]
    issues, headers = fetch(config, path, parameters)
    if not isinstance(issues, list) or len(issues) > 100:
        raise ValueError("Unexpected Sentry issue page")
    following = None
    for link in headers.get("Link", "").split(","):
        if 'rel="next"' in link and 'results="true"' in link:
            target = re.search(r"<([^>]+)>", link)
            if not target:
                raise ValueError("Malformed Sentry pagination")
            following = parse_qs(urlsplit(target.group(1)).query).get("cursor", [None])[0]
            if not following:
                raise ValueError("Sentry omitted its next cursor")
    records = []
    for issue in issues:
        data = {key: issue.get(key) for key in
                ("id", "shortId", "title", "culprit", "level", "status", "count", "userCount", "firstSeen", "lastSeen", "permalink", "project")}
        records.append({"ref": str(issue["id"]), "version": digest(data), "data": data})
    query = "Sentry issue inventory; all statuses; projects=" + ",".join(map(str, projects)) + "; [" + window["from"] + "," + window["until"] + "). Open issue events for stack traces; counts may be lifetime totals."
    return page(records, window.get("cursor"), following, query)


def prometheus(config, window):
    queries = config.get("queries")
    if not isinstance(queries, list) or not queries:
        raise ValueError("Configure explicit PromQL queries for Ryker")
    cursor = json.loads(window["cursor"]) if window.get("cursor") else {"query": 0, "from": window["from"], "offset": 0}
    index, offset = cursor["query"], cursor["offset"]
    start, stop = timestamp(cursor["from"]), timestamp(window["until"])
    end = min(start + timedelta(hours=6), stop)
    step = config.get("step_seconds", 60)
    if not isinstance(step, int) or step < 30:
        raise ValueError("Choose a sampling step of at least 30 seconds")
    body, _headers = fetch(config, "/api/v1/query_range", {
        "query": queries[index], "start": iso(start), "end": iso(end - timedelta(microseconds=1)), "step": step,
    })
    if body.get("status") != "success" or body.get("warnings") or body.get("infos"):
        raise ValueError("Prometheus returned an error or an incomplete/annotated result; inspect it before claiming coverage")
    if body.get("data", {}).get("resultType") != "matrix":
        raise ValueError("Expected a Prometheus range matrix")
    series = sorted(body["data"]["result"], key=lambda result: digest(result["metric"]))
    series_digest = digest(series)
    if offset and cursor.get("series_digest") != series_digest:
        raise ValueError("Prometheus series changed during pagination; retain the coverage gap and retry the window")
    selected = series[offset:offset + 100]
    records = []
    for result in selected:
        data = {"query": queries[index], "from": iso(start), "until": iso(end), "step_seconds": step, "series": result}
        ref = digest({"query": queries[index], "from": iso(start), "until": iso(end), "metric": result["metric"]})
        records.append({"ref": ref, "version": digest(data), "data": data})
    if offset + 100 < len(series):
        following = {**cursor, "offset": offset + 100, "series_digest": series_digest}
    elif end < stop:
        following = {"query": index, "from": iso(end), "offset": 0}
    elif index + 1 < len(queries):
        following = {"query": index + 1, "from": window["from"], "offset": 0}
    else:
        following = None
    if following is not None:
        following = json.dumps(following, sort_keys=True)
    query = "Prometheus queries=" + json.dumps(queries, separators=(",", ":")) + "; 6-hour chunks, step=" + str(step) + "s; missing samples are unknown, not healthy."
    return page(records, window.get("cursor"), following, query)


def jsonl(config, window):
    path = Path(config["path"]).expanduser()
    content = path.read_bytes()
    fingerprint = hashlib.sha256(content).hexdigest()
    cursor = json.loads(window["cursor"]) if window.get("cursor") else {"sha256": fingerprint, "line": 0}
    if cursor["sha256"] != fingerprint:
        raise ValueError("The source file changed during pagination; restore the snapshot or start a fresh source pass")
    records = []
    lines = content.splitlines()
    offset = cursor["line"]
    start, end = timestamp(window["from"]), timestamp(window["until"])
    while offset < len(lines) and len(records) < 100:
        line = lines[offset]
        offset += 1
        if not line.strip():
            continue
        item = json.loads(line)
        at = timestamp(item["at"])
        if start <= at < end:
            data = item["data"]
            records.append({"ref": item["ref"], "version": digest(data), "data": data})
    following = json.dumps({"sha256": fingerprint, "line": offset}, sort_keys=True) if offset < len(lines) else None
    return page(records, window.get("cursor"), following, config["coverage_description"])


def collect(config, window):
    if timestamp(window["from"]) >= timestamp(window["until"]):
        raise ValueError("The source window must be nonempty")
    readers = {"sentry": sentry, "prometheus": prometheus, "jsonl": jsonl}
    result = readers[config["kind"]](config, window)
    available_from = config.get("available_from")
    available_until = config.get("available_until")
    coverage_known = available_from and timestamp(available_from) <= timestamp(window["from"])
    if available_until:
        coverage_known = coverage_known and timestamp(available_until) >= timestamp(window["until"])
    elif config["kind"] == "jsonl":
        coverage_known = False
    if not coverage_known:
        result["coverage"] = "partial"
        result["limitation"] = "The source's retained history has not been verified for the whole requested period."

    if any(len(json.dumps(record["data"]).encode()) > 65_536 for record in result["records"]):
        raise ValueError("An evidence record exceeds 64 KB; split it explicitly instead of truncating")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--window", required=True, help="JSON file with from, until and cursor from the run's progress")
    args = parser.parse_args()
    try:
        config = json.loads(Path(args.config).read_text())[args.source]
        window = json.loads(Path(args.window).read_text())
        print(json.dumps(collect(config, window)))
    except HTTPError as error:
        print("Source HTTP failure: " + str(error.code) + "; retain the coverage gap", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, IndexError, URLError) as error:
        print("External collection failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
