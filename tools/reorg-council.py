#!/usr/bin/env python3
"""Off-hours jr-council reorg proposer (proposal-only, gated).

For each doc-folder "chunk" it hands the local capped model the folder's REAL file inventory plus the
repo org standard, and collects archive/merge/rename/refolder proposals. It NEVER moves, renames, deletes,
or edits any file — it only writes proposal + scorecard files under context/reorg-proposals/. Senior
(Claude) reviews and applies approved moves later, under the gate.

Fabrication gate: every path a proposal references must be one of the real files shown to the model;
every RENAME target must satisfy the naming regex. Both are scored per chunk — the deterministic signal
that tests the model's real failure mode (inventing files) on top of the qualitative proposal quality.

Usage:
  python3 tools/reorg-council.py [--only "<folder substring>"] [--model qwen3-coder-32k] [--max-files 40]
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # …/code
PARENT = os.path.dirname(REPO)                                        # …/AiOS Repository
OUT_DIR = os.path.join(REPO, "context", "reorg-proposals")
BASE_URL = os.environ.get("MODEL_BASE_URL", "http://127.0.0.1:11434")

# Doc-folder chunks — bounded units that hold appropriate context. context/memory is the read-only
# mirror and is deliberately excluded.
CHUNKS = [
    os.path.join(PARENT, "docs", "architecture"),
    os.path.join(PARENT, "docs", "SOPs"),
    os.path.join(PARENT, "docs", "requirements"),
    os.path.join(PARENT, "docs", "integration-notes"),
    os.path.join(PARENT, "docs", "conversation context"),
    os.path.join(PARENT, "docs", "build-manual"),
    os.path.join(PARENT, "docs", "Ask Lairry Case Study"),
    os.path.join(REPO, "docs"),
    os.path.join(REPO, "context", "Perplexity notes"),
    os.path.join(REPO, "context", "Tim's-obsidian-notes"),
    os.path.join(REPO, "context", "inbox"),
]

NAMING_RE = re.compile(r"^(\d{8}-)?[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+$")
ACTIONS = {"ARCHIVE", "MERGE", "RENAME", "REFOLDER", "KEEP"}

STANDARD = """AiOS REPO ORG STANDARD (condensed):
- Living spec/contract: kebab-case-topic.md (NO date, it evolves).
- Dated note (research/meeting/point-in-time): YYYYMMDD-kebab-topic.md.
- ARCHIVE a doc ONLY when another file IN THIS LIST clearly supersedes or duplicates it. Being dated is NOT a reason to archive — dated research/meeting notes are KEPT. Default to KEEP unless there is a concrete, specific reason.
- Duplicate/near-duplicate of same concept, or multiple -v1/-v2/-strawman of one idea: MERGE to one.
- File violating the naming rules: RENAME to a conforming name.
- File in the wrong place by kind: REFOLDER to its correct home.
- Forbidden: spaces in NEW names; version suffixes on living specs (git is the version).
- Do NOT invent files. Do NOT change file contents. Moves/renames/archival ONLY."""


def first_heading(path):
    try:
        with open(path, "r", errors="replace") as f:
            for _ in range(15):
                line = f.readline()
                if not line:
                    break
                s = line.strip().lstrip("#").strip()
                if s:
                    return s[:100]
    except Exception:
        pass
    return ""


def inventory(chunk_dir, max_files):
    files = []
    try:
        for name in sorted(os.listdir(chunk_dir)):
            full = os.path.join(chunk_dir, name)
            if os.path.isfile(full) and not name.startswith("."):
                files.append(name)
    except FileNotFoundError:
        return [], "MISSING"
    truncated = ""
    if len(files) > max_files:
        truncated = f"(showing first {max_files} of {len(files)})"
        files = files[:max_files]
    return files, truncated


def build_prompt(chunk_dir, files, truncated):
    rel = os.path.relpath(chunk_dir, PARENT)
    listing = "\n".join(
        f"{i+1}. {n}  —  {first_heading(os.path.join(chunk_dir, n))}"
        for i, n in enumerate(files)
    )
    return f"""{STANDARD}

You are proposing a reorganization for ONE folder: "{rel}" {truncated}

