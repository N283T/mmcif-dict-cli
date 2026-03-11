#!/bin/sh
set -eu

# mmcif-dict installer
# Usage: curl -fsSL https://raw.githubusercontent.com/N283T/mmcif-dict-cli/main/install.sh | sh

REPO="N283T/mmcif-dict-cli"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux)  os_name="linux" ;;
    Darwin) os_name="macos" ;;
    *)
      echo "Error: unsupported OS: $os" >&2
      exit 1
      ;;
  esac

  case "$arch" in
    x86_64|amd64)  arch_name="x86_64" ;;
    aarch64|arm64) arch_name="aarch64" ;;
    *)
      echo "Error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  if [ "$os_name" = "macos" ] && [ "$arch_name" = "x86_64" ]; then
    echo "Error: macOS x86_64 (Intel) is not supported" >&2
    exit 1
  fi

  echo "mmcif-dict-${os_name}-${arch_name}"
}

get_latest_version() {
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name": *"//;s/".*//'
}

main() {
  platform="$(detect_platform)"
  version="${VERSION:-$(get_latest_version)}"

  if [ -z "$version" ]; then
    echo "Error: could not determine latest version" >&2
    exit 1
  fi

  url="https://github.com/${REPO}/releases/download/${version}/${platform}.tar.gz"
  echo "Downloading mmcif-dict ${version} (${platform})..."

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  curl -fsSL "$url" -o "${tmpdir}/mmcif-dict.tar.gz"
  tar -xzf "${tmpdir}/mmcif-dict.tar.gz" -C "$tmpdir"

  mkdir -p "$INSTALL_DIR"
  cp "${tmpdir}/mmcif-dict" "$INSTALL_DIR/mmcif-dict"
  chmod +x "$INSTALL_DIR/mmcif-dict"

  echo "Installed mmcif-dict to ${INSTALL_DIR}/mmcif-dict"

  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "Add to your PATH:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  fi
}

main
