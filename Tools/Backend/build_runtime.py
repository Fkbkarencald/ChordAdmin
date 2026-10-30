#!/usr/bin/env python3
"""Freeze the verified local backend, model weights and native media tools.

Run with ChordAdminBackend's Python 3.9 environment. The produced directory is
relocatable and needs neither that environment nor Homebrew at runtime.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "Tools"


VOCAL_MODELS = ("htdemucs", "wav2vec2-xlsr-53-espeak-cv-ft")
# transformers loads model code lazily and checks these distributions at import.
TRANSFORMERS_METADATA = ("transformers", "tokenizers", "huggingface-hub", "safetensors", "regex", "tqdm",
                         "requests", "packaging", "filelock", "numpy", "pyyaml", "fsspec")


def prepare(source, stage):
    stage.mkdir(parents=True, exist_ok=True)
    for name in ("routes", "services", "vendor"):
        shutil.copytree(source / name, stage / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy2(source / "app.py", stage / "app.py")
    changes = {
        "services/cache_service.py": (
            'CACHE_DIR = Path(__file__).parent.parent / "cache"',
            'CACHE_DIR = Path(os.environ["CHORDADMIN_CACHE_DIR"])'),
        "services/audio_service.py": (
            'TEMP_DIR = Path(__file__).parent.parent / "temp"',
            'TEMP_DIR = Path(os.environ["CHORDADMIN_TEMP_DIR"])'),
    }
    for name, (before, after) in changes.items():
        path = stage / name
        text = path.read_text()
        if before not in text:
            raise RuntimeError("Backend source changed; review storage adapter: " + name)
        path.write_text("import os\n" + text.replace(before, after))
    # Cache writes must be atomic if the parent quits during an analysis.
    cache = stage / "services/cache_service.py"
    text = cache.read_text().replace('with open(path, "w") as f:', 'with open(str(path) + ".tmp", "w") as f:')
    text = text.replace('            json.dump(data, f)\n', '            json.dump(data, f)\n        os.replace(str(path) + ".tmp", path)\n')
    cache.write_text(text)
    model_source = source / "models/Chord-CNN-LSTM"
    model = stage / "models/Chord-CNN-LSTM"
    shutil.copytree(model_source, model, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"))
    # Vocal separation and phoneme models: safetensors only, never pickles.
    for name in VOCAL_MODELS:
        if not (source / "models" / name / "model.safetensors").is_file():
            raise RuntimeError("Build input is missing: models/" + name)
        shutil.copytree(source / "models" / name, stage / "models" / name, dirs_exist_ok=True)
    return model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("/Volumes/ChordAdminBackendArchive/ChordAdminBackend"))
    parser.add_argument("--identity", default="-")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    stage = TOOLS / ".runtime-build/source"
    model = prepare(args.source, stage)
    if args.prepare_only:
        print(stage)
        return
    from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata
    binaries = []
    data = [(str(model), "models/Chord-CNN-LSTM")]
    data += [(str(stage / "models" / name), "models/" + name) for name in VOCAL_MODELS]
    for distribution in TRANSFORMERS_METADATA:
        data += copy_metadata(distribution)
    hidden = collect_submodules("transformers.models.wav2vec2") + collect_submodules("vendor.demucs")
    for package in ("madmom", "librosa"):
        package_data, package_bins, package_hidden = collect_all(package)
        data += package_data
        binaries += package_bins
        hidden += package_hidden
    for tool in ("ffmpeg", "ffprobe", "deno"):
        path = shutil.which(tool)
        if not path:
            raise RuntimeError("Build input is missing: " + tool)
        binaries.append((str(Path(path).resolve()), "bin"))
    downloader = TOOLS / ".runtime-downloads/yt-dlp_macos"
    lock = json.loads((TOOLS / "Backend/download-tools.lock.json").read_text())["yt-dlp"]
    if not downloader.exists():
        import urllib.request
        downloader.parent.mkdir(parents=True, exist_ok=True)
        downloader.write_bytes(urllib.request.urlopen(lock["url"]).read())
        downloader.chmod(0o755)
    if hashlib.sha256(downloader.read_bytes()).hexdigest() != lock["sha256"]:
        raise RuntimeError("Standalone yt-dlp checksum mismatch")
    # PyInstaller preserves executable basenames.
    packaged_downloader = stage / "yt-dlp"
    shutil.copy2(downloader, packaged_downloader)
    binaries.append((str(packaged_downloader), "bin"))
    config = {"data": data, "binaries": binaries, "hidden": hidden}
    config_path = TOOLS / ".runtime-build/inputs.json"
    config_path.write_text(json.dumps(config))
    spec = TOOLS / "Backend/analysis.spec"
    env = dict(os.environ, CHORDADMIN_FREEZE_SOURCE=str(stage), CHORDADMIN_FREEZE_INPUTS=str(config_path),
               CHORDADMIN_FREEZE_IDENTITY=args.identity,
               CHORDADMIN_CACHE_DIR=str(TOOLS / ".runtime-build/cache"),
               CHORDADMIN_TEMP_DIR=str(TOOLS / ".runtime-build/temp"))
    Path(env["CHORDADMIN_CACHE_DIR"]).mkdir(parents=True, exist_ok=True)
    Path(env["CHORDADMIN_TEMP_DIR"]).mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--distpath", str(TOOLS / ".runtime-dist"),
                    "--workpath", str(TOOLS / ".runtime-build/pyinstaller"), str(spec)], env=env, check=True)
    output = TOOLS / ".runtime-dist/ChordAdminAnalysis.app/Contents/Resources"
    notices = output / "Licences"
    notices.mkdir(exist_ok=True)
    shutil.copy2(model / "LICENSE", notices / "Chord-CNN-LSTM-MIT.txt")
    import madmom
    shutil.copy2(Path(madmom.__file__).parent / "models/LICENSE", notices / "madmom-models.txt")
    shutil.copy2(stage / "vendor/demucs/LICENSE", notices / "Demucs-htdemucs-MIT.txt")
    shutil.copy2(stage / "vendor/demucs/LICENSE-openunmix", notices / "openunmix-filtering-MIT.txt")
    (notices / "wav2vec2-xlsr-53-espeak-cv-ft.txt").write_text(
        "facebook/wav2vec2-xlsr-53-espeak-cv-ft (Hugging Face), Apache License 2.0.\n"
        "Converted to float16 safetensors for ChordAdmin; weights otherwise unchanged.\n")
    # Retain the complete installed distribution notices for all collected deps.
    import importlib.metadata
    for distribution in importlib.metadata.distributions():
        for item in distribution.files or []:
            if any(word in str(item).lower() for word in ("license", "licence", "copying", "copyright")):
                src = distribution.locate_file(item)
                if src.is_file():
                    dst = notices / distribution.metadata.get("Name", "unknown") / str(item).replace("..", "_")
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
    manifest = {"version": 1, "architecture": "arm64", "python": sys.version.split()[0],
                "backendSource": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.source).decode().strip(),
                "backendSourceDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=args.source).strip()),
                "backendFiles": {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for directory in (stage / "services", stage / "routes")
                                 for p in directory.glob("*.py")},
                "models": {**{p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (model / "cache_data").glob("*.sdict")},
                           **{name + "/model.safetensors": hashlib.sha256((stage / "models" / name / "model.safetensors").read_bytes()).hexdigest()
                              for name in VOCAL_MODELS}},
                "packager": "PyInstaller 6.16.0", "downloader": lock, "distribution": "development; third-party model licence review required"}
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    helper = output.parent.parent
    # Keep upstream's standalone downloader signature. Re-signing only its
    # outer one-file executable breaks validation of its extracted Python libs.
    shutil.copy2(downloader, helper / 'Contents/Frameworks/bin/yt-dlp')
    print(output)


if __name__ == "__main__":
    main()
