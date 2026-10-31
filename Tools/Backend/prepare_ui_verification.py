#!/usr/bin/env python3
"""Prepare the stub-Firebase app for native runtime/layout checks only."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import wave
root = Path(__file__).resolve().parents[2]
bundle = root / 'Tools/.build/ChordAdmin.app'
helper = bundle / 'Contents/Helpers/ChordAdminAnalysis.app'
helper.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'Tools/.runtime-dist/ChordAdminAnalysis.app', helper, symlinks=True, dirs_exist_ok=True)
fixture = Path(tempfile.mkdtemp(prefix='chordadmin-ui-isolated-'))
jobdir = fixture / 'jobs/offline-fixture'
jobdir.mkdir(parents=True)
with wave.open(str(jobdir / 'analysis.wav'), 'wb') as audio:
    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(44100)
    audio.writeframes(b'\0\0' * 44100)
(jobdir / 'job.json').write_text(json.dumps({
    'id': 'offline-fixture', 'sourceUrl': 'https://youtu.be/layoutfixture', 'status': 'audioReady',
    'createdAt': '2026-10-27T00:00:00Z', 'title': 'Offline layout fixture',
    'songDocumentID': 'offline-layout-song', 'analysisWavPath': str(jobdir / 'analysis.wav'),
}))
path = bundle / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['LSEnvironment'] = {'CHORDADMIN_JOBS_DIR': str(fixture)}
info['CFBundleDisplayName'] = 'ChordAdmin Local Verification'
path.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
print(bundle)
print('Synthetic job storage:', fixture)
print('No account, real recordings or production data are used by this UI build.')
