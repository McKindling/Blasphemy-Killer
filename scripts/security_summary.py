#!/usr/bin/env python3
"""Print a severity-count table for one security scanner's JSON report.

Used by .github/workflows/security.yml. Counts only: the repository is public
and job summaries are public, so finding details never go in them. Always exits
0; a missing or unreadable report prints a note instead of failing the build.

    security_summary.py <tool> <report.json> [<report.json> ...]
"""
import json
import sys
from collections import Counter

ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO", "UNKNOWN"]
NORMAL = {
    "ERROR": "HIGH", "WARNING": "MEDIUM", "MODERATE": "MEDIUM",
    "INFORMATIONAL": "INFO", "INFORMATION": "INFO", "NOTE": "INFO",
}


def norm(sev) -> str:
    s = str(sev or "UNKNOWN").upper()
    s = NORMAL.get(s, s)
    return s if s in ORDER else "UNKNOWN"


def count(tool: str, data) -> Counter:
    c: Counter = Counter()
    if tool == "pip-audit":
        for dep in data.get("dependencies", []):
            for _ in dep.get("vulns", []):
                c["UNKNOWN"] += 1  # pip-audit does not report severity
    elif tool == "semgrep":
        for r in data.get("results", []):
            c[norm(r.get("extra", {}).get("severity"))] += 1
    elif tool == "gitleaks":
        c["HIGH"] += len(data or [])
    elif tool == "checkov":
        reports = data if isinstance(data, list) else [data]
        for rep in reports:
            for f in rep.get("results", {}).get("failed_checks", []):
                c[norm(f.get("severity"))] += 1
    elif tool == "trivy":
        for res in data.get("Results", []):
            for v in res.get("Vulnerabilities") or []:
                c[norm(v.get("Severity"))] += 1
            for m in res.get("Misconfigurations") or []:
                c[norm(m.get("Severity"))] += 1
            for s in res.get("Secrets") or []:
                c[norm(s.get("Severity"))] += 1
    elif tool == "zizmor":
        for f in data:
            c[norm(f.get("determinations", {}).get("severity"))] += 1
    elif tool == "zap":
        risk = {"3": "HIGH", "2": "MEDIUM", "1": "LOW", "0": "INFO"}
        for site in data.get("site", []):
            for a in site.get("alerts", []):
                c[risk.get(str(a.get("riskcode")), "UNKNOWN")] += 1
    else:
        raise SystemExit(f"unknown tool {tool!r}")
    return c


def main(argv: list[str]) -> None:
    tool, paths = argv[1], argv[2:]
    total: Counter = Counter()
    notes = []
    for p in paths:
        try:
            with open(p) as fh:
                total += count(tool, json.load(fh))
        except (OSError, ValueError) as e:
            notes.append(f"`{p}` unreadable: {type(e).__name__}")
    print(f"### {tool}\n")
    if notes:
        print("\n".join(f"- {n}" for n in notes) + "\n")
    if not total:
        print("No findings." if not notes else "")
        return
    print("| Severity | Count |\n|---|---|")
    for sev in ORDER:
        if total[sev]:
            print(f"| {sev} | {total[sev]} |")


if __name__ == "__main__":
    main(sys.argv)
