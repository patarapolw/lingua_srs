#!/usr/bin/env bash
# Installs the Dart SDK alone (no Flutter), for running `dart format` where
# Flutter is not available, such as a Claude cloud session. See AGENTS.md.
#
#   tool/install_dart_sdk.sh [version]   # default: the latest stable release
#
# It downloads Google's official SDK zip from storage.googleapis.com and checks
# it against the published SHA-256. That host is on the cloud sessions' default
# (Trusted) allowlist, unlike micro.mamba.pm and api.anaconda.org, which the
# micromamba installer needs. Installs into $DART_SDK_DIR (default
# ~/.dart-sdk) and prints the path of the `dart` binary. Does nothing if that
# version is there already.
set -euo pipefail

base=https://storage.googleapis.com/dart-archive/channels/stable/release
dest=${DART_SDK_DIR:-$HOME/.dart-sdk}
curl_get() { curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors "$@"; }

version=${1:-}
if [[ -z $version ]]; then
  version=$(curl_get "$base/latest/VERSION" |
    sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
  [[ -n $version ]] || { echo "Could not read the latest Dart version." >&2; exit 1; }
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

if [[ -x $dest/bin/dart ]] &&
  [[ $("$dest/bin/dart" --version 2>&1) == *"version: $version "* ]]; then
  echo "$dest/bin/dart"
  exit 0
fi

zip=dartsdk-$os-$arch-release.zip
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Dart SDK $version ($os-$arch)..." >&2
curl_get -o "$tmp/$zip" "$base/$version/sdk/$zip"
expected=$(curl_get "$base/$version/sdk/$zip.sha256sum" | cut -d' ' -f1)
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/$zip" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$zip" | cut -d' ' -f1)
fi
if [[ $actual != "$expected" ]]; then
  echo "Checksum mismatch for $zip: expected $expected, got $actual." >&2
  exit 1
fi

unzip -q "$tmp/$zip" -d "$tmp"
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$tmp/dart-sdk" "$dest"
"$dest/bin/dart" --version >&2
echo "$dest/bin/dart"
