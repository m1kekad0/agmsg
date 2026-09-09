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

Scoped vs installation-wide classification is by PROJECT presence only:
a record with a non-empty project belongs to that scope; a record with an
empty project is installation-wide (global) and keeps its type. Global
components live in top-level `global_components` (each carrying its own
`type`); `scopes[].project` is therefore always non-empty -- no fake
empty-project scope is ever synthesized.

Store strictness (P1-3): each store file has an exact field width
(scopes 4 / regs 6 / comps 8 / findings 11). Short/long rows are rejected
(rc 2, stdout empty) -- padding/truncation is forbidden. Scoped children
(registrations, scoped components, scoped findings) must belong to an
existing scopes.tsv (project,type); child records never synthesize scopes.
Duplicate scope rows are rejected (rc 2); at minimum conflicting duplicates
are always rejected.

Global opaque instances (P1-6): comps/findings carry a trailing opaque ID
(global_instanceN). Non-empty opaque means {"kind":"opaque","id":...},
distinguishing multiple global components sharing one id. Raw PID/hash/URL/
socket/path never appear as structured instance IDs.
"""
import argparse
import json
import sys


def _read_tsv(path, width, name):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, start=1):
                line = line.rstrip("\n")
                if not line:
                    continue
                # Strict: no newline stripping beyond the terminator (a raw
                # newline inside a field would have split rows already and
                # surfaces here as a width mismatch). CR must not appear
                # (input-boundary rejection in Bash); a stray CR also fails
                # closed here rather than silently surviving.
                if "\r" in line:
                    raise ValueError(
                        f"{name}:{lineno} carries a carriage return")
                parts = line.split("\x1f")
                if len(parts) != width:
                    raise ValueError(
                        f"{name}:{lineno} has {len(parts)} fields, "
                        f"expected {width}")
                rows.append(parts)
    except OSError as exc:
        print(f"agmsg: doctor --json: cannot read scan store ({exc})",
              file=sys.stderr)
        sys.exit(2)
    return rows


def _reject_noscope(row):
    # A scoped-table row (scopes.tsv / registrations.tsv) with an empty
    # project is an internal inconsistency: those tables must always carry
    # a real project. Silently dropping the record could yield rc 0 with
    # diagnosable:true (false healthy), so fail closed via the rc 2 path
    # in _entrypoint() instead.
    raise ValueError(f"scoped record has no project: {row!r}")


def _reject_orphan(kind, row):
    # A scoped child (registration / scoped component / scoped finding)
    # whose (project,type) has no scopes.tsv entry is an internal
    # inconsistency: child records must never synthesize scopes. Fail
    # closed (rc 2) rather than inventing an unknown scope.
    raise ValueError(f"{kind} without scope: {row!r}")


def _reject_duplicate_scope(key):
    raise ValueError(f"duplicate scope: {key!r}")


def _target(kind, team, agent, comp, opaque=""):
    if kind == "registration":
        return {"kind": "registration", "team": team, "agent": agent}
    if kind == "component":
        instance = None
        if opaque:
            instance = {"kind": "opaque", "id": opaque}
        elif team or agent:
            instance = {"kind": "registration", "team": team,
                        "agent": agent}
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

    scope_rows = _read_tsv(args.scopes, 4, "scopes.tsv")
    reg_rows = _read_tsv(args.registrations, 6, "regs.tsv")
    comp_rows = _read_tsv(args.components, 8, "comps.tsv")
    finding_rows = _read_tsv(args.findings, 11, "findings.tsv")

    # Group observations by scope in first-seen order. Only scopes.tsv rows
    # (always carrying a real project) create scopes[] entries; scoped
    # children must reference an existing scope, empty-project records are
    # installation-wide.
    order = []
    regs = {}
    comps = {}
    findings = {}
    delivery = {}
    seen_scopes = set()
    for dproj, stype, mode, dstatus in scope_rows:
        if not dproj:
            _reject_noscope((dproj, stype, mode, dstatus))
        key = (dproj, stype)
        if key in seen_scopes:
            _reject_duplicate_scope(key)
        seen_scopes.add(key)
        order.append(key)
        regs[key] = []
        comps[key] = []
        findings[key] = []
        delivery[key] = {"mode": mode, "status": dstatus}
    for dproj, stype, team, agent, lock, watcher in reg_rows:
        if not dproj:
            _reject_noscope((dproj, stype, team, agent, lock, watcher))
        key = (dproj, stype)
        if key not in delivery:
            _reject_orphan("registration",
                           (dproj, stype, team, agent, lock, watcher))
        regs[key].append({"team": team, "agent": agent, "lock": lock,
                          "watcher": watcher or None})
    # One component object per (scope, id, instance, opaque); signals keep
    # collection order. Empty-project components are installation-wide and
    # collected into global_components (each carrying its own type).
    # Opaque IDs keep distinct underlying instances distinct (P1-6).
    comp_index = {}
    global_comp_index = {}
    global_components = []
    for dproj, stype, comp, iteam, iagent, scode, sstatus, opaque in comp_rows:
        instance = None
        if opaque:
            instance = {"kind": "opaque", "id": opaque}
        elif iteam or iagent:
            instance = {"kind": "registration", "team": iteam,
                        "agent": iagent}
        if not dproj:
            gkey = (stype, comp, iteam, iagent, opaque)
            if gkey not in global_comp_index:
                entry = {"id": comp, "type": stype, "instance": instance,
                         "signals": []}
                global_comp_index[gkey] = entry
                global_components.append(entry)
            global_comp_index[gkey]["signals"].append({"code": scode,
                                                       "status": sstatus})
            continue
        key = (dproj, stype)
        if key not in delivery:
            _reject_orphan("component",
                           (dproj, stype, comp, iteam, iagent,
                            scode, sstatus, opaque))
        ckey = (key, comp, iteam, iagent, opaque)
        if ckey not in comp_index:
            entry = {"id": comp, "instance": instance, "signals": []}
            comp_index[ckey] = entry
            comps[key].append(entry)
        comp_index[ckey]["signals"].append({"code": scode,
                                            "status": sstatus})
    for row in finding_rows:
        (code, kind, category, dproj, stype, tkind, tteam, tagent, tcomp,
         evidence, opaque) = row
        finding = {
            "code": code,
            "kind": kind,
            "category": category,
            "scope": {"project": dproj or None, "type": stype or None},
            "target": _target(tkind, tteam, tagent, tcomp, opaque),
            "evidence": evidence,
        }
        if dproj:
            key = (dproj, stype)
            if key not in delivery:
                _reject_orphan("finding", row)
            findings[key].append(finding)
        else:
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
        "global_components": global_components,
        "global_findings": global_findings,
    }

    sys.stdout.write(json.dumps(payload, sort_keys=True) + "\n")
    if total_findings == 0 and all_diagnosable:
        return 0
    return 1


def _entrypoint():
    # Normalize every unexpected failure to the rc 2 contract (stdout empty,
    # concise human diagnostic on stderr): an uncaught traceback would
    # otherwise exit 1 with no JSON payload, violating the stable ABI.
    # The payload is built fully in memory and written to stdout exactly
    # once, so a failure can never leave a partial JSON document behind.
    try:
        return main()
    except SystemExit as exc:
        # _read_tsv OSError path already exits 2 with stderr; a bare
        # `return` here would turn it into rc 0. Re-raise to preserve it.
        raise
    except Exception as exc:
        print(f"agmsg: doctor --json: serializer failed ({exc})",
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(_entrypoint())
