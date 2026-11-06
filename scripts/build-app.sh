#!/bin/zsh
set -eu

task_root="${0:A:h:h}"
cd "$task_root"
swift build -c release
task_bin_dir="$(swift build -c release --show-bin-path)"
task_bundle="$task_root/dist/Q2C.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
cp "$task_bin_dir/Q2C" "$task_bundle/Contents/MacOS/Q2C.new"
mv -f "$task_bundle/Contents/MacOS/Q2C.new" "$task_bundle/Contents/MacOS/Q2C"
cp "$task_root/app/Resources/Q2C.icns" "$task_bundle/Contents/Resources/Q2C.icns"
cp "$task_root/app/Info.plist" "$task_bundle/Contents/Info.plist"
signing_identity="${Q2C_CODESIGN_IDENTITY:-Q2C Local Dev}"
available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if print -r -- "$available_identities" | grep -Fq "\"$signing_identity\"" || \
   print -r -- "$available_identities" | grep -Fq "$signing_identity"; then
  print -r -- "Signing with: $signing_identity"
  codesign --force --sign "$signing_identity" "$task_bundle"
elif [[ -n "${Q2C_CODESIGN_IDENTITY:-}" ]]; then
  print -u2 -r -- "Code signing identity not found: $Q2C_CODESIGN_IDENTITY"
  print -u2 -r -- 'Create it in Keychain Access or unset Q2C_CODESIGN_IDENTITY to use ad-hoc signing.'
  exit 1
else
  print -r -- 'Q2C Local Dev identity not found; using ad-hoc signing.'
  print -r -- 'Create a stable Code Signing identity to keep Accessibility authorization across debug builds.'
  codesign --force --sign - "$task_bundle"
fi
codesign --verify --strict "$task_bundle"
print -r -- "Built: $task_bundle"
