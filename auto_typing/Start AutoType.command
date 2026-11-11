#!/bin/zsh
set -eu
cd -- "${0:A:h}"
# Keep the signed app outside synced source folders, whose Finder metadata can
# invalidate code signing. The source and launcher remain in this folder.
app="$HOME/Applications/AutoType.app"
binary="$app/Contents/MacOS/AutoType"
settings_dir="$HOME/Library/Application Support/AutoType"
identity_file="$settings_dir/signing-identity"
# Pin a real development identity: ad-hoc signing changes TCC identity on every
# rebuild. Never silently fall back to ad-hoc signing if the certificate expires.
if [[ -n "${AUTOTYPE_SIGNING_IDENTITY:-}" ]]; then
    signing_identity="$AUTOTYPE_SIGNING_IDENTITY"
elif [[ -f "$identity_file" ]]; then
    signing_identity="$(cat "$identity_file")"
else
    identity_output="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')"
    signing_identities=("${(@f)identity_output}")
    if [[ ${#signing_identities} -ne 1 || -z "$identity_output" ]]; then
        print 'Choose an existing Apple Development certificate using AUTOTYPE_SIGNING_IDENTITY.'
        print 'No certificate was created or purchased. AutoType was not changed.'
        exit 1
    fi
    signing_identity="${signing_identities[1]}"
fi
if [[ ! -x "$binary" || AutoType.swift -nt "$binary" || "$0" -nt "$binary" || "$identity_file" -nt "$binary" ]] || ! codesign --verify "$app" 2>/dev/null; then
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        print 'Apple Command Line Tools are required. Run: xcode-select --install'
        read -r '?Press Enter to close.'
        exit 1
    fi
    mkdir -p "$HOME/Applications" "$settings_dir"
    staging_dir="$(mktemp -d "$HOME/Applications/.AutoType-build.XXXXXX")"
    trap 'rm -rf -- "$staging_dir"' EXIT
    staging_app="$staging_dir/AutoType.app"
    mkdir -p "$staging_app/Contents/MacOS"
    print 'Building AutoType…'
    xcrun swiftc -O AutoType.swift -o "$staging_app/Contents/MacOS/AutoType" -framework Cocoa -framework ApplicationServices -framework Carbon -framework Vision
    cat > "$staging_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AutoType</string>
<key>CFBundleIdentifier</key><string>local.autotype.utility</string>
<key>CFBundleName</key><string>AutoType</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>AutoType detects your typed trigger and types your selected text.</string>
</dict></plist>
PLIST
    # Finder metadata inherited by newly generated files can prevent signing.
    xattr -cr "$staging_app"
    codesign --force --sign "$signing_identity" --timestamp=none --identifier local.autotype.utility "$staging_app"
    codesign --verify --strict "$staging_app"
    "$staging_app/Contents/MacOS/AutoType" --self-test
    # Do not replace the working app unless the new build and signature pass.
    if [[ -d "$app" ]]; then mv "$app" "$staging_dir/previous.app"; fi
    if ! mv "$staging_app" "$app"; then
        if [[ -d "$staging_dir/previous.app" ]]; then mv "$staging_dir/previous.app" "$app"; fi
        exit 1
    fi
    if [[ ! -f "$identity_file" || "$(cat "$identity_file")" != "$signing_identity" ]]; then
        print -r -- "$signing_identity" > "$identity_file"
        touch "$binary"
    fi
fi
if [[ "${1:-}" == '--self-test' ]]; then
    exec "$binary" --self-test
elif [[ "${1:-}" != '--build-only' ]]; then
    # New versions handle SIGTERM by saving any pending text and quitting.
    python3 - "$binary" <<'PY'
import os, signal, subprocess, sys, time
binary = sys.argv[1]
pids = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    pid, command = line.strip().split(None, 1)
    if command in (binary, binary + ' --preview'):
        pids.append(int(pid))
for pid in pids:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
deadline = time.monotonic() + 5
while pids:
    alive = []
    for pid in pids:
        try:
            os.kill(pid, 0)
            alive.append(pid)
        except ProcessLookupError:
            pass
    pids = alive
    if pids and time.monotonic() >= deadline:
        sys.exit('AutoType is still closing. Quit it from the AT menu, then launch again.')
    if pids:
        time.sleep(0.1)
PY
    open "$app"
fi
