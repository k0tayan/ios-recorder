#!/bin/bash
# inject.sh - Inject the recorder dylib into a target app using Frida
#
# Usage:
#   ./inject.sh [app_name_or_bundle_id]
#
# Examples:
#   ./inject.sh "ProjectSekai"
#   ./inject.sh com.sega.pjsekai
#
# Prerequisites:
#   - Frida installed on both PC and iOS device
#   - USB connection to the device

set -e

TARGET="${1:-com.sega.pjsekai}"
DYLIB_PATH="/Library/MobileSubstrate/DynamicLibraries/iosrecorder.dylib"

echo "[*] iOS App Recorder - Frida Injector"
echo "[*] Target: $TARGET"
echo "[*] Dylib: $DYLIB_PATH"

# Check if Frida is available
if ! command -v frida &> /dev/null; then
    echo "[!] Frida is not installed. Install with: pip install frida-tools"
    exit 1
fi

# Create loader script
LOADER_JS=$(mktemp /tmp/recorder_loader_XXXXXX.js)
cat > "$LOADER_JS" << 'JSEOF'
// Loader script for iOS App Recorder
console.log("[Recorder] Loading dylib via Frida...");

var dylibPath = "/Library/MobileSubstrate/DynamicLibraries/iosrecorder.dylib";
var handle = Module.load(dylibPath);

if (handle) {
    console.log("[Recorder] dylib loaded successfully at: " + handle.base);
} else {
    console.log("[Recorder] Failed to load dylib!");
}

// Keep the script running
console.log("[Recorder] Injection complete. Use socket commands to control recording.");
console.log("[Recorder] Socket: /tmp/ios_recorder.sock");
console.log("[Recorder] Commands: START, STOP, STATUS");
JSEOF

echo "[*] Loading dylib into $TARGET..."
frida -U -n "$TARGET" -l "$LOADER_JS" --no-pause

# Cleanup
rm -f "$LOADER_JS"
