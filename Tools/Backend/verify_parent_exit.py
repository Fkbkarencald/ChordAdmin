#!/usr/bin/env python3
"""Check the packaged helper exits when its owning process disappears."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

executable = str(Path(sys.argv[1]).resolve())
root = Path(tempfile.mkdtemp(prefix='chordadmin-parent-exit-'))
parent_script = root / 'parent.py'
parent_script.write_text('''import json,os,subprocess,sys,time
from pathlib import Path
root=Path(sys.argv[2]); (root/'cache').mkdir(); (root/'temp').mkdir(); (root/'jobs').mkdir()
env=dict(os.environ,CHORDADMIN_RUNTIME_TOKEN='test-parent-token-with-more-than-thirty-two-characters',
 CHORDADMIN_RUNTIME_INSTANCE='parent-exit-test',CHORDADMIN_PARENT_PID=str(os.getpid()),
 CHORDADMIN_READY_FILE=str(root/'ready.json'), CHORDADMIN_CACHE_DIR=str(root/'cache'),
 CHORDADMIN_TEMP_DIR=str(root/'temp'), CHORDADMIN_JOBS_ROOT=str(root/'jobs'),NUMBA_CACHE_DIR=str(root/'numba'))
with (root/'runtime.log').open('w') as log:
 child=subprocess.Popen([sys.argv[1]],env=env,stdout=log,stderr=log)
 for attempt in range(400):
  if (root/'ready.json').exists():
   print(json.dumps({'pid':child.pid}),flush=True);os._exit(0)
  if child.poll() is not None:raise RuntimeError('Helper exited before readiness')
  time.sleep(.1)
 child.terminate();raise RuntimeError('Helper readiness timed out')
''')
parent = subprocess.run([sys.executable, str(parent_script), executable, str(root)], capture_output=True, text=True, timeout=50)
if parent.returncode:
    raise RuntimeError(parent.stderr + (root / 'runtime.log').read_text())
pid = json.loads(parent.stdout)['pid']
for attempt in range(80):
    # A reparented process can briefly be a zombie before launchd reaps it.
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    if result.returncode or result.stdout.strip().startswith('Z'):
        print('Parent-exit check passed: its helper stopped; no media was analysed.')
        break
    time.sleep(.1)
else:
    raise RuntimeError('The helper outlived its parent')
