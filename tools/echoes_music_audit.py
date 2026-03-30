#!/usr/bin/env python3
"""Audit Echoes plugin music catalogs without editing repo files.
This script is intentionally conservative:
- it reads a pinned wowdev listfile CSV or URL
- it scans plugin Tracks.lua / TrackDurations
- it finds candidate tracks for configured scopes
- it can download audio from Wago and measure durations via ffprobe
- it emits reports and patch-ready snippets
It never rewrites the plugin files directly.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
USER_AGENT = "EchoesMusicAudit/1.0"
DEFAULT_LISTFILE_URL = (
    "https://github.com/wowdev/wow-listfile/releases/latest/download/"
    "community-listfile-withcapitals.csv"
)
WAGO_DOWNLOAD_URL = "https://wago.tools/api/casc/{fdid}?download"
TRACK_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+)\s*,")
DURATION_RE = re.compile(
    r"^\s*\[(\d+)\]\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*--\s*([A-Za-z_][A-Za-z0-9_]*)"
)
@dataclass
class Candidate:
    fdid: int
    path: str
    scope_name: str
    scope_comment: str
    pack_key: Optional[str]
    pack_label: Optional[str]
    symbol: str
    existing_symbol: Optional[str]
    existing_duration: Optional[float]
    measured_duration: Optional[float] = None
    duration_error: Optional[str] = None
    @property
    def effective_symbol(self) -> str:
        return self.existing_symbol or self.symbol
    @property
    def is_missing_track(self) -> bool:
        return self.existing_symbol is None
    @property
    def needs_duration(self) -> bool:
        return self.existing_duration is None
    @property
    def has_duration_mismatch(self) -> bool:
        if self.existing_duration is None or self.measured_duration is None:
            return False
        return abs(self.existing_duration - self.measured_duration) >= 0.05
def read_text(source: str) -> str:
    if re.match(r"^https?://", source):
        request = urllib.request.Request(source, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request) as response:
            return response.read().decode("utf-8", "replace")
    return Path(source).read_text(encoding="utf-8")
def load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)
def parse_listfile(text: str) -> List[tuple[int, str]]:
    entries: List[tuple[int, str]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if ";" in line:
            left, right = line.split(";", 1)
        elif "," in line:
            left, right = line.split(",", 1)
        else:
            continue
        try:
            fdid = int(left)
        except ValueError:
            continue
        entries.append((fdid, right.strip()))
    return entries
def parse_tracks_file(text: str) -> Dict[int, str]:
    mapping: Dict[int, str] = {}
    for line in text.splitlines():
        match = TRACK_RE.match(line)
        if not match:
            continue
        symbol, fdid = match.groups()
        mapping[int(fdid)] = symbol
    return mapping
def parse_durations_file(text: str) -> Dict[int, float]:
    mapping: Dict[int, float] = {}
    for line in text.splitlines():
        match = DURATION_RE.match(line)
        if not match:
            continue
        fdid, duration, _symbol = match.groups()
        mapping[int(fdid)] = float(duration)
    return mapping
def normalize_stem(stem: str) -> str:
    stem = re.sub(r"\.[A-Za-z0-9]+$", "", stem)
    stem = re.sub(r"^(?:MUS|mus)_[0-9]+_", "", stem)
    parts = re.split(r"[^A-Za-z0-9]+", stem)
    words = [part for part in parts if part]
    if not words:
        return "Track"
    return "".join(word[:1].upper() + word[1:] for word in words)
def compile_patterns(patterns: Iterable[str], ignore_case: bool) -> List[re.Pattern[str]]:
    flags = re.IGNORECASE if ignore_case else 0
    return [re.compile(pattern, flags) for pattern in patterns]
def match_scope(path: str, scope: Dict[str, Any], compiled: List[re.Pattern[str]]) -> bool:
    for pattern in compiled:
        if pattern.search(path):
            return True
    return False
def build_candidates(
    listfile_entries: List[tuple[int, str]],
    scopes: List[Dict[str, Any]],
    track_symbols: Dict[int, str],
    durations: Dict[int, float],
) -> List[Candidate]:
    candidates: List[Candidate] = []
    compiled_cache: Dict[str, List[re.Pattern[str]]] = {}
    for scope in scopes:
        key = scope["name"]
        compiled_cache[key] = compile_patterns(
            scope.get("patterns", []),
            scope.get("ignore_case", True),
        )
    seen: set[tuple[str, int]] = set()
    for fdid, path in listfile_entries:
        for scope in scopes:
            scope_name = scope["name"]
            if not match_scope(path, scope, compiled_cache[scope_name]):
                continue
            pair = (scope_name, fdid)
            if pair in seen:
                continue
            seen.add(pair)
            basename = Path(path).name
            symbol = scope.get("symbol_overrides", {}).get(
                str(fdid),
                scope.get("symbol_prefix", "") + normalize_stem(basename),
            )
            candidates.append(
                Candidate(
                    fdid=fdid,
                    path=path,
                    scope_name=scope_name,
                    scope_comment=scope.get("comment", scope_name),
                    pack_key=scope.get("pack_key"),
                    pack_label=scope.get("pack_label"),
                    symbol=symbol,
                    existing_symbol=track_symbols.get(fdid),
                    existing_duration=durations.get(fdid),
                )
            )
    candidates.sort(key=lambda item: (item.scope_name, item.fdid))
    return candidates
def measure_duration(fdid: int, extension: str = ".bin") -> float:
    with tempfile.TemporaryDirectory() as temp_dir:
        target = Path(temp_dir) / f"{fdid}{extension}"
        request = urllib.request.Request(
            WAGO_DOWNLOAD_URL.format(fdid=fdid),
            headers={"User-Agent": USER_AGENT},
        )
        with urllib.request.urlopen(request) as response, open(target, "wb") as handle:
            handle.write(response.read())
        env = dict(os.environ)
        env["LC_ALL"] = "C"
        output = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(target),
            ],
            text=True,
            env=env,
        ).strip()
        return round(float(output), 1)
def maybe_measure_durations(candidates: List[Candidate], enabled: bool) -> None:
    if not enabled:
        return
    for candidate in candidates:
        extension = Path(candidate.path).suffix or ".bin"
        try:
            candidate.measured_duration = measure_duration(candidate.fdid, extension)
        except Exception as exc:  # noqa: BLE001
            candidate.duration_error = str(exc)
def format_track_snippets(candidates: List[Candidate]) -> str:
    lines: List[str] = []
    grouped: Dict[str, List[Candidate]] = {}
    for candidate in candidates:
        if not candidate.is_missing_track:
            continue
        grouped.setdefault(candidate.scope_comment, []).append(candidate)
    for comment, group in grouped.items():
        lines.append(f"    -- {comment}")
        for item in group:
            lines.append(f"    {item.symbol} = {item.fdid},")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"
def format_duration_snippets(candidates: List[Candidate]) -> str:
    lines: List[str] = []
    for item in candidates:
        if item.measured_duration is None and not item.needs_duration:
            continue
        if item.duration_error:
            continue
        duration = item.measured_duration if item.measured_duration is not None else item.existing_duration
        if duration is None:
            continue
        if item.needs_duration or item.has_duration_mismatch:
            lines.append(
                f"    [{item.fdid}] = {duration:6.1f},  -- {item.effective_symbol}"
            )
    return "\n".join(lines).rstrip() + ("\n" if lines else "")
def format_pack_suggestions(candidates: List[Candidate]) -> str:
    lines: List[str] = []
    grouped: Dict[str, List[Candidate]] = {}
    labels: Dict[str, str] = {}
    for item in candidates:
        if not item.pack_key or not item.pack_label:
            continue
        grouped.setdefault(item.pack_key, []).append(item)
        labels[item.pack_key] = item.pack_label
    for pack_key, group in grouped.items():
        lines.append(f"local {pack_key} = Pack {{")
        lines.append(f'    label = "{labels[pack_key]}",')
        lines.append("    any = {")
        for item in group:
            lines.append(f"        T.{item.effective_symbol},")
        lines.append("    },")
        lines.append("}")
        lines.append("")
    return "\n".join(lines).rstrip() + ("\n" if lines else "")
def format_table_row(columns: List[str]) -> str:
    return "| " + " | ".join(columns) + " |"
def build_markdown_report(
    config: Dict[str, Any],
    plugin_root: Path,
    track_symbols: Dict[int, str],
    durations: Dict[int, float],
    candidates: List[Candidate],
) -> str:
    missing_tracks = [item for item in candidates if item.is_missing_track]
    missing_durations = [item for item in candidates if item.needs_duration]
    mismatched_durations = [item for item in candidates if item.has_duration_mismatch]
    stale_duration_ids = sorted(set(durations) - set(track_symbols))
    lines = [
        f"# {config['name']}",
        "",
        f"- Plugin root: `{plugin_root}`",
        f"- Tracks known: `{len(track_symbols)}`",
        f"- Duration rows: `{len(durations)}`",
        f"- Scoped candidates: `{len(candidates)}`",
        f"- Missing tracks in scope: `{len(missing_tracks)}`",
        f"- Missing durations in scope: `{len(missing_durations)}`",
        f"- Duration mismatches in scope: `{len(mismatched_durations)}`",
        f"- Stale duration rows in plugin: `{len(stale_duration_ids)}`",
        "",
        "## Scoped Candidates",
        "",
        format_table_row(
            [
                "FDID",
                "Scope",
                "Path",
                "Symbol",
                "In Tracks",
                "Duration",
                "Measured",
            ]
        ),
        format_table_row(["---"] * 7),
    ]
    for item in candidates:
        duration_value = "" if item.existing_duration is None else f"{item.existing_duration:.1f}"
        measured = ""
        if item.duration_error:
            measured = f"error: {item.duration_error}"
        elif item.measured_duration is not None:
            measured = f"{item.measured_duration:.1f}"
        lines.append(
            format_table_row(
                [
                    str(item.fdid),
                    item.scope_name,
                    item.path,
                    item.effective_symbol,
                    "yes" if item.existing_symbol else "no",
                    duration_value,
                    measured,
                ]
            )
        )
    lines.extend(
        [
            "",
            "## Missing Tracks",
            "",
        ]
    )
    if missing_tracks:
        for item in missing_tracks:
            lines.append(f"- `{item.fdid}` `{item.symbol}` from `{item.path}`")
    else:
        lines.append("- None.")
    lines.extend(
        [
            "",
            "## Missing Or Mismatched Durations",
            "",
        ]
    )
    if missing_durations or mismatched_durations:
        for item in missing_durations + [m for m in mismatched_durations if m not in missing_durations]:
            reason = "missing"
            if item.has_duration_mismatch:
                reason = f"mismatch ({item.existing_duration:.1f} vs {item.measured_duration:.1f})"
            lines.append(f"- `{item.fdid}` `{item.effective_symbol}`: {reason}")
    else:
        lines.append("- None.")
    lines.extend(
        [
            "",
            "## Stale Duration Rows",
            "",
        ]
    )
    if stale_duration_ids:
        for fdid in stale_duration_ids:
            lines.append(f"- `{fdid}`")
    else:
        lines.append("- None.")
    lines.extend(
        [
            "",
            "## Manual Review Notes",
            "",
            "- Review final symbol names before patching if the filename is ambiguous.",
            "- Review `intro` / `day` / `night` / `any` placement manually.",
            "- Story-state requests such as post-event music should usually become optional packs unless the game exposes stable subzone signals.",
        ]
    )
    return "\n".join(lines) + "\n"
def write_outputs(output_dir: Path, report: str, candidates: List[Candidate], config: Dict[str, Any]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "report.md").write_text(report, encoding="utf-8")
    (output_dir / "tracks_snippet.lua").write_text(format_track_snippets(candidates), encoding="utf-8")
    (output_dir / "durations_snippet.lua").write_text(format_duration_snippets(candidates), encoding="utf-8")
    (output_dir / "pack_suggestions.lua").write_text(format_pack_suggestions(candidates), encoding="utf-8")
    json_payload = {
        "name": config["name"],
        "scoped_candidates": [
            {
                "fdid": item.fdid,
                "scope": item.scope_name,
                "path": item.path,
                "symbol": item.symbol,
                "existing_symbol": item.existing_symbol,
                "existing_duration": item.existing_duration,
                "measured_duration": item.measured_duration,
                "duration_error": item.duration_error,
                "pack_key": item.pack_key,
                "pack_label": item.pack_label,
            }
            for item in candidates
        ],
    }
    (output_dir / "audit.json").write_text(
        json.dumps(json_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
def resolve_plugin_root(config_path: Path, config: Dict[str, Any], override: Optional[str]) -> Path:
    if override:
        return Path(override).resolve()
    plugin_root = config.get("plugin_root", ".")
    return (config_path.parent / plugin_root).resolve()
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit Echoes plugin music tracks and durations without editing files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """\
            Example:
              python tools/echoes_music_audit.py \
                --config tools/plugin_configs/quelthalas_void.json \
                --measure-durations \
                --output-dir docs/generated/quelthalas_void
            """
        ),
    )
    parser.add_argument("--config", required=True, help="Path to a JSON config file.")
    parser.add_argument(
        "--listfile",
        help="Listfile path or URL. Defaults to the latest wowdev community listfile release.",
    )
    parser.add_argument("--plugin-root", help="Override plugin root from config.")
    parser.add_argument("--output-dir", help="Directory for report and snippet files.")
    parser.add_argument(
        "--measure-durations",
        action="store_true",
        help="Download matching audio from Wago and measure durations with ffprobe.",
    )
    args = parser.parse_args(argv)
    config_path = Path(args.config).resolve()
    config = load_json(str(config_path))
    plugin_root = resolve_plugin_root(config_path, config, args.plugin_root)
    tracks_path = plugin_root / config.get("tracks_file", "Tracks.lua")
    listfile_source = args.listfile or config.get("listfile") or DEFAULT_LISTFILE_URL
    listfile_entries = parse_listfile(read_text(listfile_source))
    tracks_text = tracks_path.read_text(encoding="utf-8")
    track_symbols = parse_tracks_file(tracks_text)
    durations = parse_durations_file(tracks_text)
    candidates = build_candidates(
        listfile_entries=listfile_entries,
        scopes=config.get("scopes", []),
        track_symbols=track_symbols,
        durations=durations,
    )
    maybe_measure_durations(candidates, args.measure_durations)
    report = build_markdown_report(
        config=config,
        plugin_root=plugin_root,
        track_symbols=track_symbols,
        durations=durations,
        candidates=candidates,
    )
    if args.output_dir:
        write_outputs(Path(args.output_dir), report, candidates, config)
    else:
        sys.stdout.write(report)
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
