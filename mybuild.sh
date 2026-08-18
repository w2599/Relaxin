#!/bin/bash

set -e

pkill -f 'xcodebuild' || true
pkill -f 'run-xcodebuild.sh' || true
pkill -f 'build-basebin-resources.sh' || true
pkill -f 'make.*BaseBin' || true
pkill -f 'swiftc' || true
pkill -f 'clang' || true


cd "$(dirname "$0")" || exit 1

# rm -rf /tmp/relaxin-deriveddata
APP_VERSION=$(awk -F= '/^MARKETING_VERSION/ {gsub(/ /, "", $2); print $2; exit}' Configuration/Version.xcconfig)
CURRENT_PROJECT_VERSION=$(awk -F= '/^CURRENT_PROJECT_VERSION/ {gsub(/ /, "", $2); print $2; exit}' Configuration/Version.xcconfig)


Threads="-j1"
if [ -n "$1" ]; then
    Threads="-j$1"
fi

echo $Threads


make ipa tipa \
     $Threads \
     CONFIGURATION=Release \
     DERIVED_DATA="/tmp/relaxin-deriveddata" \
     IPA_OUTPUT="${HOME}/www/html/TS/Relaxin_v${APP_VERSION}_${CURRENT_PROJECT_VERSION}_whitelist_17.0.ipa" \
     TIPA_OUTPUT="${HOME}/www/html/TS/Relaxin_v${APP_VERSION}_${CURRENT_PROJECT_VERSION}_whitelist_17.0.tipa"

