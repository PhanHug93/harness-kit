#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
# Seat configuration for the multi-agent collaboration protocol.
# Seats are the fixed protocol vocabulary (tags); occupants are dynamic data in
# docs/agent-configs/seats.json. Bash only dispatches; one python3 program does
# the JSON work. The program is passed with `python3 -c` so the process keeps
# the caller's stdin (a real terminal stays interactive for `wizard`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SEATS_FILE="${AGENT_SEATS_FILE:-$PROJECT_ROOT/docs/agent-configs/seats.json}"
LEGACY_PROFILES="${AGENT_SEATS_LEGACY_PROFILES:-$PROJECT_ROOT/docs/agent-configs/model-profiles.json}"
AGENTS_MD="${AGENT_SEATS_AGENTS_MD:-$PROJECT_ROOT/AGENTS.md}"
SEATS_PROJECT_ROOT="${AGENT_SEATS_PROJECT_ROOT-$PROJECT_ROOT}"

usage() {
  printf '%s\n' \
    "Usage:" \
    "  scripts/agent-seats.sh show                       # roster + warnings (read-only)" \
    "  scripts/agent-seats.sh validate                   # exit 1 on an invalid assignment (read-only)" \
    "  scripts/agent-seats.sh suggest                    # proposed roster (read-only)" \
    "  scripts/agent-seats.sh wizard [--yes]             # interactive assignment on a TTY; --yes accepts suggestions" \
    "  scripts/agent-seats.sh set <seat|route> --host <claude|codex|gemini|cursor|windsurf|human> \\" \
    "        [--model <id> --effort <e>] [--fallback-model <id> --fallback-effort <e>] [--no-fallback]" \
    "  scripts/agent-seats.sh init                       # create seats.json once (defaults or legacy migration); never overwrites" \
    "  scripts/agent-seats.sh reset                      # rewrite seats.json from bundle defaults (explicit)" \
    "  scripts/agent-seats.sh render                     # refresh the seat roster block in AGENTS.md" \
    "  scripts/agent-seats.sh roster-block               # print the roster block text (for generators)" \
    "  scripts/agent-seats.sh resolve <seat|route>       # 8 lines for launchers: seat tag phase host model effort fallback_model fallback_effort" \
    "  scripts/agent-seats.sh model-info <model>         # 3 lines: host default_effort efforts(space-separated)" \
    "  scripts/agent-seats.sh model-overlap [--quiet] <seat|route> <model>   # comma-separated other seats (build<->gate, build<->verify, verify<->build) whose codex primary model is <model>; empty when none. A fact for @audit, never an authorization; --quiet drops the stderr note and warnings (the launcher warns itself)" \
    "  scripts/agent-seats.sh roster-check <AGENTS.md>   # exit 1 'roster drift' when the roster block differs from render output" \
    "  scripts/agent-seats.sh conflict <seat|route> <effective-model>   # deprecated: prints 1 when model-overlap for @build is non-empty" \
    "" \
    "A packet keeps its own seats in .agents/tasks/<id>/seats.json, copied from the project roster at its first" \
    "tier set; each change is logged with the user's words. A packet without the file follows the project roster." \
    "  scripts/agent-seats.sh show --task <id>          # seats by host, the tier's seats, facts for @audit" \
    "  scripts/agent-seats.sh use project|claude|codex --task <id> --reason TEXT [--by TAG]" \
    "        # project: copy the roster again; claude: every seat but @owner on Claude; codex: every seat but" \
    "        # @owner on Codex (a seat not yet there takes its project occupant on Codex, else @verify's, else @gate's)" \
    "  scripts/agent-seats.sh set <seat> --host <h> [...] --task <id> --reason TEXT [--by TAG]" \
    "  scripts/agent-seats.sh history --task <id>       # the change log, oldest first" \
    "  scripts/agent-seats.sh check <seat> --host claude|codex [--task <id>]   # ok: (0) or STOP: (1)" \
    "  scripts/agent-seats.sh resolve <seat> --task <id> | open-packet | tier-line --task <id> --tier <t> | close-line --task <id>" \
    "        # for the launchers and agent-tier.py; without --task, check uses the only open packet" \
    "" \
    "Seats: @spec @gate @build @verify @audit @owner. Route aliases: planning=@spec coding=@build reviewing=@verify." \
    "Exit codes: 0 ok; 1 invalid input, refused (lock busy, end of input, unwritable) or usage — nothing written;" \
    "            2 seats.json written but the roster was not rendered; 3 roster markers unbalanced (nothing written);" \
    "            130 interrupted (if 'seats.json written' was printed, run render)."
}

fail() {
  printf 'agent-seats: ERROR: %s\n' "$*" >&2
  exit 1
}

# Bash 3.2: read -d '' returns non-zero at EOF, hence the || true.
read -r -d '' SEATS_PY <<'PY' || true
import json
import os
import pathlib
import re
import sys

SEATS_FILE = pathlib.Path(os.environ["SEATS_FILE"])
LEGACY = pathlib.Path(os.environ["LEGACY_PROFILES"])
AGENTS_MD = pathlib.Path(os.environ["AGENTS_MD"])
PROJECT_ROOT_ENV = os.environ.get("AGENT_SEATS_PROJECT_ROOT")
ROSTER_BEGIN = "<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->"
ROSTER_END = "<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->"
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
args = sys.argv[2:]
# model-overlap --quiet: the caller (the launcher) prints its own warning.
QUIET = cmd == "model-overlap" and "--quiet" in args
if QUIET:
    args = [a for a in args if a != "--quiet"]

SCHEMA = "agent-seats/v1"
HOSTS = ("claude", "codex", "gemini", "cursor", "windsurf", "human")
LAUNCHABLE = ("codex",)
# User-facing route names (resolve, set, model-overlap): planning opens @spec.
ROUTE_ALIASES = {"planning": "spec", "coding": "build", "reviewing": "verify"}
# Legacy model-profiles.json route fields: the old planning_* model was the
# pre-coding reviewer, so migration seeds @gate from it.
LEGACY_ROUTE_SEATS = {"planning": "gate", "coding": "build", "reviewing": "verify"}
SEAT_ORDER = ["spec", "gate", "build", "verify", "audit", "owner"]
SEAT_META = {
    "spec": {"tag": "@spec", "phase": "analysis", "duty": "analysis and specification"},
    "gate": {"tag": "@gate", "phase": "technical_review", "duty": "technical gate and plan"},
    "build": {"tag": "@build", "phase": "implementation", "duty": "build from the plan"},
    "verify": {"tag": "@verify", "phase": "verification", "duty": "verification review"},
    "audit": {"tag": "@audit", "phase": "cross_review", "duty": "independent cross-review"},
    "owner": {"tag": "@owner", "phase": "resolution", "duty": "final decision"},
}
# Duty text that earlier kit releases wrote; a seats.json that still carries it
# shows today's text, while a duty the user wrote stays.
KIT_DUTIES = {
    "gate": ("pre-coding technical review (blocking adequacy verdict)",),
    "build": ("bounded implementation",),
    "verify": ("final technical review",),
}
# Grammar: values that travel through launcher interfaces can never contain
# whitespace or delimiters.
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")
EFFORT_RE = re.compile(r"[a-z][a-z0-9_-]*")
OCCUPANT_KEYS = ("model", "effort", "fallback_model", "fallback_effort")


def duty_of(seat, entry):
    duty = entry.get("duty")
    if not duty or duty in KIT_DUTIES.get(seat, ()):
        return SEAT_META[seat]["duty"]
    return duty


def is_model(v):
    return isinstance(v, str) and MODEL_RE.fullmatch(v) is not None


def is_effort(v):
    return isinstance(v, str) and EFFORT_RE.fullmatch(v) is not None
LEGACY_EFFORTS = ["none", "low", "medium", "high", "xhigh", "max"]
LEGACY_ROUTE_KEYS = ("planning_model", "coding_model", "reviewing_model",
                     "planning_fallback_model", "coding_fallback_model", "reviewing_fallback_model")
# The profile the old generator emitted by default. A legacy file equal to it
# carries no user decision, so seat defaults apply instead of migrating it.
LEGACY_BUNDLE_DEFAULT = {"reasoning_effort": "xhigh", "planning_model": "gpt-5.6-sol", "coding_model": "gpt-5.6-luna",
                         "reviewing_model": "gpt-5.6-sol", "planning_fallback_model": "gpt-5.6-terra",
                         "coding_fallback_model": "gpt-5.6-terra", "reviewing_fallback_model": "gpt-5.6-terra"}
