#!/usr/bin/env bash
set -euo pipefail
study_root="${OPUS_STUDY_ROOT:-/Volumes/DATA/Murmur-models/opus-quality}"
shared_python="${OMNI_PYTHON:-/Volumes/DATA/omni-bench/python/.venv/bin/python}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
normalization_python="$study_root/normalization-env/bin/python"
if [[ ! -x "$normalization_python" ]]; then
  /opt/homebrew/bin/uv venv --python "$shared_python" "$study_root/normalization-env"
fi
# Hide the read-only dependency path during installation so the package manager
# only considers packages physically owned by this isolated environment.
"$normalization_python" - <<'PY'
import sysconfig
from pathlib import Path
(Path(sysconfig.get_paths()['purelib'])/'murmur-shared-readonly.pth').write_text('')
PY
/opt/homebrew/bin/uv pip install --python "$normalization_python" -r "$script_dir/normalization-requirements.txt"
"$normalization_python" - "$shared_python" <<'PY'
import subprocess,sys,sysconfig
from pathlib import Path
shared=subprocess.check_output([sys.argv[1],'-c','import sysconfig;print(sysconfig.get_paths()["purelib"])'],text=True).strip()
(Path(sysconfig.get_paths()['purelib'])/'murmur-shared-readonly.pth').write_text(shared+'\n/Volumes/DATA/omni-bench/python/src\n')
PY
