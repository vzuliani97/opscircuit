#!/usr/bin/env bash
# Downloads pinned versions of kind, kubeconform and the Kyverno CLI into ./bin and verifies their SHA-256 checksums.
# Nothing is installed system-wide. kubectl and Docker are expected to be installed already.
set -euo pipefail

KIND_VERSION="v0.33.0"
KUBECONFORM_VERSION="v0.8.0"
KYVERNO_VERSION="v1.19.1" # keep in sync with KYVERNO_VERSION in the Makefile

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [[ ! -x "$BIN/kind" ]]; then
  url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}"
  curl -fsSLo "$BIN/kind" "$url"
  expected="$(curl -fsSL "${url}.sha256sum" | cut -d' ' -f1)"
  [[ "$(sha256 "$BIN/kind")" == "$expected" ]] || { echo "kind checksum mismatch" >&2; rm -f "$BIN/kind"; exit 1; }
  chmod +x "$BIN/kind"
fi

if [[ ! -x "$BIN/kubeconform" ]]; then
  archive="kubeconform-${OS}-${ARCH}.tar.gz"
  base="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSLo "$tmp/$archive" "$base/$archive"
  expected="$(curl -fsSL "$base/CHECKSUMS" | grep " ${archive}\$" | cut -d' ' -f1)"
  [[ "$(sha256 "$tmp/$archive")" == "$expected" ]] || { echo "kubeconform checksum mismatch" >&2; exit 1; }
  tar -xzf "$tmp/$archive" -C "$BIN" kubeconform
  rm -rf "$tmp"
fi

if [[ ! -x "$BIN/kyverno" ]]; then
  # Kyverno names the amd64 build "x86_64".
  archive="kyverno-cli_${KYVERNO_VERSION}_${OS}_${ARCH/amd64/x86_64}.tar.gz"
  base="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSLo "$tmp/$archive" "$base/$archive"
  expected="$(curl -fsSL "$base/checksums.txt" | grep " ${archive}\$" | cut -d' ' -f1)"
  [[ "$(sha256 "$tmp/$archive")" == "$expected" ]] || { echo "kyverno checksum mismatch" >&2; exit 1; }
  tar -xzf "$tmp/$archive" -C "$BIN" kyverno
  rm -rf "$tmp"
fi

"$BIN/kind" version
"$BIN/kubeconform" -v
"$BIN/kyverno" version
