"""Private, parent-owned host for the bundled ChordAdmin analysis service.

No reloader, network downloads or dependency installation occur at runtime.
All writable data goes to the app's Application Support directory.
"""
import json
import os
from pathlib import Path
import secrets
import signal
import sys
import threading
import time


def preflight():
    """Load dependencies and model checkpoints, without analysing any media."""
    import torch
    import librosa
    from numba import njit
    if njit(lambda value: value + 1)(1) != 2:
        raise RuntimeError("The bundled numerical JIT could not initialise.")
    from madmom.features.beats import RNNBeatProcessor
    from madmom.features.downbeats import RNNDownBeatProcessor
    # These lazy attributes must be present in a frozen, offline installation.
    _ = librosa.cqt, librosa.hybrid_cqt, librosa.load, librosa.resample
    _ = librosa.effects.harmonic, librosa.feature.chroma_cqt, librosa.feature.mfcc
    RNNBeatProcessor()
    RNNDownBeatProcessor()
    from services import structure_service
    from services import chord_service
    if not chord_service._is_available():
        raise RuntimeError("Bundled chord model checkpoints are missing.")
    model_dir = chord_service._MODEL_DIR
    previous = Path.cwd()
    sys.path.insert(0, str(model_dir))
    try:
        os.chdir(model_dir)
        from chordnet_ismir_naive import ChordNet
        from mir.nn.train import NetworkInterface
        from extractors.xhmm_ismir import XHMMDecoder
        from chord_recognition import MODEL_NAMES
        XHMMDecoder(template_file="data/submission_chord_list.txt")
        for name in MODEL_NAMES:
            net = NetworkInterface(ChordNet(None), name, load_checkpoint=False)
            del net
    finally:
        os.chdir(previous)
        sys.path.pop(0)
    # Vocal evidence for section names: confirm both models are bundled and
    # their code imports, without loading 700 MB of weights at launch.
    from services import vocal_service
    if not vocal_service.available():
        raise RuntimeError("Bundled vocal separation models are missing.")
    from vendor.demucs.apply import apply_model  # noqa: F401
    from vendor.demucs.htdemucs import HTDemucs  # noqa: F401
    from transformers import Wav2Vec2Config, Wav2Vec2ForCTC  # noqa: F401
    Wav2Vec2Config.from_pretrained(str(vocal_service.PHONEME_DIR), local_files_only=True)
    return {"beats": True, "downbeats": True, "audioStructure": True, "vocalAnalysis": True,
            "chords": True, "translation": True, "torch": torch.__version__}


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(preflight(), sort_keys=True), flush=True)
        return
    token = os.environ.get("CHORDADMIN_RUNTIME_TOKEN", "")
    instance = os.environ.get("CHORDADMIN_RUNTIME_INSTANCE", "")
    parent = int(os.environ.get("CHORDADMIN_PARENT_PID", "0"))
    ready_path = Path(os.environ["CHORDADMIN_READY_FILE"])
    jobs_root = Path(os.environ["CHORDADMIN_JOBS_ROOT"]).resolve()
    if len(token) < 32 or not instance or parent <= 1:
        raise RuntimeError("The managed runtime must be launched by ChordAdmin.")
    # Parent death stops even a startup/import or in-flight inference, so a
    # crashed UI cannot leave an orphan holding audio/model memory indefinitely.
    def watch_parent():
        while True:
            if os.getppid() != parent:
                os._exit(0)
            time.sleep(0.5)
    threading.Thread(target=watch_parent, daemon=True).start()
    capabilities = preflight()
    from app import app
    from flask import g, jsonify, request
    from werkzeug.serving import make_server
    app.config.update(MAX_CONTENT_LENGTH=512 * 1024 * 1024)

    analysis_lock = threading.Lock()

    @app.before_request
    def private_requests_only():
        supplied = request.headers.get("Authorization", "")
        if request.headers.get("Origin") or not secrets.compare_digest(supplied, "Bearer " + token):
            return jsonify({"status": "error", "message": "Unauthorised local analysis request"}), 403
        if request.path != "/health":
            if not analysis_lock.acquire(blocking=False):
                return jsonify({"status": "error", "message": "Another local analysis is still finishing. Try again shortly."}), 409
            g.analysis_lock = True
        if request.path == "/api/translate-to-stagebee":
            data = request.get_json(silent=True) or {}
            try:
                folder = Path(data.get("jobFolderPath", "")).resolve()
                folder.relative_to(jobs_root)
                if folder == jobs_root:
                    raise ValueError("Expected a job folder")
            except (ValueError, TypeError):
                return jsonify({"status": "error", "message": "The job is outside ChordAdmin's job storage"}), 400

    @app.teardown_request
    def release_analysis_lock(error):
        if getattr(g, "analysis_lock", False):
            analysis_lock.release()

    def health():
        return jsonify(status="healthy", service="ChordAdminBackend", version="managed-1",
                       instance=instance, capabilities=capabilities)
    app.view_functions["health.health"] = health
    # Health remains responsive during inference. Other requests are serialised
    # because the inherited chord adapter temporarily changes cwd.
    server = make_server("127.0.0.1", 0, app, threaded=True)
    info = {"port": server.server_port, "pid": os.getpid(), "instance": instance}
    ready_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = ready_path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(info, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, ready_path)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        ready_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
