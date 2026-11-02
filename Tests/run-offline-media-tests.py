#!/usr/bin/env python3
"""Integration tests for the shipping Swift pipeline; ffmpeg is only a fixture/inspection tool."""
import hashlib
import json
import pathlib
import subprocess
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIX = ROOT / 'Analysis/OfflineProcessing/Fixtures'
FIX.mkdir(parents=True, exist_ok=True)
DRIVER = ROOT / '.build-tests/OfflineMediaProcessingTests'
REPORT = []


def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True).stdout


def ff(*args):
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args])


def info(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', path]))


def pcm(path):
    return run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0', '-c:a', 'pcm_f32le', '-f', 'f32le', '-'])


def video_packets(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_packets',
        '-show_entries', 'packet=stream_index,pts_time,dts_time,duration_time,size,data_hash',
        '-show_data_hash', 'sha256', '-of', 'json', path]))['packets']


def process(path, effect='low-latency', mode=None, failure=False):
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    args = [str(DRIVER), effect, str(path)] + ([mode] if mode else [])
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before, 'source changed'
    if failure:
        assert result.returncode != 0, result.stdout
        return result.stderr[-1000:]
    assert result.returncode == 0, result.stderr
    if mode in ('cancel', 'cancel-mid'):
        assert result.stdout.strip() == 'CANCELLED'
        return
    output = pathlib.Path(result.stdout.strip())
    assert output.exists() and output.parent == path.parent and output != path
    return output


# Deliberately non-block-aligned audio with a transient at both ends.
source = FIX / '边界采样.wav'
ff('-f', 'lavfi', '-i', 'aevalsrc=0.1*sin(2*PI*220*t)+0.3*eq(n\\,0)+0.2*eq(n\\,120479)|0.07*sin(2*PI*440*t):s=48000:d=2.51',
   '-c:a', 'pcm_f32le', source)
