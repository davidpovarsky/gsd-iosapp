#!/usr/bin/env bash
# Build the real native GSD iPad app with Hanlin AI and Remote MCP.
# Produce two unsigned IPA archives: full and sideload-compatible without
# nested app extensions. Neither is installable until properly signed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${GSD_IPA_CONFIGURATION:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "Unsupported configuration: $CONFIGURATION" >&2; exit 2 ;;
esac
DERIVED="${GSD_DERIVED_DIR:-$ROOT/.gsd-hanlin-derived}"
OUTPUT="${GSD_IPA_OUTPUT_DIR:-$ROOT/dist/gsd-hanlin-ipad}"
mkdir -p "$OUTPUT" "$DERIVED"

set -o pipefail
xcodebuild -project "$ROOT/GSD.xcodeproj" \
  -scheme GSD \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$OUTPUT/gsd-hanlin-build.log"

APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/GSD.app"
[[ -d "$APP" ]] || { echo "GSD.app missing at $APP" >&2; exit 1; }
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || { echo "GSD Info.plist missing" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
[[ " $ARCHS " == *" arm64 "* ]] || { echo "No arm64 device binary" >&2; exit 1; }
[[ -n "$BUNDLE_ID" ]] || { echo "No bundle identifier" >&2; exit 1; }

TMP="$OUTPUT/.gsd-ipa-payload"
rm -rf "$TMP"
mkdir -p "$TMP/Payload"
ditto "$APP" "$TMP/Payload/GSD.app"
FULL="$OUTPUT/GSD-Hanlin-iPad-$VERSION+$BUILD_NUMBER-UNSIGNED.ipa"
rm -f "$FULL"
(cd "$TMP" && zip -qry "$FULL" Payload)
unzip -tq "$FULL" > "$OUTPUT/gsd-ipa-zip-check.txt"
rm -rf "$TMP"

SIDE="$OUTPUT/GSD-Hanlin-iPad-$VERSION+$BUILD_NUMBER-SIDELOAD-NO-EXTENSIONS-UNSIGNED.ipa"
python3 "$ROOT/scripts/package_gsd_sideload_ipa.py" \
  --source "$FULL" \
  --output "$SIDE" \
  --manifest "$OUTPUT/GSD-Hanlin-iPad-manifest.json"

export FULL SIDE BUNDLE_ID EXECUTABLE VERSION BUILD_NUMBER CONFIGURATION ARCHS
python3 - <<'PY'
import json,os,zipfile,plistlib,hashlib,pathlib
full=pathlib.Path(os.environ['FULL']);side=pathlib.Path(os.environ['SIDE'])
for p in (full,side):
    with zipfile.ZipFile(p) as z:
        assert z.testzip() is None
        names=z.namelist()
        info=plistlib.loads(z.read('Payload/GSD.app/Info.plist'))
        assert info['CFBundleIdentifier']==os.environ['BUNDLE_ID']
        assert 'Payload/GSD.app/'+info['CFBundleExecutable'] in names
        if p==side:
            assert not any('/PlugIns/' in n or '/Watch/' in n or
                           '/Extensions/' in n for n in names)
        print('GSD IPA:',p.name,'archive bytes',p.stat().st_size,
              'entries',len(names),'signed',False)
        print('sha256',hashlib.sha256(p.read_bytes()).hexdigest())
manifest=pathlib.Path(os.environ['FULL']).parent/'GSD-Hanlin-iPad-build-info.json'
manifest.write_text(json.dumps({
 'app':'GSD Hanlin iPad', 'configuration':os.environ['CONFIGURATION'],
 'version':os.environ['VERSION'],'build':os.environ['BUILD_NUMBER'],
 'bundleID':os.environ['BUNDLE_ID'],'architectures':os.environ['ARCHS'].split(),
 'signed':False,'deviceInstallTested':False,'chatGPTPairingTested':False,
 'warning':'Must sign the IPA before installing. Sideload variant omits app extensions.'
},indent=2)+'\n',encoding='utf8')
PY
echo "GSD iPad full and sideload unsigned IPA archives exported in $OUTPUT"
