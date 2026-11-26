#!/usr/bin/env bash
# Copy a local Paykit v0.2 build (module PaykitV2) into LocalPackages/PaykitV2.
#
# The build comes from paykit-rs `paykit-ffi/build-ios-renamed.sh`, which writes a Swift package with
# PaykitV2FFI.xcframework and Sources/PaykitV2/*.swift. Only those two parts are copied; the committed
# LocalPackages/PaykitV2/Package.swift stays as it is. Both copied parts are gitignored.
#
# Usage: scripts/fetch-paykit-v2.sh [path to the built PaykitV2 package]
#   The default source is $PAYKIT_V2_BUILD, or ../.build/ffi-v2/PaykitV2 next to this checkout.
#
# After a new copy, Xcode may keep the old framework module cache. Clean the build folder if the
# bindings changed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_source="$(cd "$repo_root/.." && pwd)/.build/ffi-v2/PaykitV2"
source_dir="${1:-${PAYKIT_V2_BUILD:-$default_source}}"
target_dir="$repo_root/LocalPackages/PaykitV2"

if [[ ! -d "$source_dir/PaykitV2FFI.xcframework" || ! -d "$source_dir/Sources/PaykitV2" ]]; then
    echo "error: no PaykitV2 build at $source_dir" >&2
    echo "Build it with paykit-ffi/build-ios-renamed.sh in paykit-rs, or pass its path." >&2
    exit 1
fi

rm -rf "$target_dir/PaykitV2FFI.xcframework" "$target_dir/Sources"
mkdir -p "$target_dir/Sources/PaykitV2"
cp -R "$source_dir/PaykitV2FFI.xcframework" "$target_dir/PaykitV2FFI.xcframework"
cp "$source_dir"/Sources/PaykitV2/*.swift "$target_dir/Sources/PaykitV2/"

echo "Copied PaykitV2 from $source_dir"
ls "$target_dir/PaykitV2FFI.xcframework" "$target_dir/Sources/PaykitV2"
