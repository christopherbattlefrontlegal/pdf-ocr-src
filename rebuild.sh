#!/bin/zsh
# Rebuild + codesign + install pdf-ocr.
# Without codesign --force --sign -, swift build's linker-signed binary gets
# SIGKILL'd at launch from Quick Actions (Code Signature Invalid). With it, runs.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
cp .build/release/pdf-ocr /Users/studio/bin/pdf-ocr
codesign --force --sign - /Users/studio/bin/pdf-ocr
echo "Installed: $(ls -la /Users/studio/bin/pdf-ocr)"
echo "MD5: $(md5 -q /Users/studio/bin/pdf-ocr)"