for effect in ['reference', 'low-latency', 'audio-denoise-ai', 'era5-declipper']:
    output = process(source, effect, 'bypass')
    a, b = pcm(source), pcm(output)
    assert len(a) == len(b), f'{effect}: frame count mismatch'
    x = struct.unpack('<%df' % (len(a) // 4), a)
    y = struct.unpack('<%df' % (len(b) // 4), b)
    error = max(abs(u-v) for u, v in zip(x, y))
    assert error <= 5e-8, f'{effect}: latency compensation or tail mismatch: {error}'
    REPORT.append({'test': 'bypass_exact_frames_and_samples', 'effect': effect, 'max_sample_error': error, 'passed': True})
    print('PASS latency/tail/bypass:', effect, flush=True)

active = process(source)
assert len(pcm(active)) == len(pcm(source)) and pcm(active) != pcm(source)
REPORT.append({'test': 'active_dsp_changes_audio_keeps_length', 'passed': True})
gain = process(source, mode='gain')
a, b = pcm(active), pcm(gain)
assert len(a) == len(b)
x = struct.unpack('<%df' % (len(a) // 4), a)
y = struct.unpack('<%df' % (len(b) // 4), b)
# Existing DSP ramps gain at startup; verify the settled transfer.
gain_error = max(abs(v-u*10**(-6/20)) for u, v in zip(x[9600:], y[9600:]))
assert gain_error < 2e-6
REPORT.append({'test': 'current_parameter_snapshot_minus6dB', 'max_error_after_100ms': gain_error, 'passed': True})
# A second export must retain the first completed copy.
original = active.read_bytes()
second = process(source)
assert second != active and active.read_bytes() == original
REPORT.append({'test': 'collision_never_overwrites', 'passed': True})
process(source, mode='cancel')
REPORT.append({'test': 'cancelled_job_no_partial_copy', 'passed': True})

mp3 = FIX / '44k单声道.MP3'
ff('-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=44100:duration=2.37', '-c:a', 'libmp3lame', '-b:a', '128k', mp3)
out = process(mp3)
assert info(out)['streams'][0]['sample_rate'] == '44100'
assert info(out)['streams'][0]['channels'] == 1
REPORT.append({'test': 'mp3_mono_44100_to_wav', 'passed': True})

mp4 = FIX / 'H264_AAC_错位音轨.mp4'
ff('-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=30:duration=3.2', '-itsoffset', '0.4', '-i', source,
   '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-bf', '2', '-c:a', 'aac', '-b:a', '192k', mp4)
mov = FIX / 'HEVC_PCM24.mov'
ff('-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=25:duration=2.51', '-i', source,
   '-map', '0:v', '-map', '1:a', '-c:v', 'libx265', '-x265-params', 'log-level=error', '-tag:v', 'hvc1', '-c:a', 'pcm_s24le', mov)
multi = FIX / '双音轨.mp4'
ff('-i', mp4, '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100:duration=3.2',
   '-map', '0:v', '-map', '0:a', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a:0', '192k', '-b:a:1', '96k',
   '-metadata:s:a:0', 'language=zho', '-metadata:s:a:1', 'language=eng', multi)
rotated = FIX / '旋转视频.mp4'
ff('-i', mp4, '-c', 'copy', '-metadata:s:v:0', 'rotate=90', rotated)
alac = FIX / 'ALAC.mov'
ff('-i', mp4, '-c:v', 'copy', '-c:a', 'alac', alac)

prores = FIX / 'ProRes_PCM16.mov'
ff('-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=25:duration=2.51', '-i', source,
   '-map', '0:v', '-map', '1:a', '-c:v', 'prores_ks', '-profile:v', '3', '-c:a', 'pcm_s16le', prores)
m4v = FIX / 'AAC.m4v'
ff('-i', mp4, '-c', 'copy', '-f', 'ipod', m4v)

for path in [mp4, mov, multi, rotated, alac, prores, m4v]:
    output = process(path)
    a, b = info(path), info(output)
    p, q = video_packets(path), video_packets(output)
    assert len(p) == len(q), f'{path.name}: video packet count differs'
    for src, dst in zip(p, q):
        assert src['data_hash'] == dst['data_hash'], f'{path.name}: video data changed'
        for key in ['pts_time', 'dts_time', 'duration_time']:
            assert abs(float(src.get(key, 0)) - float(dst.get(key, 0))) < 0.00002, (path.name, key, src, dst)
    src_audio = [x for x in a['streams'] if x['codec_type'] == 'audio']
    dst_audio = [x for x in b['streams'] if x['codec_type'] == 'audio']
    assert len(src_audio) == len(dst_audio)
    checks = []
    native_a = json.loads(run([DRIVER, 'inspect', path]))
    native_b = json.loads(run([DRIVER, 'inspect', output]))
    for track_index, (src, dst) in enumerate(zip(src_audio, dst_audio)):
        for key in ['codec_name', 'profile', 'sample_rate', 'channels', 'bits_per_sample', 'bits_per_raw_sample']:
            assert src.get(key) == dst.get(key), (path.name, key, src.get(key), dst.get(key))
        for stream in [src, dst]:
            layout = stream.get('channel_layout') or ('mono' if stream['channels'] == 1 else 'stereo')
            assert layout == ('mono' if stream['channels'] == 1 else 'stereo'), (path.name, 'layout', layout)
        # AAC packetization can shift reported packet start by one encoder frame; the edit list must keep media aligned.
        assert abs(float(src.get('start_time', 0)) - float(dst.get('start_time', 0))) <= 1 / float(src['sample_rate']) + 0.00001, (path.name, 'audio start', src.get('start_time'), dst.get('start_time'))
        na, nb = native_a[track_index], native_b[track_index]
        assert na['frames'] == nb['frames'], (path.name, 'valid audio frames', na, nb)
        assert abs(na['start'] - nb['start']) < 1 / na['rate'], (path.name, 'native start', na, nb)
        assert abs(na['end'] - nb['end']) < 1 / na['rate'], (path.name, 'native end', na, nb)
        if src['codec_name'] == 'aac':
            assert abs(int(src['bit_rate']) - int(dst['bit_rate'])) / int(src['bit_rate']) < 0.02, (path.name, 'bitrate drift', src['bit_rate'], dst['bit_rate'])
        assert (src.get('tags', {}).get('language') or 'und') == (dst.get('tags', {}).get('language') or 'und'), path.name
        checks.append({'codec': src['codec_name'], 'rate': src['sample_rate'], 'channels': src['channels'],
            'source_bitrate': src.get('bit_rate'), 'output_bitrate': dst.get('bit_rate'),
            'source_start': src.get('start_time'), 'output_start': dst.get('start_time'), 'native_source': na, 'native_output': nb})
    sv = [x for x in a['streams'] if x['codec_type'] == 'video'][0]
    dv = [x for x in b['streams'] if x['codec_type'] == 'video'][0]
    assert sv.get('side_data_list') == dv.get('side_data_list'), (path.name, 'video side data')
    assert abs(float(a['format']['duration']) - float(b['format']['duration'])) < 0.0001
    REPORT.append({'test': path.name, 'passed': True, 'video_packets_unchanged': len(p), 'audio': checks})
    print('PASS original video bytes, timing, audio format:', path.name, flush=True)

no_audio = FIX / '无音轨.mp4'
ff('-i', mp4, '-map', '0:v', '-c', 'copy', no_audio)
process(no_audio, failure=True)
surround = FIX / '多声道.mov'
ff('-f', 'lavfi', '-i', 'color=size=160x90:rate=25:duration=1', '-f', 'lavfi', '-i', 'anullsrc=channel_layout=5.1:sample_rate=48000',
   '-t', '1', '-c:v', 'libx264', '-c:a', 'pcm_s16le', surround)
process(surround, failure=True)
unsupported = FIX / 'AC3.mov'
ff('-i', mp4, '-c:v', 'copy', '-c:a', 'ac3', '-b:a', '192k', unsupported)
process(unsupported, failure=True)
long_audio = FIX / '取消测试.wav'
ff('-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=48000:duration=60', '-c:a', 'pcm_f32le', long_audio)
process(long_audio, 'audio-denoise-ai', 'cancel-mid')
assert not list(FIX.glob('取消测试_*')), 'cancelled job published an output'
REPORT.append({'test': 'cancel_during_processing_removes_partial', 'passed': True})
assert not list(FIX.glob('.dayu-*')), 'partial files left behind'
REPORT.append({'test': 'no_audio_multichannel_unsupported_codec_fail_cleanly', 'passed': True})
(ROOT / 'Analysis/OfflineProcessing/report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
print('PASS all offline media integration tests')
