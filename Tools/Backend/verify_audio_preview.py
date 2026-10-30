#!/usr/bin/env python3
"""Exercise the frozen beat/structure endpoints on an isolated copy of a WAV.

Never writes the input or an existing job. No download, translation or publishing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('helper', type=Path)
    parser.add_argument('audio', type=Path)
    parser.add_argument('--min-bpm', type=float)
    parser.add_argument('--max-bpm', type=float)
    args = parser.parse_args()
    source_hash = hashlib.sha256(args.audio.read_bytes()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='chordadmin-packaged-timing-'))
    for name in ('cache', 'temp', 'jobs'):
        (root / name).mkdir()
    audio = root / 'jobs/analysis.wav'
    shutil.copy2(args.audio, audio)
    token = secrets.token_hex(32)
    env = dict(os.environ, CHORDADMIN_RUNTIME_TOKEN=token, CHORDADMIN_RUNTIME_INSTANCE='timing-preview',
               CHORDADMIN_PARENT_PID=str(os.getpid()), CHORDADMIN_READY_FILE=str(root / 'ready.json'),
               CHORDADMIN_CACHE_DIR=str(root / 'cache'), CHORDADMIN_TEMP_DIR=str(root / 'temp'),
               CHORDADMIN_JOBS_ROOT=str(root / 'jobs'), NUMBA_CACHE_DIR=str(root / 'cache/numba'))
    for name in ('PYTHONPATH', 'PYTHONHOME', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH'):
        env.pop(name, None)
    env['PATH'] = '/usr/bin:/bin'
    log = (root / 'runtime.log').open('w')
    process = subprocess.Popen([str(args.helper.resolve())], env=env, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 90
        while not (root / 'ready.json').exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Helper failed to start; see ' + str(root / 'runtime.log'))
            time.sleep(0.1)
        base = 'http://127.0.0.1:' + str(json.loads((root / 'ready.json').read_text())['port'])

        def post(endpoint, fields):
            boundary = secrets.token_hex(16)
            chunks = []
            for key, value in fields.items():
                chunks.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + key +
                               '"\r\n\r\n' + str(value) + '\r\n').encode())
            chunks += [('--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="analysis.wav"'
                        '\r\nContent-Type: audio/wav\r\n\r\n').encode(), audio.read_bytes(),
                       ('\r\n--' + boundary + '--\r\n').encode()]
            request = urllib.request.Request(base + endpoint, data=b''.join(chunks),
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'multipart/form-data; boundary=' + boundary})
            with urllib.request.urlopen(request, timeout=300) as response:
                result = json.load(response)
            if result.get('status') != 'success':
                raise RuntimeError(str(result))
            return result

        fields = {'model': 'madmom', 'beats_per_bar': 4}
        if args.min_bpm is not None:
            fields['min_bpm'] = args.min_bpm
        if args.max_bpm is not None:
            fields['max_bpm'] = args.max_bpm
        beats = post('/api/detect-beats', fields)
        (root / 'beats.json').write_text(json.dumps(beats, indent=2))
        starts = [beat['time'] for beat in beats['beats'] if beat['beatInBar'] == 1]
        # Only complete decoded bar intervals are used for this endpoint probe.
        bars = [{'bar': i + 1, 'start': a, 'end': b} for i, (a, b) in enumerate(zip(starts, starts[1:]))]
        structure = post('/api/detect-structure', {'bars': json.dumps(bars)})
        (root / 'structure.json').write_text(json.dumps(structure, indent=2))
        assert source_hash == hashlib.sha256(args.audio.read_bytes()).hexdigest()
        assert source_hash == hashlib.sha256(audio.read_bytes()).hexdigest()
        summary = {'inputUnchanged': True, 'bpm': beats['bpm'], 'beats': beats['beatCount'],
                   'firstDownbeat': starts[0], 'suggestedPickupBeats': beats['suggestedPickupBeats'],
                   'warnings': beats['warnings'], 'completeBars': len(bars),
                   'sectionBoundaries': len(structure['boundaries']),
                   'listenerReviewRequired': True, 'output': str(root)}
        (root / 'verification.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary), flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        log.close()


if __name__ == '__main__':
    main()
