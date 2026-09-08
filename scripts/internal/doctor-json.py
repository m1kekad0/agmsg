#!/usr/bin/env python3
"""Serialize doctor.sh's structured scan store into the stable
`doctor --json` ABI (Issue #8, schema_version 1). See
docs/building-on-agmsg.md for the full field contract.

This helper shapes and escapes only. All diagnosis happens in Bash
(scripts/doctor.sh plus the type plugs under scripts/drivers/types/),
which writes one TSV file per record kind with values already redacted
through the run's single pseudonym table. Unknown finding codes, kinds,
target kinds, component ids, and signal codes/statuses are passed through
untouched -- consumers must tolerate them, and this serializer must never
drop a record it does not recognize.

Exit codes mirror the doctor contract: 0 when there are no findings and
the whole report is fully diagnosable, 1 when a meaningful report was
produced with one or more findings (partial diagnosability included --
every undiagnosable scope carries a diagnostic_failure finding, so it is
always non-empty). stdout carries exactly one JSON payload on 0/1; any
internal failure exits 2 with stdout empty and an explanation on stderr.
"""
import argparse
import json
import sys


def _read_tsv(path, width):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\x1f")
                while len(parts) < width:
                    parts.append("")
                rows.append(parts[:width])
    except OSError as exc:
        print(f"agmsg: doctor --json: cannot read scan store ({exc})",
              file=sys.stderr)
        sys.exit(2)
    return rows


def _target(kind, team, agent, comp):
    if kind == "registration":
        return {"kind": "registration", "team": team, "agent": agent}
    if kind == "component":
        instance = None
        if team or agent:
            instance = {"kind": "registration", "team": team, "agent": agent}
        return {"kind": "component", "component_id": comp,
                "instance": instance}
    if kind:
        # Future additive target kind: keep the raw marker so consumers can
        # tell "targeted at something unknown" apart from "scope-wide".
        return {"kind": kind, "team": team or None, "agent": agent or None,
                "component_id": comp or None}
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scopes", required=True)
    parser.add_argument("--registrations", required=True)
    parser.add_argument("--components", required=True)
    parser.add_argument("--findings", required=True)
    parser.add_argument("--filter-project", default="")
    parser.add_argument("--filter-type", default="")
    parser.add_argument("--filter-team", default="")
    parser.add_argument("--teams", required=True, type=int)
    args = parser.parse_args()

    scope_rows = _read_tsv(args.scopes, 4)
    reg_rows = _read_tsv(args.registrations, 6)
    comp_rows = _read_tsv(args.components, 7)
    finding_rows = _read_tsv(args.findings, 10)

    # Group observations by scope in first-seen order.
    order = []
    regs = {}
    comps = {}
    findings = {}
    delivery = {}
    for dproj, stype, mode, dstatus in scope_rows:
        key = (dproj, stype)
        if key not in delivery:
            order.append(key)
            regs[key] = []
            comps[key] = []
            findings[key] = []
            delivery[key] = {"mode": mode, "status": dstatus}
    for dproj, stype, team, agent, lock, watcher in reg_rows:
        key = (dproj, stype)
        if key not in delivery:
            order.append(key)
            regs[key] = []
            comps[key] = []
            findings[key] = []
            delivery[key] = {"mode": "", "status": "unknown"}
        regs[key].append({"team": team, "agent": agent, "lock": lock,
                          "watcher": watcher or None})
    # One component object per (scope, id, instance); signals keep
    # collection order.
    comp_index = {}
    for dproj, stype, comp, iteam, iagent, scode, sstatus in comp_rows:
        key = (dproj, stype)
        if key not in delivery:
            order.append(key)
            regs[key] = []
            comps[key] = []
            findings[key] = []
            delivery[key] = {"mode": "", "status": "unknown"}
        instance = None
        if iteam or iagent:
            instance = {"kind": "registration", "team": iteam,
                        "agent": iagent}
        ckey = (key, comp, iteam, iagent)
        if ckey not in comp_index:
            entry = {"id": comp, "instance": instance, "signals": []}
            comp_index[ckey] = entry
            comps[key].append(entry)
        comp_index[ckey]["signals"].append({"code": scode,
                                            "status": sstatus})
    for row in finding_rows:
        (code, kind, category, dproj, stype, tkind, tteam, tagent, tcomp,
         evidence) = row
        finding = {
            "code": code,
            "kind": kind,
            "category": category,
            "scope": {"project": dproj or None, "type": stype or None},
            "target": _target(tkind, tteam, tagent, tcomp),
            "evidence": evidence,
        }
        if dproj or stype:
            key = (dproj, stype)
            if key not in delivery:
                order.append(key)
                regs[key] = []
                comps[key] = []
                findings[key] = []
                delivery[key] = {"mode": "", "status": "unknown"}
            findings[key].append(finding)
        else:
            finding["scope"] = {"project": None, "type": stype or None}

            findings.setdefault(None, []).append(finding)

    scopes = []
    total_findings = 0
    all_diagnosable = True
    for key in order:
        dproj, stype = key
        scope_findings = findings.get(key, [])
        diagnosable = all(f["kind"] != "diagnostic_failure"
                          for f in scope_findings)
        # A scope the scan recorded nothing for is trivially diagnosable;
        # anything undiagnosable always carries its diagnostic_failure.
        if not diagnosable:
            all_diagnosable = False
        total_findings += len(scope_findings)
        scopes.append({
            "project": dproj,
            "type": stype,
            "diagnosable": diagnosable,
            "registrations": regs.get(key, []),
            "delivery": delivery.get(key, {"mode": "", "status": "unknown"}),
            "components": comps.get(key, []),
            "findings": scope_findings,
        })

    global_findings = findings.get(None, [])
    total_findings += len(global_findings)
    if any(f["kind"] == "diagnostic_failure" for f in global_findings):
        all_diagnosable = False

    payload = {
        "schema_version": 1,
        "scope": {
            "project": args.filter_project or None,
            "type": args.filter_type or None,
            "team": args.filter_team or None,
        },
        "summary": {
            "teams": args.teams,
            "registrations": sum(len(regs.get(k, [])) for k in order),
            "scopes": len(scopes),
            "findings": total_findings,
        },
        "diagnosable": all_diagnosable,
        "scopes": scopes,
        "global_findings": global_findings,
    }

    sys.stdout.write(json.dumps(payload, sort_keys=True) + "\n")
    if total_findings == 0 and all_diagnosable:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
