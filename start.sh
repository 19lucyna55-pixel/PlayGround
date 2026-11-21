#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$PROJECT_DIR"
PORT="${PORT:-3000}"
OUTPUT_DIR="$PROJECT_DIR/dist"
WEB_METADATA_DIR="${OPENCODE_WEB_DIR:-/home/runner/work/_temp/omgithub-web}"

run() {
  /usr/bin/time -p "$@"
}

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { echo "Invalid PORT: $PORT" >&2; exit 1; }
[[ -f "$PROJECT_DIR/index.html" ]] || { echo 'Missing static source: index.html' >&2; exit 1; }

if [[ -f "$PROJECT_DIR/package.json" ]]; then
  if [[ -f "$PROJECT_DIR/package-lock.json" ]]; then
    run npm ci --no-audit --no-fund
  else
    run npm install --no-audit --no-fund
  fi
  run npm run build --if-present
fi

run mkdir -p "$OUTPUT_DIR"
if [[ ! -f "$OUTPUT_DIR/index.html" ]] || ! run cmp -s "$PROJECT_DIR/index.html" "$OUTPUT_DIR/index.html"; then
  run cp "$PROJECT_DIR/index.html" "$OUTPUT_DIR/index.html"
fi

run mkdir -p "$WEB_METADATA_DIR"
run node -e 'const fs=require("node:fs");const path=require("node:path");const project=path.resolve(process.argv[1]);const directory=path.resolve(process.argv[2]);fs.writeFileSync(path.join(process.argv[3],"deployment-output.json"),JSON.stringify({project,directory}));' "$PROJECT_DIR" "$OUTPUT_DIR" "$WEB_METADATA_DIR"

printf 'Serving %s on 0.0.0.0:%s\n' "$OUTPUT_DIR" "$PORT"
exec /usr/bin/time -p python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$OUTPUT_DIR"
