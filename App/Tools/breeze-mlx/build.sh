#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
work="$root/.build/breeze-mlx-runtime"
destination="$1"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
mkdir -p "$work"
fingerprint="$(cat "$here/worker.py" "$here/build.sh" "$here/requirements.txt" | shasum -a 256)"
if [[ ! -x "$work/dist/BreezeMLX.app/Contents/MacOS/BreezeMLX" || "$(cat "$work/stamp" 2>/dev/null || true)" != "$fingerprint $identity" ]]; then
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    export UV_CACHE_DIR="$work/uv" UV_PYTHON_INSTALL_DIR="$work/python" PYINSTALLER_CONFIG_DIR="$work/pyinstaller"
    uv venv --allow-existing --managed-python --python 3.11 "$work/venv"
    uv pip install --python "$work/venv/bin/python" -r "$here/requirements.txt"
    # Preserve mlx-whisper's DTW algorithm for word times. Running its two loops as
    # Python avoids LLVM JIT executable pages inside the hardened macOS helper.
    "$work/venv/bin/python" - <<'PYTHON'
import sysconfig
from pathlib import Path
path = Path(sysconfig.get_path("purelib")) / "mlx_whisper/timing.py"
source = path.read_text()
if "import numba" in source:
    for statement in ["import numba\n", "@numba.jit(nopython=True)\n", "@numba.jit(nopython=True, parallel=True)\n"]:
        assert statement in source
        source = source.replace(statement, "")
    path.write_text(source)
PYTHON
    stdlib="$("$work/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
    "$work/venv/bin/python" -m PyInstaller --noconfirm --clean --onedir --windowed --osx-bundle-identifier dev.mm2t.breeze-mlx --name BreezeMLX \
        --workpath "$work/work" --distpath "$work/dist" --specpath "$work" \
        --codesign-identity "$identity" --collect-all mlx --collect-data mlx_whisper \
        --add-data "$stdlib/LICENSE.txt:licenses/CPython" --collect-all tiktoken_ext \
        --copy-metadata scipy --copy-metadata tiktoken --copy-metadata regex --copy-metadata certifi \
        --exclude-module numba --exclude-module llvmlite --exclude-module torch \
        --exclude-module matplotlib --exclude-module transformers "$here/worker.py"
    printf '%s\n' "$fingerprint $identity" > "$work/stamp"
fi
# Replace the entire signed bundle. Merging leaves obsolete libraries after upgrades.
mkdir -p "$(dirname "$destination")"
stage="$(mktemp -d "$(dirname "$destination")/.breeze-mlx.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$work/dist/BreezeMLX.app" "$stage/BreezeMLX.app"
if [[ -e "$destination" ]]; then mv "$destination" "$stage/previous.app"; fi
if ! mv "$stage/BreezeMLX.app" "$destination"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$destination"; fi
    exit 1
fi
