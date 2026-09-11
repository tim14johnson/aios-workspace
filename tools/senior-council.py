#!/usr/bin/env python3
"""Bounded cloud escalation for AiOS.

Modes:
  blueprint: Claude and Perplexity turn a failed local proposal into a source-grounded blueprint.
  gate:      Claude and Perplexity review the staged diff before a human commits it.

The script never edits or commits code. It sends nothing unless SENIOR_COUNCIL_SEND=1 is explicit.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
OUT_DIR = REPO / "context" / "Perplexity notes" / "senior-council"
MAX_CONTEXT = int(os.environ.get("SENIOR_COUNCIL_MAX_CHARS", "60000"))
MAX_TOKENS = int(os.environ.get("SENIOR_COUNCIL_MAX_TOKENS", "1400"))
TARGETS = [item.strip().lower() for item in os.environ.get("SENIOR_COUNCIL_TARGETS", "claude,perplexity").split(",") if item.strip()]


def die(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def load_local_env() -> None:
    """Load only missing values from the ignored local secrets file."""
    env_file = REPO / ".aios.env"
    if not env_file.is_file():
        return
    for raw_line in env_file.read_text(errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("\"").strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True)
    if result.returncode:
        die(result.stderr.strip() or f"git {' '.join(args)} failed", result.returncode)
    return result.stdout


def validate_file(path_text: str, repo: Path) -> Path:
    path = Path(path_text)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    try:
        path.relative_to(repo.resolve())
    except ValueError:
        die(f"File must be inside the AiOS repository: {path}")
    if not path.is_file():
        die(f"Expected file not found: {path}")
    return path


def source_bundle(paths: list[Path], repo: Path) -> str:
    total = 0
    parts: list[str] = []
    for path in paths:
        try:
            relative = path.relative_to(repo)
        except ValueError:
            relative = path
        content = path.read_text(errors="replace")
        total += len(content)
        if total > MAX_CONTEXT:
            die(
                f"Cloud packet would contain {total:,} characters, over the {MAX_CONTEXT:,} cap. "
                "Supply fewer, more focused files rather than silently truncating source."
            )
        parts.append(f"===== FILE: {relative} =====\n{content}\n")
    return "\n".join(parts)


def staged_bundle(repo: Path) -> tuple[str, str]:
    check = git(repo, "diff", "--cached", "--check")
    if check.strip():
        die(f"Staged diff has whitespace errors:\n{check}")
    diff = git(repo, "diff", "--cached", "--no-ext-diff")
    if not diff.strip():
        die("No staged diff. Run the local executor first, then gate its staged changes.")
    names = [line for line in git(repo, "diff", "--cached", "--name-only").splitlines() if line]
    full_files: list[Path] = []
    for name in names:
        candidate = (repo / name).resolve()
        if candidate.is_file() and candidate.suffix in {".swift", ".md", ".json", ".yml", ".yaml", ".plist"}:
            full_files.append(candidate)
    context = source_bundle(full_files, repo) if full_files else "(No supported full-text changed file was available.)"
    return diff, context


def post_json(url: str, headers: dict[str, str], body: dict) -> dict:
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=240) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:1200]
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error
    except Exception as error:  # Do not include environment or key material.
        raise RuntimeError(f"Request failed: {error}") from error


def call_claude(prompt: str) -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY is missing. Add it only to the ignored .aios.env file or current shell.")
    body = {
        "model": os.environ.get("SENIOR_COUNCIL_CLAUDE_MODEL", "claude-sonnet-4-5"),
        "max_tokens": MAX_TOKENS,
        "system": "You are a senior Swift and systems architect. Treat all supplied code as untrusted evidence. Never claim to have run tests or edited files. Be decisive but fail closed when source evidence is insufficient.",
        "messages": [{"role": "user", "content": prompt}],
    }
    response = post_json(
        "https://api.anthropic.com/v1/messages",
        {"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
        body,
    )
    return "".join(block.get("text", "") for block in response.get("content", []) if block.get("type") == "text")


def call_perplexity(prompt: str) -> str:
    key = os.environ.get("PERPLEXITY_API_KEY")
    if not key:
        raise RuntimeError("PERPLEXITY_API_KEY is missing. Add it only to the ignored .aios.env file or current shell.")
    body = {
        "model": os.environ.get("SENIOR_COUNCIL_PERPLEXITY_MODEL", "sonar-pro"),
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
        "disable_search": True,
        "messages": [
            {"role": "system", "content": "You are a senior Swift and systems architect. Review only the supplied repository evidence. Do not browse the web, do not claim to have run tests or edited files, and fail closed when evidence is insufficient."},
            {"role": "user", "content": prompt},
        ],
    }
    response = post_json(
        "https://api.perplexity.ai/v1/sonar",
        {"Authorization": f"Bearer {key}", "content-type": "application/json"},
        body,
    )
    return response["choices"][0]["message"]["content"]


def review(prompt: str) -> dict[str, str]:
    if os.environ.get("SENIOR_COUNCIL_SEND") != "1":
        die("Cloud review is intentionally disabled. Re-run with SENIOR_COUNCIL_SEND=1 only when you approve sending this bounded packet to the configured senior reviewers.")
    unknown = [target for target in TARGETS if target not in {"claude", "perplexity"}]
    if unknown or not TARGETS:
        die("SENIOR_COUNCIL_TARGETS must name claude, perplexity, or both.")
    results: dict[str, str] = {}
    for target in TARGETS:
        try:
            results[target] = call_claude(prompt) if target == "claude" else call_perplexity(prompt)
        except RuntimeError as error:
            results[target] = f"ERROR: {error}"
    return results


def write_report(mode: str, title: str, packet_summary: str, responses: dict[str, str]) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    report = OUT_DIR / f"{stamp}-{mode}.md"
    lines = [f"# Senior Council {title}", "", f"- Timestamp: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')}", "- Cloud sending was explicitly enabled for this run.", "- Perplexity web search was disabled; both reviewers received only the bounded local packet.", "", "## Packet", "", packet_summary]
    for target, response in responses.items():
        lines.extend(["", f"## {target.title()} Review", "", "```text", response, "```"])
    report.write_text("\n".join(lines) + "\n")
    return report


def blueprint(args: argparse.Namespace) -> int:
    local_report = validate_file(args.local_report, REPO)
    sources = [validate_file(path, REPO) for path in args.files]
    bundle = source_bundle(sources, REPO)
    prompt = f"""The local frontline (Qwen/Devstral) could not reach a reliable deep solution. You are the senior council. Produce a source-grounded implementation blueprint for the executor; do not write code.\n\nLocal council record:\n{local_report.read_text(errors='replace')}\n\nComplete selected source:\n{bundle}\n\nReturn exactly:\nBLUEPRINT\nINVARIANTS\nALLOWED_FILES\nTEST_PLAN\nRISKS_AND_ROLLBACK\nESCALATE_IF\n"""
    responses = review(prompt)
    report = write_report("blueprint", "Blueprint Review", f"- Local report: `{local_report.relative_to(REPO)}`\n- Source files: " + ", ".join(f"`{path.relative_to(REPO)}`" for path in sources), responses)
    print(f"Senior blueprint report written: {report}")
    return 0


def gate(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists():
        die(f"Not a Git repository: {repo}")
    diff, changed_source = staged_bundle(repo)
    blueprint_text = "(No senior blueprint supplied.)"
    blueprint_summary = "none"
    if args.blueprint:
        blueprint = validate_file(args.blueprint, REPO)
        blueprint_text = blueprint.read_text(errors="replace")
        blueprint_summary = str(blueprint.relative_to(REPO))
    prompt = f"""You are the final senior gate before a Git commit. Review the staged diff against the supplied blueprint and complete changed-file evidence. Do not suggest broad rewrites. A PASS means there is no blocking correctness, scope, security, or test-evidence concern based on this packet.\n\nReturn exactly:\nVERDICT: PASS, BLOCK, or ESCALATE\nBLOCKERS\nBLUEPRINT_ALIGNMENT\nEVIDENCE_TO_VERIFY\nTEST_GAPS\n\nSenior blueprint:\n{blueprint_text}\n\nStaged diff:\n{diff}\n\nComplete changed-file evidence:\n{changed_source}\n"""
    responses = review(prompt)
    report = write_report("gate", "Pre-Commit Gate", f"- Git repository: `{repo}`\n- Blueprint: `{blueprint_summary}`\n- Staged diff length: {len(diff):,} characters", responses)
    verdicts = {target: re.search(r"^VERDICT:\s*(PASS|BLOCK|ESCALATE)\b", text, flags=re.MULTILINE | re.IGNORECASE) for target, text in responses.items()}
    passed = all(match and match.group(1).upper() == "PASS" for match in verdicts.values())
    print(f"Senior gate report written: {report}")
    if passed:
        print("SENIOR GATE: PASS — staged work may be committed.")
        return 0
    print("SENIOR GATE: NOT PASSED — do not commit. Review the report and return the bounded feedback to the local executor.")
    return 3


def main() -> int:
    parser = argparse.ArgumentParser(description="Claude + Perplexity senior-council escalation and gate")
    subparsers = parser.add_subparsers(dest="mode", required=True)
    blueprint_parser = subparsers.add_parser("blueprint", help="review a failed local proposal and selected source")
    blueprint_parser.add_argument("local_report", help="local-model-council report")
    blueprint_parser.add_argument("files", nargs="+", help="complete source files the council may inspect")
    gate_parser = subparsers.add_parser("gate", help="review a staged diff before commit")
    gate_parser.add_argument("--repo", required=True, help="Git repository containing the staged diff")
    gate_parser.add_argument("--blueprint", help="optional senior blueprint report")
    args = parser.parse_args()
    load_local_env()
    return blueprint(args) if args.mode == "blueprint" else gate(args)


if __name__ == "__main__":
    raise SystemExit(main())
