#!/usr/bin/env bash
# Installs the Android SDK platform 34 + matching build-tools into the
# persisted ANDROID_SDK_ROOT, accepting licences non-interactively. Idempotent
# (sdkmanager no-ops on packages already installed) and safe to run either
# backgrounded from entrypoint.sh on container start, or synchronously (used
# directly by test/smoke.sh) since a completed install returns quickly.
set -euo pipefail

SDKMANAGER="/opt/android-cmdline-tools/latest/bin/sdkmanager"
SDK_ROOT="${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT must be set}"

mkdir -p "$SDK_ROOT"

# entrypoint.sh backgrounds this script and test/smoke.sh also runs it
# synchronously (to avoid racing the background copy) — flock serialises any
# overlapping invocations so two sdkmanager processes never write the same
# SDK root concurrently. The second invocation blocks, then no-ops through
# the idempotent install once the first finishes.
exec 9>"$SDK_ROOT/.bootstrap.lock"
flock 9

# `yes` outlives sdkmanager's reads and gets SIGPIPE once sdkmanager stops
# consuming stdin; under `set -o pipefail` that failure (128+13=141) would
# otherwise abort the script here, before the actual install below ever runs.
yes | "$SDKMANAGER" --sdk_root="$SDK_ROOT" --licenses >/dev/null || true

"$SDKMANAGER" --sdk_root="$SDK_ROOT" \
  "platform-tools" \
  "platforms;android-34" \
  "build-tools;34.0.0"

echo "Android SDK bootstrap complete: platform 34 + build-tools installed at $SDK_ROOT."