Files in this folder (reference them by EXACT filename as shown):
{listing}

For EACH file, output exactly one line, pipe-delimited, no prose:
ACTION|filename|target|reason
where ACTION is one of ARCHIVE, MERGE, RENAME, REFOLDER, KEEP.
- filename MUST be copied exactly from the list above (never invent one).
- target: for RENAME the new name; for REFOLDER the destination folder; for MERGE the file to merge INTO; for ARCHIVE/KEEP put "-".
- reason: a short phrase.
Output ONLY the lines, one per file shown."""


def call_model(model, prompt, timeout):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0},
    }).encode()
    req = urllib.request.Request(f"{BASE_URL}/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    return data.get("message", {}).get("content", "")


def gate(response, real_files):
    real = set(real_files)
    referenced = fabricated = rename_ok = rename_bad = actions = 0
    for line in response.splitlines():
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4 or parts[0].upper() not in ACTIONS:
            continue
        action, filename, target = parts[0].upper(), parts[1], parts[2]
        actions += 1
        referenced += 1
        if filename not in real:
            fabricated += 1
        if action == "RENAME" and target not in ("-", ""):
            if NAMING_RE.match(target):
                rename_ok += 1
            else:
                rename_bad += 1
    real_pct = 100 * (referenced - fabricated) / referenced if referenced else 100
    renames = rename_ok + rename_bad
    name_pct = 100 * rename_ok / renames if renames else 100
    return {"actions": actions, "fabricated": fabricated,
            "referenced_real_pct": round(real_pct, 1),
            "name_conformance_pct": round(name_pct, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--model", default=os.environ.get("MODEL_ID", "qwen3-coder-32k"))
    ap.add_argument("--max-files", type=int, default=40)
    ap.add_argument("--timeout", type=int, default=240)
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    log_path = os.path.join(OUT_DIR, "_run.log")
    score_path = os.path.join(OUT_DIR, "_scorecard.tsv")
    chunks = [c for c in CHUNKS if args.only.lower() in c.lower()] if args.only else CHUNKS

    def log(msg):
        with open(log_path, "a") as f:
            f.write(msg + "\n")
        print(msg, flush=True)

    if not os.path.exists(score_path):
        with open(score_path, "w") as f:
            f.write("chunk\tactions\tfabricated\treferenced_real_pct\tname_conformance_pct\telapsed_s\n")

    log(f"=== reorg-council start · model={args.model} · {len(chunks)} chunk(s) ===")
    for chunk in chunks:
        rel = os.path.relpath(chunk, PARENT)
        files, truncated = inventory(chunk, args.max_files)
        if truncated == "MISSING" or not files:
            log(f"[skip] {rel} (missing or empty)")
            continue
        prompt = build_prompt(chunk, files, truncated)
        t0 = time.time()
        try:
            response = call_model(args.model, prompt, args.timeout)
        except Exception as e:
            log(f"[error] {rel}: {e}")
            continue
        elapsed = round(time.time() - t0, 1)
        scores = gate(response, files)

        safe = rel.replace(os.sep, "__").replace(" ", "_")
        with open(os.path.join(OUT_DIR, f"{safe}.md"), "w") as f:
            f.write(f"# Reorg proposal — {rel}\n\n"
                    f"*Model: {args.model} · elapsed {elapsed}s · PROPOSAL ONLY (no files moved).*\n\n"
                    f"Gate: {scores['actions']} actions · {scores['fabricated']} fabricated · "
                    f"{scores['referenced_real_pct']}% real files · "
                    f"{scores['name_conformance_pct']}% name-conformant\n\n"
                    f"```\n{response.strip()}\n```\n")
        with open(score_path, "a") as f:
            f.write(f"{rel}\t{scores['actions']}\t{scores['fabricated']}\t"
                    f"{scores['referenced_real_pct']}\t{scores['name_conformance_pct']}\t{elapsed}\n")
        log(f"[ok] {rel}: {scores['actions']} actions, {scores['fabricated']} fabricated, "
            f"{scores['referenced_real_pct']}% real, {elapsed}s")
    log("=== reorg-council done ===")


if __name__ == "__main__":
    main()
