"""Score hypothesis RTTMs against AliMeeting references with pyannote.metrics.

Usage: score.py REF_DIR HYP_DIR [--fill-gaps SECONDS] [--json OUT.json]
--fill-gaps bridges same-speaker hypothesis gaps shorter than SECONDS before scoring, the way
pyannote's min_duration_off does; AliMeeting turns include short pauses that tight models leave out.
REF_DIR holds <session>.rttm and <session>.uem; HYP_DIR holds <file-id>.rttm and <file-id>.json
from diareval. A hypothesis file id is "<session>__<condition>".
"""

import argparse
import json
from pathlib import Path

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate


def load_rttm(path: Path) -> Annotation:
    annotation = Annotation(uri=path.stem)
    for line in path.read_text().splitlines():
        fields = line.split()
        if not fields or fields[0] != "SPEAKER":
            continue
        start, duration = float(fields[3]), float(fields[4])
        annotation[Segment(start, start + duration)] = fields[7]
    return annotation


def load_uem(path: Path) -> Timeline:
    fields = path.read_text().split()
    return Timeline([Segment(float(fields[2]), float(fields[3]))])


def overlap_timeline(annotation: Annotation) -> Timeline:
    regions = []
    tracks = list(annotation.itertracks())
    for i, (seg_a, _) in enumerate(tracks):
        for seg_b, _ in tracks[i + 1 :]:
            if seg_b.start >= seg_a.end:
                break
            inter = seg_a & seg_b
            if inter:
                regions.append(inter)
    return Timeline(regions).support()


def components(metric_result: dict) -> dict:
    total = metric_result["total"]
    return {
        "scored_speech_s": total,
        "der": metric_result["diarization error rate"],
        "miss": metric_result["missed detection"] / total if total else 0.0,
        "false_alarm": metric_result["false alarm"] / total if total else 0.0,
        "confusion": metric_result["confusion"] / total if total else 0.0,
    }


def fill_gaps(annotation: Annotation, seconds: float) -> Annotation:
    filled = Annotation(uri=annotation.uri)
    for label in annotation.labels():
        for segment in annotation.label_timeline(label).support(collar=seconds):
            filled[segment] = label
    return filled


def score(ref_dir: Path, hyp_dir: Path, gap_fill: float = 0.0) -> dict:
    hyps = sorted(hyp_dir.glob("*.rttm"))
    if not hyps:
        raise SystemExit(f"no hypothesis RTTMs in {hyp_dir}")
    pooled = {
        "collar0": DiarizationErrorRate(collar=0.0, skip_overlap=False),
        "collar0.25": DiarizationErrorRate(collar=0.25, skip_overlap=False),
        "collar0.25_skip_overlap": DiarizationErrorRate(collar=0.25, skip_overlap=True),
        "overlap_only": DiarizationErrorRate(collar=0.0, skip_overlap=False),
    }
    sessions = []
    for hyp_path in hyps:
        session = hyp_path.stem.split("__")[0]
        reference = load_rttm(ref_dir / f"{session}.rttm")
        hypothesis = load_rttm(hyp_path)
        if gap_fill:
            hypothesis = fill_gaps(hypothesis, gap_fill)
        uem = load_uem(ref_dir / f"{session}.uem")
        ref_overlap = overlap_timeline(reference).crop(uem)
        hyp_overlap = overlap_timeline(hypothesis).crop(uem)
        overlap_hit = sum(s.duration for s in ref_overlap.crop(hyp_overlap, mode="intersection"))
        ref_overlap_s = ref_overlap.duration()
        hyp_overlap_s = hyp_overlap.duration()

        row = {"file": hyp_path.stem, "session": session}
        for name, metric in pooled.items():
            scope = ref_overlap if name == "overlap_only" else uem
            row[name] = components(metric(reference, hypothesis, uem=scope, detailed=True))
        record = json.loads(hyp_path.with_suffix(".json").read_text())
        hyp_durations = hypothesis.chart()
        row.update(
            {
                "ref_speakers": len(reference.labels()),
                "hyp_speakers": len(hypothesis.labels()),
                "hyp_speakers_ge_10s": sum(1 for _, d in hyp_durations if d >= 10.0),
                "ref_speech_s": reference.get_timeline().support().crop(uem).duration(),
                "ref_overlap_s": ref_overlap_s,
                "hyp_overlap_s": hyp_overlap_s,
                "overlap_recall": overlap_hit / ref_overlap_s if ref_overlap_s else None,
                "overlap_precision": overlap_hit / hyp_overlap_s if hyp_overlap_s else None,
                "audio_s": record["audioSeconds"],
                "wall_s": record["wallSeconds"],
                "rtf": record["realTimeFactor"],
                "ref_extent_s": reference.get_timeline().extent().end,
                "hyp_extent_s": hypothesis.get_timeline().extent().end if hypothesis else 0.0,
            }
        )
        sessions.append(row)

    totals = {}
    for name, metric in pooled.items():
        totals[name] = components(_accumulated(metric))
    totals["rtf"] = sum(r["wall_s"] for r in sessions) / sum(r["audio_s"] for r in sessions)
    totals["ref_overlap_fraction"] = sum(r["ref_overlap_s"] for r in sessions) / sum(
        r["ref_speech_s"] for r in sessions
    )
    return {"sessions": sessions, "pooled": totals}


def _accumulated(metric: DiarizationErrorRate) -> dict:
    acc = dict(metric.accumulated_)
    acc["diarization error rate"] = abs(metric)
    return acc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ref_dir", type=Path)
    parser.add_argument("hyp_dir", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--fill-gaps", type=float, default=0.0)
    args = parser.parse_args()
    result = score(args.ref_dir, args.hyp_dir, args.fill_gaps)

    header = f"{'file':38} {'spk ref/hyp(>=10s)':>18} {'DER0':>6} {'DER.25':>6} {'MS':>5} {'FA':>5} {'CF':>5} {'ovDER':>6} {'ovRec':>5} {'RTF':>6}"
    print(header)
    for r in result["sessions"]:
        c = r["collar0.25"]
        print(
            f"{r['file']:38} {r['ref_speakers']:>6}/{r['hyp_speakers']}({r['hyp_speakers_ge_10s']})      "
            f"{r['collar0']['der']*100:6.2f} {c['der']*100:6.2f} {c['miss']*100:5.2f} {c['false_alarm']*100:5.2f} "
            f"{c['confusion']*100:5.2f} {r['overlap_only']['der']*100:6.2f} "
            f"{(r['overlap_recall'] or 0)*100:5.1f} {r['rtf']:6.4f}"
        )
    p = result["pooled"]
    c = p["collar0.25"]
    print(
        f"{'POOLED':38} {'':18} {p['collar0']['der']*100:6.2f} {c['der']*100:6.2f} {c['miss']*100:5.2f} "
        f"{c['false_alarm']*100:5.2f} {c['confusion']*100:5.2f} {p['overlap_only']['der']*100:6.2f} {'':5} {p['rtf']:6.4f}"
    )
    print(f"reference overlap fraction of scored speech: {p['ref_overlap_fraction']*100:.1f}%")
    if args.json:
        args.json.write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
