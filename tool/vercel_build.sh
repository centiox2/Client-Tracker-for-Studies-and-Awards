#!/usr/bin/env bash
# Builds the web version on Vercel (which has no Flutter): downloads the
# same Flutter version the apps are built with, then builds into build/web.
# The online database's address and publishable key are the same ones the
# Windows and Android builds use (.github/workflows/windows-build.yml);
# reading data still needs a profile sign-in.
set -euo pipefail

FLUTTER_VERSION="3.47.9"
SUPABASE_URL="${SUPABASE_URL:-https://dpmluuckgstycdctqwym.supabase.co}"
SUPABASE_KEY="${SUPABASE_KEY:-sb_publishable_qsw0KVpDbNr616WaSmG70w_QplfFMPs}"

if [ ! -x .flutter/bin/flutter ]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git .flutter
fi
export PATH="$PWD/.flutter/bin:$PATH"
flutter config --no-analytics --enable-web >/dev/null
flutter --version
flutter pub get
flutter build web --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_KEY="$SUPABASE_KEY"