DEFAULT_CATALOG = {
    "gpt-6-astra": {"host": "codex", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"], "default_effort": "ultra"},
    "gpt-5.6-luna": {"host": "codex", "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "xhigh"},
    "gpt-5.6-terra": {"host": "codex", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"], "default_effort": "xhigh"},
}
DEFAULT_SEATS = {
    "spec": {"host": "claude"},
    "gate": {"host": "codex", "model": "gpt-6-astra", "effort": "ultra", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "build": {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "verify": {"host": "codex", "model": "gpt-6-astra", "effort": "ultra", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "audit": {"host": "claude"},
    "owner": {"host": "human"},
}


class SeatsError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def out(message=""):
    print(message)


def warn(message):
    print(f"agent-seats: warn: {message}", file=sys.stderr)


def note(message):
    print(f"agent-seats: note: {message}", file=sys.stderr)


def escaped_path(path):
    """Keep refusal diagnostics to one safe, readable physical line."""
    text = str(path)
    result = []
    for char in text:
        code = ord(char)
        if char == "\\":
            result.append("\\\\")
        elif char == "\n":
            result.append("\\n")
        elif char == "\r":
            result.append("\\r")
        elif char == "\t":
            result.append("\\t")
        elif code < 0x20 or 0x7F <= code <= 0x9F:
            result.append(f"\\u{code:04x}")
        else:
            result.append(char)
    return "".join(result)


def configured_root():
    """Return the canonical project root selected for this invocation.

    The explicit root is an interface for generated targets and must be an
    absolute existing directory.  The installed script's own project remains
    the default when the variable is absent.
    """
    if PROJECT_ROOT_ENV is not None:
        if not PROJECT_ROOT_ENV or not os.path.isabs(PROJECT_ROOT_ENV):
            raise SeatsError("AGENT_SEATS_PROJECT_ROOT must be a non-empty absolute existing directory")
        root = pathlib.Path(PROJECT_ROOT_ENV)
    else:
        root = pathlib.Path(os.environ["AGENT_SEATS_PROJECT_ROOT"])
    try:
        root = root.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SeatsError(f"AGENT_SEATS_PROJECT_ROOT is not a usable directory: {escaped_path(exc)}")
    if not root.is_dir():
        raise SeatsError(f"AGENT_SEATS_PROJECT_ROOT is not a directory: {escaped_path(root)}")
    return root


def canonical_destination(path, root):
    """Resolve an intended destination, including a missing final component."""
    raw = pathlib.Path(path)
    if not raw.is_absolute():
        raw = pathlib.Path.cwd() / raw
    try:
        resolved = raw.resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise SeatsError(f"cannot resolve configured destination {escaped_path(raw)}: {escaped_path(exc)}")
    if resolved == root or root not in resolved.parents:
        raise SeatsError(
            f"configured destination outside project root: {escaped_path(raw)} "
            f"(root {escaped_path(root)})"
        )
    return resolved


def check_destinations():
    """Validate both configured write destinations before any project I/O."""
    root = configured_root()
    canonical_destination(SEATS_FILE, root)
    canonical_destination(AGENTS_MD, root)
    return root


def check_destination(path):
    return canonical_destination(path, configured_root())


def clone(value):
    return json.loads(json.dumps(value))


def default_document():
    return {
        "schema": SCHEMA,
        "catalog": {"models": clone(DEFAULT_CATALOG)},
        "seats": {seat: dict(SEAT_META[seat], occupant=clone(DEFAULT_SEATS[seat])) for seat in SEAT_ORDER},
    }


def read_json(path):
    """Return (document, error). error is None when the file parsed."""
    try:
        return json.loads(path.read_text(encoding="utf-8-sig")), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, UnicodeError) as exc:
        return None, f"cannot read {path}: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"malformed JSON in {path}: line {exc.lineno} column {exc.colno}"


def migrate_legacy(doc):
    """Seed codex seats from a valid legacy model-profiles.json.
    Returns (source, notes): source is "legacy" when seats were seeded, or
    "defaults" when the legacy profile equals the old generator default (no user
    decision). Acceptance mirrors the old launcher: all seven v1 keys present,
    model ids and efforts within the grammar, reasoning_effort in the old set.
    Never produces an invalid document: unknown models and efforts are added
    to the catalog explicitly, with a note."""
    legacy, error = read_json(LEGACY)
    if error == "missing":
        return "defaults", []
    if error:
        raise SeatsError(f"legacy model-profiles.json is not usable: {error}")
    if not isinstance(legacy, dict) or legacy.get("schema") != "agent-model-profiles/v1":
        raise SeatsError("legacy model-profiles.json is not agent-model-profiles/v1")
    default_profile = legacy.get("default_profile")
    if not isinstance(default_profile, str) or not default_profile:
        raise SeatsError("legacy model-profiles.json default_profile must be a non-empty string; fix it, or delete the file and run scripts/agent-seats.sh reset")
    profiles = legacy.get("profiles") or {}
    profile = profiles.get(default_profile) if isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        raise SeatsError("legacy model-profiles.json has no usable default profile")
    notes = []
    for key in ("reasoning_effort",) + LEGACY_ROUTE_KEYS:
        value = profile.get(key)
        if not isinstance(value, str) or not value:
            raise SeatsError(f"legacy model-profiles.json: profile '{legacy.get('default_profile')}' is missing required field '{key}'; fix it, or delete the file and run scripts/agent-seats.sh reset")
    base_effort = profile["reasoning_effort"]
    seat_defaults = {}

    def allowed_effort(raw, label, seat, fallback=False):
        """Efforts outside the old launcher set are kept in the diagnostic note
        only; the seat default applies instead of failing the migration."""
        if raw in LEGACY_EFFORTS:
            return raw
        default = DEFAULT_SEATS[seat]
        value = default.get("fallback_effort" if fallback else "effort") or default.get("effort")
        notes.append(f"legacy {label} effort {raw!r} is outside {', '.join(LEGACY_EFFORTS)}; the seat default '{value}' applies")
        return value
    for key in LEGACY_ROUTE_KEYS:
        if not is_model(profile[key]):
            raise SeatsError(f"legacy model-profiles.json: invalid model id for '{key}'")
    extra_effort_keys = [k for k in profile if k.endswith("_reasoning_effort") and k != "reasoning_effort"]
    if not extra_effort_keys and all(profile.get(k) == v for k, v in LEGACY_BUNDLE_DEFAULT.items()):
        return "defaults", ["legacy model-profiles.json equals the old generator default (no user customization); seat defaults apply. seats.json is authoritative; the legacy file can be deleted"]
    models = doc["catalog"]["models"]

    def ensure(model, effort):
        if not is_model(model):
            raise SeatsError(f"legacy model id is not usable: {model!r}")
        if not is_effort(effort):
            raise SeatsError(f"legacy effort is not usable for {model}: {effort!r}")
        spec = models.get(model)
        if spec is None:
            spec = {"host": "codex", "efforts": list(LEGACY_EFFORTS), "default_effort": effort}
            models[model] = spec
            notes.append(f"catalog: added {model} from legacy model-profiles.json (efforts {', '.join(LEGACY_EFFORTS)}; default {effort})")
        if effort not in spec["efforts"]:
            spec["efforts"].append(effort)
            notes.append(f"catalog: {model} gains effort '{effort}' declared by the legacy profile")

    for route, seat in LEGACY_ROUTE_SEATS.items():
        model = profile[f"{route}_model"]
        effort = allowed_effort(profile.get(f"{route}_reasoning_effort", base_effort), f"{route} reasoning_effort", seat)
        ensure(model, effort)
        occ = {"host": "codex", "model": model, "effort": effort}
        fallback = profile[f"{route}_fallback_model"]
        fallback_effort = allowed_effort(profile.get(f"{route}_fallback_reasoning_effort", base_effort), f"{route} fallback reasoning_effort", seat, fallback=True)
        ensure(fallback, fallback_effort)
        occ["fallback_model"] = fallback
        occ["fallback_effort"] = fallback_effort
        doc["seats"][seat]["occupant"] = occ
        notes.append(f"{SEAT_META[seat]['tag']}: seeded from legacy route '{route}'")
    return "legacy", notes


def model_spec(models, mid):
    """Catalog entry for mid, or None when absent or not an object. Callers must
    never dereference a raw catalog value: a hand-edited seats.json can hold a
    string, list or boolean there (gate attempt 3, F2)."""
    if not isinstance(models, dict):
        return None
    spec = models.get(mid)
    return spec if isinstance(spec, dict) else None


def catalog_default_effort(models, mid):
    """Return a catalog default only for a typed model identifier.

    Repair mode intentionally starts from structurally sound but semantically
    invalid documents. Do not pass a hand-edited list/dict/bool through dict
    lookup while rebuilding an occupant; validation below will report it and
    keep the original file untouched.
    """
    if not is_model(mid):
        return None
    spec = model_spec(models, mid)
    return spec.get("default_effort") if spec is not None else None


def validate(doc):
    errors, warnings = [], []
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA}"], warnings
    for key in doc:
        if key not in ("schema", "catalog", "seats"):
            errors.append(f"unknown top-level key {key!r} (allowed: schema, catalog, seats)")
    catalog = doc.get("catalog")
    if isinstance(catalog, dict):
        for key in catalog:
            if key != "models":
                errors.append(f"unknown catalog key {key!r} (allowed: models)")
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, dict) or not models:
        errors.append("catalog.models must be a non-empty object")
        models = {}
    for mid, spec in models.items():
        if not is_model(mid):
            errors.append(f"catalog model id {mid!r} violates the model grammar [A-Za-z0-9][A-Za-z0-9._:/-]*")
            continue
        if not isinstance(spec, dict) or spec.get("host") not in HOSTS:
            errors.append(f"catalog model {mid}: host must be one of {', '.join(HOSTS)}")
            continue
        for key in spec:
            if key not in ("host", "efforts", "default_effort"):
                errors.append(f"catalog model {mid}: unknown key {key!r} (allowed: host, efforts, default_effort)")
        efforts = spec.get("efforts")
        if not isinstance(efforts, list) or not efforts or not all(is_effort(e) for e in efforts):
            errors.append(f"catalog model {mid}: efforts must be a non-empty array matching [a-z][a-z0-9_-]*")
        elif spec.get("default_effort") not in efforts:
            errors.append(f"catalog model {mid}: default_effort must be one of its efforts")
        elif len(set(efforts)) != len(efforts):
            warnings.append(f"catalog model {mid}: efforts lists duplicates")
    seats = doc.get("seats")
    if not isinstance(seats, dict):
        return errors + ["seats must be an object"], warnings
    for seat in seats:
        if seat not in SEAT_ORDER:
            errors.append(f"unknown seat {seat!r} (allowed: {', '.join(SEAT_ORDER)})")
    for seat in SEAT_ORDER:
        entry = seats.get(seat)
        if not isinstance(entry, dict):
            errors.append(f"seat {seat}: missing")
            continue
        meta = SEAT_META[seat]
        for key in entry:
            if key not in ("tag", "phase", "duty", "occupant"):
                errors.append(f"seat {seat}: unknown key {key!r} (allowed: tag, phase, duty, occupant)")
        if entry.get("tag") != meta["tag"] or entry.get("phase") != meta["phase"]:
            errors.append(f"seat {seat}: tag/phase are protocol constants ({meta['tag']}, {meta['phase']})")
        occ = entry.get("occupant")
        if not isinstance(occ, dict):
            errors.append(f"seat {seat}: occupant must be an object")
            continue
        for key in occ:
            if key != "host" and key not in OCCUPANT_KEYS:
                errors.append(f"seat {seat}: unknown occupant key {key!r} (allowed: host, {', '.join(OCCUPANT_KEYS)})")
        host = occ.get("host")
        if host not in HOSTS:
            errors.append(f"seat {seat}: occupant.host must be one of {', '.join(HOSTS)}")
            continue
        if seat == "owner" and host != "human":
            errors.append("seat owner: occupant.host must be human")
        # Every serialized field obeys the grammar whatever the host (resolve emits them all).
        for key in OCCUPANT_KEYS:
            if key in occ and occ[key] is not None and not (is_model(occ[key]) if "model" in key else is_effort(occ[key])):
                errors.append(f"seat {seat}: occupant.{key} {occ[key]!r} violates the grammar")
        if occ.get("fallback_effort") is not None and occ.get("fallback_model") is None:
            errors.append(f"seat {seat}: fallback_effort without fallback_model")
        if host in LAUNCHABLE:
            for key, ekey in (("model", "effort"), ("fallback_model", "fallback_effort")):
                mid = occ.get(key)
                if key == "fallback_model" and mid is None:
                    warnings.append(f"seat {seat}: no fallback model; CODEX_USE_FALLBACK launches will be refused")
                    continue
                if not is_model(mid):
                    errors.append(f"seat {seat}: occupant.{key} is required for host {host} and must match the model grammar")
                    continue
                if mid not in models:
                    errors.append(f"seat {seat}: model {mid} is not in catalog.models")
                    continue
                spec = model_spec(models, mid)
                if spec is None:
                    errors.append(f"seat {seat}: catalog entry for {mid} must be an object, not {type(models.get(mid)).__name__}")
                    continue
                if spec.get("host") != host:
                    errors.append(f"seat {seat}: model {mid} belongs to host {spec.get('host')}, not {host}")
                eff = occ.get(ekey)
                supported = [e for e in (spec.get("efforts") or []) if isinstance(e, str)] if isinstance(spec.get("efforts"), list) else []
                if not isinstance(eff, str) or eff not in supported:
                    errors.append(f"seat {seat}: {ekey} '{eff}' is not supported by {mid} (supported: {', '.join(supported)})")
        elif occ.get("model"):
            warnings.append(f"seat {seat}: host {host} is host-controlled; model '{occ.get('model')}' is informational only")
    def occupant_of(seat):
        entry = seats.get(seat)
        occ = entry.get("occupant") if isinstance(entry, dict) else None
        return occ if isinstance(occ, dict) else {}

    for reviewer in ("gate", "verify"):
        oa = occupant_of(reviewer)
        ob = occupant_of("build")
        if oa.get("host") == "codex" and ob.get("host") == "codex":
            # Primary models only: fallbacks are capacity substitutes, not the
            # review authority, so a shared fallback is not a conflict.
            if oa.get("model") and oa.get("model") == ob.get("model"):
                warnings.append(f"{SEAT_META[reviewer]['tag']} and @build share the primary model {oa.get('model')}: review independence is by session only; a fact for @audit, not an authorization")
    return errors, warnings


OVERLAP_PAIRS = {"build": ("gate", "verify"), "verify": ("build",)}


def model_overlap(doc, seat, model):
    """Other seats whose codex occupant uses `model` as primary model (facts for @audit)."""
    found = []
    for other in OVERLAP_PAIRS.get(seat, ()):
        occ = doc["seats"][other]["occupant"]
        if occ.get("host") == "codex" and occ.get("model") == model:
            found.append(other)
    return found


def roster_check(path):
    p = pathlib.Path(path)
    try:
        data = p.read_bytes().replace(b"\r\n", b"\n")
    except OSError as exc:
        raise SeatsError(f"cannot read {path}: {exc}")
    begin, end = ROSTER_BEGIN.encode("utf-8"), ROSTER_END.encode("utf-8")
    nb, ne = data.count(begin), data.count(end)
    if nb != 1 or ne != 1 or data.index(begin) > data.index(end):
        raise SeatsError(f"seat roster block markers in {path} are missing or unbalanced (BEGIN={nb}, END={ne}); run scripts/agent-seats.sh render")
    return data[data.index(begin):data.index(end) + len(end)]


def occupant_text(occ):
    host = occ.get("host", "?")
    if host in LAUNCHABLE:
        text = f"{host} {occ.get('model')} @ {occ.get('effort')}"
        if occ.get("fallback_model"):
            text += f" (fallback {occ.get('fallback_model')} @ {occ.get('fallback_effort')})"
        else:
            text += " (no fallback)"
        return text
    if host == "human":
        return "human (user)"
    return f"{host} (host-controlled model)"


def roster_lines(doc):
    return [f"- `{doc['seats'][s]['tag']}` · {doc['seats'][s]['phase']} · {occupant_text(doc['seats'][s]['occupant'])}" for s in SEAT_ORDER]


def print_roster(doc, title):
    out(title)
    for line in roster_lines(doc):
        out(line)


def report(errors, warnings):
    for w in warnings:
        warn(w)
    for e in errors:
        print(f"agent-seats: ERROR: {e}", file=sys.stderr)


def write_atomic(path, data):
    """Write bytes via a sibling temp file + rename so readers never see a
    truncated file and a failed write leaves the old content intact."""
    path = pathlib.Path(path)
    check_destination(path)
    path = pathlib.Path(os.path.realpath(path))  # write through symlinks, never replace the link
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    if path.exists() and not os.access(path, os.W_OK):
        # honour a read-only file instead of renaming over it
        raise PermissionError(f"[Errno 13] Permission denied (read-only): '{path}'")
    try:
        mode = path.stat().st_mode & 0o7777 if path.exists() else None
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


SAVED = {"seats": False}


def save(doc):
    check_destination(SEATS_FILE)
    errors, _ = validate(doc)
    if errors:
        report(errors, [])
        raise SeatsError("refusing to write an invalid seats.json")
    try:
        SEATS_FILE.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(SEATS_FILE, (json.dumps(doc, indent=2) + "\n").encode("utf-8"))
    except OSError as exc:
        raise SeatsError(f"cannot write {SEATS_FILE}: {exc}; nothing written")
    SAVED["seats"] = True


def load_current():
    """Current seats.json or a SeatsError with guidance. Legacy is never consulted here."""
    doc, error = read_json(SEATS_FILE)
    if error == "missing":
        raise SeatsError(f"{SEATS_FILE} is missing; run scripts/agent-seats.sh init (or wizard --yes)")
    if error:
        raise SeatsError(f"{error}; fix it by hand or run scripts/agent-seats.sh reset")
    return doc


def structural_errors(doc):
    """Errors that make the document unusable as a starting point for set."""
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA}"]
    seats = doc.get("seats")
    if not isinstance(seats, dict):
        return ["seats must be an object"]
    errs = []
    for seat in SEAT_ORDER:
        entry = seats.get(seat)
        if not isinstance(entry, dict) or not isinstance(entry.get("occupant"), dict):
            errs.append(f"seat {seat}: missing or occupant is not an object")
    catalog = doc.get("catalog")
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, dict):
        errs.append("catalog.models must be an object")
    else:
        for mid, spec in models.items():
            if not isinstance(spec, dict):
                errs.append(f"catalog.models[{mid!r}] must be an object, not {type(spec).__name__}")
    return errs


def proposal(repairing=False):
    """Lifecycle: valid seats.json -> itself; missing -> legacy migration when a
    legacy profile exists, else defaults; malformed seats.json -> error.
    repairing=True (set) accepts a structurally sound but invalid file so the
    result can be validated instead."""
    doc, error = read_json(SEATS_FILE)
    if error is None:
        errors, _ = validate(doc)
        if errors and repairing and not structural_errors(doc):
            for e in errors:
                warn(f"current seats.json: {e}")
            return doc, "current", []
        if errors:
            report(errors, [])
            raise SeatsError("current seats.json is invalid; fix it by hand, repair the offending seat with set, or run reset")
        return doc, "current", []
    if error != "missing":
        raise SeatsError(f"{error}; run scripts/agent-seats.sh reset to start over")
    doc = default_document()
    if LEGACY.exists():
        source, notes = migrate_legacy(doc)
        return doc, source, notes
    return doc, "defaults", []


def render_block_bytes(doc, newline):
    lines = [ROSTER_BEGIN] + roster_lines(doc) + [ROSTER_END]
    return newline.join(lines).encode("utf-8")


def render(doc):
    """Replace exactly one balanced roster block or append one; every byte
    outside the block is preserved. Unbalanced markers -> exit 3, no write."""
    check_destination(AGENTS_MD)
    if not AGENTS_MD.exists():
        raise SeatsError(f"{AGENTS_MD} is missing; cannot render the seat roster")
    if not AGENTS_MD.is_file():
        raise SeatsError(f"{AGENTS_MD} is not a regular file; cannot render the seat roster")
    try:
        data = AGENTS_MD.read_bytes()
    except OSError as exc:
        raise SeatsError(f"cannot read {AGENTS_MD}: {exc}")
    newline = "\r\n" if b"\r\n" in data else "\n"
    begin, end = ROSTER_BEGIN.encode("utf-8"), ROSTER_END.encode("utf-8")
    nb, ne = data.count(begin), data.count(end)
    if nb == 0 and ne == 0:
        section = ("" if data.endswith(newline.encode("utf-8")) or not data else newline) + newline + "## Seat Roster" + newline + newline
        new = data + section.encode("utf-8") + render_block_bytes(doc, newline) + newline.encode("utf-8")
    elif nb == 1 and ne == 1 and data.index(begin) < data.index(end):
        start = data.index(begin)
        stop = data.index(end) + len(end)
        new = data[:start] + render_block_bytes(doc, newline) + data[stop:]
    else:
        raise SeatsError(f"seat roster markers in {AGENTS_MD} are unbalanced (BEGIN={nb}, END={ne}); repair the markers by hand, then rerun render", code=3)
    if new != data:
        try:
            write_atomic(AGENTS_MD, new)
        except OSError as exc:
            raise SeatsError(f"cannot write {AGENTS_MD}: {exc}")
        out("agent-seats: rendered seat roster into AGENTS.md")
    else:
        out("agent-seats: seat roster already current in AGENTS.md")


def write_and_render(doc, title):
    save(doc)
    print_roster(doc, title)
    try:
        render(doc)
    except SeatsError as exc:
        print(f"agent-seats: ERROR: seats.json was written but the roster was NOT rendered: {exc}", file=sys.stderr)
        raise SeatsError(str(exc), code=2)
    except Exception as exc:  # noqa: BLE001 - the configuration is effective; report the stale roster
        print(f"agent-seats: ERROR: seats.json was written but the roster was NOT rendered: {exc}", file=sys.stderr)
        raise SeatsError(str(exc), code=2)


def seat_from_arg(value):
    key = value.lstrip("@")
    key = ROUTE_ALIASES.get(key, key)
    if key not in SEAT_META:
        raise SeatsError(f"unknown seat or route: {value}")
    return key


SET_OPTIONS = ("host", "model", "effort", "fallback_model", "fallback_effort")


def parse_opts(tokens):
    opts = {}
    it = iter(tokens)
    for token in it:
        if token == "--no-fallback":
            opts["no_fallback"] = True
            continue
        if token.startswith("--"):
            key = token[2:].replace("-", "_")
            if key not in SET_OPTIONS:
                raise SeatsError(f"unknown option {token} (see --help)")
            try:
                value = next(it)
            except StopIteration:
                raise SeatsError(f"{token} requires a value")
            if not value or value.startswith("--"):
                raise SeatsError(f"{token} requires a non-empty value")
            opts[key] = value
        else:
            raise SeatsError(f"unexpected argument: {token}")
    if opts.get("no_fallback") and ("fallback_model" in opts or "fallback_effort" in opts):
        raise SeatsError("--no-fallback cannot be combined with --fallback-model/--fallback-effort")
    return opts


NO_ARG_COMMANDS = ("show", "validate", "suggest", "init", "reset", "render", "roster-block")


def validate_command_args():
    """Reject command-specific usage before taking a write lock or reading state."""
    if cmd in NO_ARG_COMMANDS:
        if args:
            raise SeatsError(f"{cmd} takes no arguments (see --help)")
        return
    if cmd == "wizard":
        if args not in ([], ["--yes"]):
            raise SeatsError("wizard accepts only --yes (see --help)")
        return
    if cmd == "set":
        if not args:
            raise SeatsError("set requires a seat")
        seat_from_arg(args[0])
        parse_opts(args[1:])
        return
    if cmd == "resolve":
        if len(args) != 1:
            raise SeatsError("resolve requires exactly one seat or route (see --help)")
        seat_from_arg(args[0])
        return
    if cmd == "model-info":
        if len(args) != 1 or not args[0]:
            raise SeatsError("model-info requires exactly one model id (see --help)")
        return
    if cmd == "roster-check":
        if len(args) != 1 or not args[0]:
            raise SeatsError("roster-check requires exactly one AGENTS.md path (see --help)")
        return
    if cmd in ("conflict", "model-overlap"):
        if len(args) != 2:
            raise SeatsError(f"{cmd} requires exactly a seat and a model (see --help)")
        seat_from_arg(args[0])
        if not is_model(args[1]):
            raise SeatsError(f"{cmd} model must match the model grammar (see --help)")
        return


def ask(prompt, default=""):
    # input(prompt) sends the prompt to stderr on a TTY (CPython stdio readline);
    # write it ourselves so menu and prompt share stdout and `2>/dev/null` cannot hide it.
    sys.stdout.write(prompt)
    sys.stdout.flush()
    try:
        answer = input()
    except EOFError:
        out("")
        raise SeatsError("wizard aborted (end of input); nothing written")
    answer = answer.strip()
    return answer if answer else default


def pick_number(answer, options, what):
    """Enter -> None (keep). A number in range -> index. Anything else -> exit 1."""
    if not answer:
        return None
    if answer.isdigit() and 1 <= int(answer) <= len(options):
        return int(answer) - 1
    raise SeatsError(f"invalid {what} choice {answer!r}: enter a number 1-{len(options)} or press Enter; nothing written")


def interactive_wizard(doc):
    models = doc["catalog"]["models"]
    codex_models = [m for m in models if (model_spec(models, m) or {}).get("host") == "codex"]
    host_map = {"1": "claude", "2": "codex", "3": "gemini", "4": "cursor", "5": "windsurf"}
    for seat in SEAT_ORDER:
        entry = doc["seats"][seat]
        occ = entry["occupant"]
        out("")
        out(f"{entry['tag']} — {duty_of(seat, entry)} (phase {entry['phase']})")
        out(f"  suggestion: {occupant_text(occ)}")
        if seat == "owner":
            out("  @owner is always the human user.")
            continue
        out("  hosts: 1) claude  2) codex  3) gemini  4) cursor  5) windsurf   [Enter = keep suggestion]")
        choice = ask("  host> ")
        if choice and choice not in host_map:
            raise SeatsError(f"invalid host choice {choice!r}: enter a number 1-5 or press Enter; nothing written")
        if choice in host_map and host_map[choice] != occ.get("host"):
            new_host = host_map[choice]
            if new_host == "codex":
                if not codex_models:
                    raise SeatsError("the catalog has no codex model; add one to catalog.models in docs/agent-configs/seats.json (no command edits the catalog). Nothing written")
                default = DEFAULT_SEATS[seat]
                if default.get("host") == "codex" and default["model"] in models and default.get("fallback_model", default["model"]) in models:
                    occ = clone(default)
                else:
                    occ = {"host": "codex", "model": codex_models[0], "effort": (model_spec(models, codex_models[0]) or {}).get("default_effort")}
            else:
                occ = {"host": new_host}
            entry["occupant"] = occ
        if entry["occupant"].get("host") != "codex":
            continue
        occ = entry["occupant"]
        for i, m in enumerate(codex_models, 1):
            spec = model_spec(models, m) or {}
            out(f"    {i}) {m}  efforts: {', '.join(spec['efforts'])}  default: {spec['default_effort']}")
        pick = pick_number(ask(f"  model [{occ.get('model')}]> "), codex_models, "model")
        if pick is not None:
            m = codex_models[pick]
            if m != occ.get("model"):
                occ["model"] = m
                occ["effort"] = (model_spec(models, m) or {}).get("default_effort")
        eff = ask(f"  effort [{occ.get('effort')}]> ")
        if eff:
            occ["effort"] = eff
        fb = ask(f"  fallback model number, or 'none' [{occ.get('fallback_model') or 'none'}]> ")
        if fb == "none":
            occ.pop("fallback_model", None)
            occ.pop("fallback_effort", None)
        elif pick_number(fb, codex_models, "fallback model") is not None:
            m = codex_models[int(fb) - 1]
            if m != occ.get("fallback_model"):
                occ["fallback_model"] = m
                occ["fallback_effort"] = (model_spec(models, m) or {}).get("default_effort")
        if occ.get("fallback_model"):
            fbe = ask(f"  fallback effort [{occ.get('fallback_effort')}]> ")
            if fbe:
                occ["fallback_effort"] = fbe
        errors, warnings = validate(doc)
        seat_errors = [e for e in errors if e.startswith(f"seat {seat}:")]
        if seat_errors:
            report(seat_errors, [])
            raise SeatsError("choice rejected; nothing written. Rerun the wizard")
    return doc


LOCK_FD = None


def lock_for_write(wait_seconds=10.0):
    """One writer at a time: set/wizard/init/reset/render read-modify-write
    seats.json and AGENTS.md. flock on the config directory itself (no lock
    file, so ownership never matters); bounded wait instead of blocking behind
    an interactive wizard; a filesystem without flock only costs a warning."""
    global LOCK_FD
    import fcntl
    import time
    check_destinations()
    try:
        SEATS_FILE.parent.mkdir(parents=True, exist_ok=True)
        LOCK_FD = os.open(str(SEATS_FILE.parent), os.O_RDONLY)
    except OSError as exc:
        raise SeatsError(f"cannot open {SEATS_FILE.parent} for locking: {exc}")
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
            check_destinations()
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SeatsError(f"another agent-seats write is in progress on {SEATS_FILE.parent} (waited {wait_seconds:.0f}s); retry")
            time.sleep(0.05)
        except OSError as exc:  # e.g. ENOLCK/EOPNOTSUPP on a network filesystem
            warn(f"cannot lock {SEATS_FILE.parent} ({exc}); continuing without a lock")
            return


def occupant_for(doc, seat, opts):
    """The occupant `set` writes for a seat of doc, from its options."""
    prev = doc["seats"][seat]["occupant"]
    host = opts.get("host") or prev.get("host")
    occ = {"host": host}
    if host not in LAUNCHABLE:
        inapplicable = [k for k in ("model", "effort", "fallback_model", "fallback_effort", "no_fallback") if k in opts]
        if inapplicable:
            raise SeatsError(f"host {host} is host-controlled; {', '.join('--' + k.replace('_', '-') for k in inapplicable)} do not apply; nothing written")
    if host in LAUNCHABLE:
        if "fallback_effort" in opts and not (opts.get("fallback_model") or prev.get("fallback_model")):
            raise SeatsError("--fallback-effort requires a fallback model; nothing written")
        models = doc["catalog"]["models"]
        occ["model"] = opts.get("model", prev.get("model"))
        if "effort" in opts:
            occ["effort"] = opts["effort"]
        elif prev.get("model") == occ["model"] and prev.get("effort"):
            occ["effort"] = prev["effort"]
        else:
            occ["effort"] = catalog_default_effort(models, occ["model"])
        if not opts.get("no_fallback"):
            fb = opts.get("fallback_model", prev.get("fallback_model"))
            if fb:
                occ["fallback_model"] = fb
                if "fallback_effort" in opts:
                    occ["fallback_effort"] = opts["fallback_effort"]
                elif prev.get("fallback_model") == fb and prev.get("fallback_effort"):
                    occ["fallback_effort"] = prev["fallback_effort"]
                else:
                    occ["fallback_effort"] = catalog_default_effort(models, fb)
    return occ


PACKET_SCHEMA = "agent-packet-seats/v1"
PACKET_KEYS = ("schema", "task", "seats", "history")
HISTORY_KEYS = ("at", "by", "change", "from", "to", "reason")
TASK_ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
BY_RE = re.compile(r"user|@[a-z][a-z0-9-]*")
PRESETS = ("project", "claude", "codex")
# The seats a tier's flow uses (the seat contracts' "Flow by tier").
TIER_SEATS = {"small": ("spec", "build"), "medium": ("spec", "build", "verify"),
              "large": ("spec", "gate", "build", "verify", "audit")}
HOST_NAMES = {"claude": "Claude", "codex": "Codex", "human": "You"}
PACKET_COMMANDS = ("use", "history", "check", "open-packet", "tier-line", "close-line")


def take_opts(tokens, names):
    """Pull `--name value` pairs for the given names; the other tokens keep their order."""
    opts, rest, it = {}, [], iter(tokens)
    for token in it:
        key = token[2:].replace("-", "_") if token.startswith("--") else None
        if key not in names:
            rest.append(token)
            continue
        try:
            value = next(it)
        except StopIteration:
            raise SeatsError(f"{token} requires a value")
        if key in opts:
            raise SeatsError(f"{token} is given twice")
        opts[key] = value
    return opts, rest


def tasks_dir():
    return configured_root() / ".agents" / "tasks"


def task_folder(task):
    if task == "active" or not TASK_ID.fullmatch(task or ""):
        raise SeatsError(f"task id must be lowercase letters, digits and single dashes, like fix-logout (got: {task!r})")
    return tasks_dir() / task


def utc_now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def packet_closed(folder):
    for name in ("tier.json", "state.json"):
        doc, error = read_json(folder / name)
        if error is None and isinstance(doc, dict) and doc.get("status") == "closed":
            return True
    return False


def open_packets():
    """Packets whose state.json is readable and not closed, by name."""
    root = tasks_dir()
    if not root.is_dir():
        return []
    found = []
    for folder in sorted(p for p in root.iterdir() if p.is_dir() and TASK_ID.fullmatch(p.name)):
        doc, error = read_json(folder / "state.json")
        if error is None and isinstance(doc, dict) and doc.get("status") != "closed":
            found.append(folder.name)
    return found


def project_doc():
    doc = load_current()
    errors, _ = validate(doc)
    if errors:
        report(errors, [])
        raise SeatsError("the project seats.json is invalid; run scripts/agent-seats.sh validate")
    return doc


def as_roster(project, occupants):
    """The project document with the packet's occupants, for validate() and the printers."""
    doc = clone(project)
    for seat in SEAT_ORDER:
        doc["seats"][seat]["occupant"] = clone(occupants[seat])
    return doc


def read_packet(task, project):
    """(document or None when the packet has no seats file, path)."""
    path = task_folder(task) / "seats.json"
    if path.is_symlink():
        raise SeatsError(f"{path} is a link; a packet's seats file must be a plain file")
    doc, error = read_json(path)
    if error == "missing":
        return None, path
    repair = f"; scripts/agent-seats.sh use project --task {task} --reason TEXT rewrites it from the project roster"
    if error:
        raise SeatsError(error + repair)
    if not isinstance(doc, dict) or doc.get("schema") != PACKET_SCHEMA:
        raise SeatsError(f"{path}: schema must be {PACKET_SCHEMA}{repair}")
    problems = []
    if sorted(doc) != sorted(PACKET_KEYS):
        problems.append(f"the keys must be {', '.join(PACKET_KEYS)}")
    if doc.get("task") != task:
        problems.append(f"task must be {task}")
    seats = doc.get("seats")
    # Only the shape is required here: a catalog change must not lock a packet
    # (use project repairs it); occupants are checked on a change and at launch.
    if not isinstance(seats, dict) or sorted(seats) != sorted(SEAT_ORDER) or \
            not all(isinstance(v, dict) for v in seats.values()):
        problems.append(f"seats must hold one occupant for each of {', '.join(SEAT_ORDER)}")
    history = doc.get("history")
    if not isinstance(history, list) or not all(history_entry_ok(e) for e in history):
        problems.append(f"history must be a list of entries with {', '.join(HISTORY_KEYS)}: text in at, by, change "
                        "and reason, seat occupants in to, and null or seat occupants in from")
    if problems:
        raise SeatsError(f"{path} is invalid: " + "; ".join(problems) + repair)
    return doc, path


def history_entry_ok(entry):
    def occupants(value):
        return isinstance(value, dict) and all(isinstance(v, dict) for v in value.values())
    return (isinstance(entry, dict) and sorted(entry) == sorted(HISTORY_KEYS)
            and all(isinstance(entry[k], str) for k in ("at", "by", "change", "reason"))
            and occupants(entry["to"]) and (entry["from"] is None or occupants(entry["from"])))


def effective(task, project):
    """(occupants, packet document or None) for a task, or the project roster.
    A task with no packet folder yet (a new task) follows the project roster."""
    if task and task_folder(task).is_dir():
        doc, _ = read_packet(task, project)
        if doc is not None:
            return doc["seats"], doc
    return {s: project["seats"][s]["occupant"] for s in SEAT_ORDER}, None


def lock_packet(folder, wait_seconds=10.0):
    """Exclusive flock on the packet folder, the lock agent-tier.py takes."""
    import errno
    import fcntl
    import time
    try:
        fd = os.open(str(folder), os.O_RDONLY)
    except OSError as exc:
        raise SeatsError(f"cannot open {folder} for locking: {exc.strerror}")
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                warn(f"cannot lock {folder} ({exc.strerror}); continuing without a lock")
                return fd
            if time.monotonic() >= deadline:
                raise SeatsError(f"another command still holds the packet {folder.name}; try again")
            time.sleep(0.05)


def snapshot(task, project, by, reason):
    occupants = {s: clone(project["seats"][s]["occupant"]) for s in SEAT_ORDER}
    return {"schema": PACKET_SCHEMA, "task": task, "seats": occupants,
            "history": [{"at": utc_now(), "by": by, "change": "snapshot", "from": None,
                         "to": clone(occupants), "reason": reason}]}


def write_packet(path, doc):
    try:
        write_atomic(path, (json.dumps(doc, indent=2) + "\n").encode("utf-8"))
    except OSError as exc:
        raise SeatsError(f"cannot write {path}: {exc}; nothing written")


def occ_short(occ):
    host = occ.get("host", "?")
    return f"{host} ({occ.get('model')})" if host in LAUNCHABLE else host


def grouped(occupants):
    order = ["claude", "codex"] + [h for h in HOSTS if h not in ("claude", "codex", "human")] + ["human"]
    lines = []
    for host in order:
        seats = [s for s in SEAT_ORDER if occupants[s].get("host") == host]
        if seats:
            names = [f"@{s} ({occupants[s].get('model')} {occupants[s].get('effort')})" if host in LAUNCHABLE else f"@{s}"
                     for s in seats]
            lines.append(f"{HOST_NAMES.get(host, host)}: {' '.join(names)}")
    return lines


def tier_line(tier, occupants):
    line = f"Seats for {tier}: " + " → ".join(f"@{s} {occ_short(occupants[s])}" for s in TIER_SEATS[tier])
    return line + (", which plans, builds and verifies" if tier == "small" else "")


def facts(project, occupants):
    """Independence facts for @audit; they never block."""
    build = occupants["build"]
    same = [r for r in ("gate", "verify", "audit") if occupants[r].get("host") == build.get("host")]
    items = []
    if same:
        items.append(f"same_host @build {' '.join('@' + r for r in same)} ({build.get('host')})")
    if build.get("host") == "codex" and build.get("model"):
        overlap = model_overlap(as_roster(project, occupants), "build", build["model"])
        if overlap:
            items.append(f"model_overlap @build {' '.join('@' + o for o in overlap)}")
    return items


def preset_occupants(name, task, current, project):
    if name == "project":
        return {s: clone(project["seats"][s]["occupant"]) for s in SEAT_ORDER}
    result = {s: clone(current[s]) for s in SEAT_ORDER}
    if name == "claude":
        for s in SEAT_ORDER:
            if s != "owner":
                result[s] = {"host": "claude"}
        return result
    donor = next((clone(project["seats"][s]["occupant"]) for s in ("verify", "gate")
                  if project["seats"][s]["occupant"].get("host") == "codex"), None)
    for s in SEAT_ORDER:
        if s == "owner" or result[s].get("host") == "codex":
            continue
        if project["seats"][s]["occupant"].get("host") == "codex":
            result[s] = clone(project["seats"][s]["occupant"])
            continue
        if donor is None:
            raise SeatsError(f"the codex preset needs a Codex model for @{s}, and the project has neither @verify nor "
                             f"@gate on Codex; set it: scripts/agent-seats.sh set {s} --host codex --model <id> "
                             f"--task {task} --reason TEXT")
        result[s] = clone(donor)
    return result


def change_packet(task, by, reason, describe, compute):
    """Load (or snapshot) the packet under its lock, apply compute(current, project),
    append one history entry when anything changed, and write."""
    folder = task_folder(task)
    if not folder.is_dir():
        raise SeatsError(f"task {task} has no packet ({folder}); start it with scripts/agent-guard.sh tier set")
    if not reason.strip():
        raise SeatsError("--reason needs the user's words")
    if not BY_RE.fullmatch(by):
        raise SeatsError(f"--by must be user or a seat tag like @spec (got: {by!r})")
    lock_packet(folder)
    if packet_closed(folder):
        raise SeatsError(f"task {task} is closed; its seats no longer change")
    project = project_doc()
    try:
        doc, path = read_packet(task, project)
    except SeatsError:
        path = folder / "seats.json"
        if describe != "preset project" or path.is_symlink():
            raise
        return repair_packet(task, path, project, by, reason)
    if doc is None:
        doc = snapshot(task, project, by, "first change")
    current = doc["seats"]
    new = compute(current, project)
    errors, warnings = validate(as_roster(project, new))
    report(errors, warnings)
    if errors:
        raise SeatsError("the arrangement is invalid; nothing written")
    moved = [s for s in SEAT_ORDER if not same_seat(current[s], new[s])]
    frm = {s: current[s] for s in moved}
    to = {s: new[s] for s in moved}
    if not to:
        out(f"agent-seats: packet {task} already has that arrangement; nothing written")
        return 0
    doc["seats"] = new
    doc["history"].append({"at": utc_now(), "by": by, "change": describe, "from": clone(frm), "to": clone(to), "reason": reason})
    write_packet(path, doc)
    out(f"Packet {task} seats ({describe}):")
    for line in grouped(new):
        out(f"- {line}")
    note("record the user's decision in the packet's user-decision.md")
    return 0


def repair_packet(task, path, project, by, reason):
    """use project on a broken packet file: keep it aside and start a new trail."""
    kept = path.with_name("seats.json.broken-" + utc_now().replace(":", "").replace("-", ""))
    try:
        os.replace(path, kept)
    except OSError as exc:
        raise SeatsError(f"cannot move {path} aside: {exc}; nothing written")
    doc = snapshot(task, project, by, reason)
    doc["history"][0]["change"] = "repair"
    write_packet(path, doc)
    out(f"Packet {task} seats (repaired from the project roster; the broken file is {kept.name}):")
    for line in grouped(doc["seats"]):
        out(f"- {line}")
    note("record the user's decision in the packet's user-decision.md")
    return 0


def same_seat(one, other):
    """Equal as a launcher reads them: a host-controlled seat is its host only."""
    def shape(occ):
        if occ.get("host") not in LAUNCHABLE:
            return {"host": occ.get("host")}
        return {k: v for k, v in occ.items() if v is not None}
    return shape(one) == shape(other)


def history_line(entry):
    details = ", ".join(f"@{s} {occ_short((entry['from'] or {}).get(s, {}))} -> {occ_short(occ)}"
                        for s, occ in entry["to"].items()) if entry["from"] is not None else "from the project roster"
    return f"{entry['at']} {entry['by']} {entry['change']}: {entry['reason']} ({details})"


def packet_main():
    task_opts = ("task", "reason", "by", "tier", "host") if cmd == "check" else ("task", "reason", "by", "tier")
    opts, rest = take_opts(args, task_opts)
    task = opts.get("task")
    if cmd == "open-packet":
        if rest or opts:
            raise SeatsError("open-packet takes no arguments")
        found = open_packets()
        if len(found) == 1:
            out(found[0])
        elif len(found) > 1:
            note(f"several open packets ({', '.join(found)}); pass --task <id> to use a packet's seats")
        return 0
    if cmd == "check":
        if len(rest) != 1 or opts.get("host") not in ("claude", "codex"):
            raise SeatsError("check needs a seat and --host claude|codex (see --help)")
        seat, host = seat_from_arg(rest[0]), opts["host"]
        if not task:
            # The launcher's rule: the only open packet, else the project roster.
            found = open_packets()
            task = found[0] if len(found) == 1 else None
            if len(found) > 1:
                out(f"note: several open packets ({', '.join(found)}); pass --task <id> to follow a packet's seats")
        project = project_doc()
        occupants, doc = effective(task, project)
        has_packet = bool(task) and task_folder(task).is_dir()
        if task and not has_packet:
            where = f"the project roster (no packet {task} yet)"
        else:
            where = f"packet {task}" if task else "the project roster"
        occ = occupants[seat]
        if occ.get("host") == host:
            out(f"ok: @{seat} sits on {host} for {where}")
            return 0
        if occ.get("host") == "codex":
            there = f"open it with .codex/codex-mode.sh @{seat}" + (f" --task {task}" if task else "")
        else:
            there = f"open it on {occ.get('host')}"
        # A packet change needs the packet folder; before it exists only the project roster moves.
        move = (f"scripts/agent-seats.sh set {seat} --host {host}" + (" --model <id>" if host in LAUNCHABLE else "")
                + (f' --task {task} --reason "<your words>"' if has_packet else ""))
        out(f"STOP: @{seat} sits on {occ_short(occ)} for {where}, not on {host}; {there}, or move it with {move}")
        return 1
    if not task:
        raise SeatsError(f"{cmd} needs --task <id> (see --help)")
    task_folder(task)
    if cmd == "model-overlap":
        if len(rest) != 2 or not is_model(rest[1]):
            raise SeatsError("model-overlap requires a seat and a model (see --help)")
        project = project_doc()
        occupants, _ = effective(task, project)
        overlap = model_overlap(as_roster(project, occupants), seat_from_arg(rest[0]), rest[1])
        if overlap:
            out(",".join(overlap))
        return 0
    if cmd == "resolve":
        if len(rest) != 1:
            raise SeatsError("resolve requires exactly one seat or route (see --help)")
        seat = seat_from_arg(rest[0])
        occupants, _ = effective(task, project_doc())
        occ = occupants[seat]
        for value in (seat, SEAT_META[seat]["tag"], SEAT_META[seat]["phase"], occ.get("host", ""), occ.get("model") or "",
                      occ.get("effort") or "", occ.get("fallback_model") or "", occ.get("fallback_effort") or ""):
            out(value)
        return 0
    if cmd in ("show", "history", "close-line"):
        if rest:
            raise SeatsError(f"{cmd} takes only --task (see --help)")
        project = project_doc()
        occupants, doc = effective(task, project)
        if cmd == "history":
            if doc is None:
                out(f"Packet {task} has no seats file; it follows the project roster.")
            for entry in (doc or {}).get("history", []):
                out(history_line(entry))
            return 0
        changes = len(doc["history"]) - 1 if doc else 0
        if cmd == "close-line":
            source = "" if doc else " (the project roster)"
            out(f"Seats at close{source}: " + " · ".join(grouped(occupants)) + f" ({changes} change{'' if changes == 1 else 's'})")
            return 0
        out(f"Packet {task} seats:" if doc else f"Packet {task} follows the project roster (no seats file yet):")
        for error in validate(as_roster(project, occupants))[0] if doc else []:
            warn(f"packet {task}: {error}; scripts/agent-seats.sh use project --task {task} repairs it")
        for line in grouped(occupants):
            out(f"- {line}")
        tier_doc, error = read_json(task_folder(task) / "tier.json")
        tier = tier_doc.get("declared") if error is None and isinstance(tier_doc, dict) else None
        if tier in TIER_SEATS:
            out(tier_line(tier, occupants))
        found = facts(project, occupants)
        out("Facts for @audit: " + ("; ".join(found) if found else "none"))
        out(f"Changes: {changes} (scripts/agent-seats.sh history --task {task})")
        return 0
    if cmd == "tier-line":
        if rest or opts.get("tier") not in TIER_SEATS:
            raise SeatsError("tier-line needs --task <id> --tier small|medium|large")
        folder = task_folder(task)
        if not folder.is_dir():
            raise SeatsError(f"task {task} has no packet ({folder})")
        by = opts.get("by", "user")
        lock_packet(folder)
        project = project_doc()
        doc, path = read_packet(task, project)
        if doc is None and not packet_closed(folder):
            doc = snapshot(task, project, by if BY_RE.fullmatch(by) else "user", "first tier set")
            write_packet(path, doc)
        occupants = doc["seats"] if doc else {s: project["seats"][s]["occupant"] for s in SEAT_ORDER}
        out(tier_line(opts["tier"], occupants))
        # Who codes is the user's choice per task: say how to move @build.
        build_host = occupants["build"].get("host")
        other = "claude" if build_host == "codex" else "codex --model <id>"
        out(f"@build codes on {build_host}; the user can move it: scripts/agent-seats.sh set build --host {other} "
            f"--task {task} --reason \"<the user's words>\"")
        return 0
    if cmd == "use":
        if len(rest) != 1 or rest[0] not in PRESETS:
            raise SeatsError(f"use needs one preset: {', '.join(PRESETS)}")
        if "reason" not in opts:
            raise SeatsError("use --task needs --reason with the user's words")
        preset = rest[0]
        return change_packet(task, opts.get("by", "user"), opts["reason"], f"preset {preset}",
                             lambda current, project: preset_occupants(preset, task, current, project))
    if cmd == "set":
        if not rest:
            raise SeatsError("set requires a seat")
        seat = seat_from_arg(rest[0])
        set_opts = parse_opts(rest[1:])
        if "reason" not in opts:
            raise SeatsError("set --task needs --reason with the user's words")

        def compute(current, project):
            new = {s: clone(current[s]) for s in SEAT_ORDER}
            new[seat] = occupant_for(as_roster(project, current), seat, set_opts)
            return new
        return change_packet(task, opts.get("by", "user"), opts["reason"], f"seat {seat}", compute)
    raise SeatsError(f"{cmd} does not take --task")


def main():
    if cmd in PACKET_COMMANDS or (cmd in ("show", "set", "resolve", "model-overlap") and "--task" in args):
        return packet_main()
    if cmd == "set" and any(a in ("--reason", "--by") for a in args):
        raise SeatsError("--reason and --by go with --task <id>")
    validate_command_args()
    if cmd in ("render", "set", "wizard", "reset", "init"):
        check_destinations()
    if cmd in ("set", "wizard", "reset", "render"):
        lock_for_write()
    if cmd == "suggest":
        doc, source, notes = proposal()
        print_roster(doc, {"current": "Current seats (seats.json):", "legacy": "Suggested seats (migrated from model-profiles.json):", "defaults": "Suggested seats (bundle defaults):"}[source])
        for n in notes:
            note(n)
        return 0
    if cmd == "reset":
        doc = default_document()
        write_and_render(doc, "seats.json reset to bundle defaults:")
        return 0
    if cmd == "init":
        def init_precheck(appeared):
            """True when a file is already there and valid. Raises on anything
            present but unusable. Only a 'missing' result may create the file,
            and the fast path and the post-lock recheck apply the same rules
            (gate attempt 3, F1: a file that appeared during the wait was
            overwritten with defaults and init still reported success)."""
            doc, error = read_json(SEATS_FILE)
            where = " (it appeared while waiting for the lock)" if appeared else ""
            if error is None:
                errors, _ = validate(doc)
                if errors:
                    report(errors, [])
                    raise SeatsError(f"existing seats.json is invalid{where}; init does not overwrite. Fix it by hand, repair the seat with set, or run reset")
                return True
            if error != "missing":
                raise SeatsError(f"{error}{where}; init does not overwrite. Run reset")
            return False

        # Read-only fast path: a present file never takes the lock and never
        # prompts, so generators and launchers can call init unconditionally.
        if init_precheck(False):
            out("agent-seats: seats.json present and valid; nothing written")
            return 0
        lock_for_write()
        if init_precheck(True):  # same rules under the lock
            out("agent-seats: seats.json appeared while waiting for the lock; nothing written")
            return 0
        doc = default_document()
        source, notes = "defaults", []
        if LEGACY.exists():
            source, notes = migrate_legacy(doc)
        save(doc)
        for n in notes:
            note(n)
        print_roster(doc, f"seats.json created from {source}:")
        return 0
    if cmd == "wizard":
        accept_all = "--yes" in args
        doc, source, notes = proposal()
        for n in notes:
            note(n)
        if source == "current":
            note("starting from the current seats.json")
        interactive = sys.stdin.isatty() and not accept_all
        if interactive:
            doc = interactive_wizard(doc)
        write_and_render(doc, "seats.json written:")
        return 0
    if cmd == "show":
        doc = load_current()
        errors, warnings = validate(doc)
        if not errors:
            print_roster(doc, "Seats:")
        report(errors, warnings)
        return 1 if errors else 0
    if cmd == "validate":
        doc = load_current()
        errors, warnings = validate(doc)
        report(errors, warnings)
        if errors:
            return 1
        out("agent-seats: seats.json valid")
        return 0
    if cmd == "render":
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("refusing to render an invalid assignment")
        render(doc)
        return 0
    if cmd == "roster-block":
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("invalid assignment")
        sys.stdout.write(render_block_bytes(doc, "\n").decode("utf-8") + "\n")
        return 0
    if cmd == "resolve":
        if not args:
            raise SeatsError("resolve requires a seat or route")
        seat = seat_from_arg(args[0])
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            return 1
        entry = doc["seats"][seat]
        occ = entry["occupant"]
        for value in (seat, entry["tag"], entry["phase"], occ.get("host", ""), occ.get("model") or "", occ.get("effort") or "", occ.get("fallback_model") or "", occ.get("fallback_effort") or ""):
            out(value)
        return 0
    if cmd == "model-info":
        if not args:
            raise SeatsError("model-info requires a model id")
        doc = load_current()
        if structural_errors(doc):
            report(structural_errors(doc), [])
            raise SeatsError("seats.json is structurally invalid; run validate")
        spec = model_spec(doc.get("catalog", {}).get("models"), args[0])
        if spec is None:
            raise SeatsError(f"model {args[0]} is not in catalog.models; add it to catalog.models in docs/agent-configs/seats.json (no command edits the catalog)")
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("seats.json is invalid; run validate")
        out(spec.get("host", ""))
        out(spec.get("default_effort", ""))
        out(" ".join(spec.get("efforts") or []))
        return 0
    if cmd == "roster-check":
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("invalid assignment")
        found = roster_check(args[0])
        if found != render_block_bytes(doc, "\n"):
            raise SeatsError("roster drift: run scripts/agent-seats.sh render")
        out("agent-seats: seat roster current")
        return 0
    if cmd in ("conflict", "model-overlap"):
        seat = seat_from_arg(args[0])
        model = args[1]
        doc = load_current()
        errors, warnings = validate(doc)
        report(errors, [] if QUIET else warnings)
        if errors:
            raise SeatsError("seats.json is invalid; run validate")
        overlap = model_overlap(doc, seat, model)
        if overlap and not QUIET:
            note(f"@{seat} effective model {model} is also the primary model of {', '.join('@' + o for o in overlap)}: a fact for @audit, not an authorization")
        if cmd == "model-overlap":
            if overlap:
                out(",".join(overlap))
            return 0
        out("1" if seat == "build" and overlap else "0")
        return 0
    if cmd == "set":
        if not args:
            raise SeatsError("set requires a seat")
        seat = seat_from_arg(args[0])
        opts = parse_opts(args[1:])
        if read_json(SEATS_FILE)[1] == "missing":
            raise SeatsError(f"{SEATS_FILE} is missing; run scripts/agent-seats.sh init first (set never creates the file)")
        doc, source, notes = proposal(repairing=True)
        for n in notes:
            note(n)
        occ = occupant_for(doc, seat, opts)
        doc["seats"][seat]["occupant"] = occ
        errors, warnings = validate(doc)
        report(errors, warnings)
        if errors:
            raise SeatsError("assignment is invalid; nothing written")
        write_and_render(doc, f"agent-seats: {SEAT_META[seat]['tag']} -> {occupant_text(occ)}")
        return 0
    raise SeatsError(f"unknown command: {cmd}")


try:
    sys.exit(main())
except SeatsError as exc:
    print(f"agent-seats: ERROR: {exc}", file=sys.stderr)
    sys.exit(exc.code)
except KeyboardInterrupt:
    if SAVED["seats"]:
        print("\nagent-seats: ERROR: interrupted after seats.json was written; the roster may be stale: run scripts/agent-seats.sh render", file=sys.stderr)
    else:
        print("\nagent-seats: ERROR: interrupted; nothing written", file=sys.stderr)
    sys.exit(130)
PY

cmd="${1:-}"
case "$cmd" in
  show|validate|suggest|wizard|set|init|reset|render|roster-block|resolve|model-info|conflict|model-overlap|roster-check|use|history|check|open-packet|tier-line|close-line)
    python3 -c 'import sys' >/dev/null 2>&1 || fail "python3 is required (a working interpreter, not the macOS command-line-tools stub)"
    shift
    SEATS_FILE="$SEATS_FILE" LEGACY_PROFILES="$LEGACY_PROFILES" AGENTS_MD="$AGENTS_MD" \
      AGENT_SEATS_PROJECT_ROOT="$SEATS_PROJECT_ROOT" \
      python3 -c "$SEATS_PY" "$cmd" "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    fail "unknown command: $cmd"
    ;;
esac
