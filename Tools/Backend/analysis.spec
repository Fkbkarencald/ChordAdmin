# PyInstaller 6.16.0; the build driver supplies exact local build inputs.
import json
import os
from pathlib import Path
source = Path(os.environ['CHORDADMIN_FREEZE_SOURCE'])
inputs = json.loads(Path(os.environ['CHORDADMIN_FREEZE_INPUTS']).read_text())
identity = os.environ['CHORDADMIN_FREEZE_IDENTITY']
a = Analysis([str(Path(SPECPATH) / 'managed_server.py')],
    pathex=[str(source), str(source / 'models/Chord-CNN-LSTM')],
    binaries=inputs['binaries'], datas=inputs['data'],
    hiddenimports=inputs['hidden'] + ['chord_recognition', 'mir.nn.train', 'extractors.cqt', 'io_new.chordlab_io'],
    excludes=['tkinter', 'IPython', 'pytest', 'matplotlib', 'tensorboard'],
    module_collection_mode={'librosa': 'pyz+py', 'numba': 'pyz+py'})
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='chordadmin-analysis',
    console=True, target_arch='arm64', codesign_identity=None if identity == '-' else identity)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='LocalAnalysis')

app = BUNDLE(coll, name='ChordAdminAnalysis.app', icon=None,
    bundle_identifier='com.tanaquiapps.ChordAdmin.analysis',
    info_plist={'LSUIElement': True, 'LSBackgroundOnly': True,
                'CFBundleName': 'ChordAdmin local analysis'})
