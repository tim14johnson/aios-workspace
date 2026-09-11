#!/usr/bin/env python3
"""
AiOS Crawl Agent — thin file index submitter for legacy / non-spoke devices.

Usage:
    python3 aios-crawl-agent.py --hub 192.168.1.x:8080 --token YOUR_TOKEN /path/to/crawl

Requirements: Python 3.6+, no third-party packages.
"""

import os
import sys
import json
import time
import uuid
import mimetypes
import argparse
import urllib.request
import urllib.error


def crawl(roots):
    records = []
    for root in roots:
        for dirpath, _, files in os.walk(root):
            for fname in files:
                path = os.path.join(dirpath, fname)
                try:
                    st = os.stat(path)
                    mime, _ = mimetypes.guess_type(path)
                    records.append({
                        "id": str(uuid.uuid4()),
                        "path": path,
                        "size": st.st_size,
                        "modDate": st.st_mtime,
                        "contentType": mime or "application/octet-stream",
                        "nasMoveCandidate": False,
                    })
                except (PermissionError, FileNotFoundError):
                    pass
    return records


def submit(hub_url, token, records, crawl_root, device_id):
    payload = {
        "jobID": str(uuid.uuid4()),
        "crawlRoot": crawl_root,
        "deviceID": device_id,
        "submittedAt": time.time(),
        "records": records,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://{hub_url}/api/file-index",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"Submitted {len(records)} records — HTTP {resp.status}")
    except urllib.error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection failed: {e.reason}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="AiOS thin crawl agent")
    parser.add_argument("--hub", required=True, help="Hub address:port (e.g. 192.168.1.5:8080)")
    parser.add_argument("--token", required=True, help="Bearer auth token from Hub config")
    parser.add_argument("--device", default=os.uname().nodename, help="Device ID (default: hostname)")
    parser.add_argument("paths", nargs="+", help="Paths to crawl")
    args = parser.parse_args()

    print(f"Crawling: {', '.join(args.paths)}")
    records = crawl(args.paths)
    print(f"Found {len(records)} files — submitting to {args.hub}…")
    submit(args.hub, args.token, records, args.paths[0], args.device)


if __name__ == "__main__":
    main()
