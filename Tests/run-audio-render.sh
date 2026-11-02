#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$test_dir/.." && pwd)"
source_audio="${1:-/Volumes/DayuMedia 4TB/2026.10.27/261027_005.MP3}"
sample_seconds="${2:-}"
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/dayu-audio-render.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
mkdir -p "$project_dir/Outputs" "$project_dir/Analysis/Levelmatic"
python3 - "$source_audio" "$project_dir" "$benchmark_dir/build-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
source, project, destination = sys.argv[1:]
root = pathlib.Path(project)
paths = [pathlib.Path(source), root / '大鱼音频效果器Extension/DSP/LevelerCore.hpp',
         root / '大鱼音频效果器Extension/DSP/ReferenceLimiter.hpp', root / 'Tests/RenderAudio.mm']
manifest = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
pathlib.Path(destination).write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
PY
xcrun clang++ -O3 -ffp-contract=off -std=c++17 -fobjc-arc -framework Foundation -framework AudioToolbox \
    "$test_dir/RenderAudio.mm" -o "$benchmark_dir/RenderAudio"
python3 - "$benchmark_dir/build-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
for path, digest in json.loads(pathlib.Path(sys.argv[1]).read_text()).items():
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != digest:
        raise SystemExit('A build input changed during compilation; rerun once edits are complete: ' + path)
PY
if [[ -n "$sample_seconds" ]]; then
    metrics="$project_dir/Analysis/Levelmatic/short-audio-metrics.json"
    destination="$project_dir/Outputs/261027_005_自动电平_小样.m4a"
    "$benchmark_dir/RenderAudio" "$source_audio" "$benchmark_dir/render.wav" "$metrics" "$sample_seconds"
else
    metrics="$project_dir/Analysis/Levelmatic/long-audio-metrics.json"
    destination="$project_dir/Outputs/261027_005_自动电平.m4a"
    "$benchmark_dir/RenderAudio" "$source_audio" "$benchmark_dir/render.wav" "$metrics"
    python3 - "$metrics" "$benchmark_dir/segments.tsv" <<'PY'
import json, pathlib, sys
metrics = json.loads(pathlib.Path(sys.argv[1]).read_text())
seconds = metrics['per_second']
ranked = []
for start in range(60, len(seconds) - 90, 5):
    levels = [b['input']['rms_dbfs'] for b in seconds[start:start+30]]
    audible = sorted(v for v in levels if v > -50)
    if len(audible) < 24:
        continue
    spread = audible[int((len(audible)-1)*.9)] - audible[int((len(audible)-1)*.1)]
    ranked.append((spread, start))
selected = []
for spread, start in sorted(ranked, reverse=True):
    if all(abs(start - previous) >= 300 for previous in selected):
        selected.append(start)
    if len(selected) == 2:
        break
with open(sys.argv[2], 'w') as f:
    for start in sorted(selected):
        end = start + 30
        label = f'{start//60:02d}分{start%60:02d}秒至{end//60:02d}分{end%60:02d}秒'
        f.write(f'{start}\t{end}\t{label}\n')
PY
    mkdir -p "$project_dir/Outputs/试听"
    while IFS=$'\t' read -r start end label; do
        ffmpeg -v error -nostdin -y -ss "$start" -i "$source_audio" -t "$((end - start))" \
            -c:a aac -b:a 192k -movflags +faststart "$project_dir/Outputs/试听/A_原声_$label.m4a"
        ffmpeg -v error -nostdin -y -ss "$start" -i "$benchmark_dir/render.wav" -t "$((end - start))" \
            -c:a aac -b:a 192k -movflags +faststart "$project_dir/Outputs/试听/B_处理后_$label.m4a"
    done < "$benchmark_dir/segments.tsv"
fi
ffmpeg -v error -nostdin -y -i "$benchmark_dir/render.wav" -c:a aac -b:a 192k -movflags +faststart "$benchmark_dir/processed.m4a"
mv -f "$benchmark_dir/processed.m4a" "$destination"
python3 - "$metrics" "$destination" "$benchmark_dir/build-manifest.json" "$benchmark_dir/segments.tsv" <<'PY'
import json, math, os, pathlib, sys
path, destination, manifest, segments = sys.argv[1:]
with open(path) as f:
    metrics = json.load(f)
metrics['final_audio_output'] = destination
metrics['final_audio_size_bytes'] = os.stat(destination).st_size
metrics['encoding'] = 'AAC LC, 192 kb/s, source sample rate and channel count retained'
metrics['intermediate_float_wav_deleted_after_encode'] = True
metrics['peak_resident_memory_scope'] = 'Renderer peak RSS through audio processing and WAV finalization, sampled before constructing/serializing metrics JSON; excludes the separate ffmpeg AAC encoder process'
metrics['compile_flags'] = ['-O3', '-ffp-contract=off', '-std=c++17', '-fobjc-arc']
metrics['build_input_sha256'] = json.loads(pathlib.Path(manifest).read_text())
if pathlib.Path(segments).exists():
    previews = []
    for row in pathlib.Path(segments).read_text().splitlines():
        start, end, label = row.split('\t')
        start, end = int(start), int(end)
        preview = {'start_seconds': start, 'end_seconds': end,
                   'selection_method': 'Large variation in per-second RMS with >=24/30 input seconds above -50dBFS; no speech recognition or source separation',
                   'original': str(pathlib.Path(destination).parent / '试听' / f'A_原声_{label}.m4a'),
                   'processed': str(pathlib.Path(destination).parent / '试听' / f'B_处理后_{label}.m4a')}
        for track in ('input', 'output'):
            levels = sorted(b[track]['rms_dbfs'] for b in metrics['per_second'][start:end])
            preview[track + '_rms_p90_minus_p10_db'] = levels[int((len(levels)-1)*.9)] - levels[int((len(levels)-1)*.1)]
            preview[track + '_rms_dbfs'] = 10 * math.log10(sum(10**(v/10) for v in levels) / len(levels))
        previews.append(preview)
    metrics['ab_previews'] = previews
with open(path, 'w') as f:
    json.dump(metrics, f, ensure_ascii=False, indent=2)
PY
printf '%s\n' "$destination"
