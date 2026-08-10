#!/usr/bin/env bash
set -euo pipefail

sudo apt update
sudo apt install -y \
  ca-certificates \
  curl \
  libfdt1 \
  libsdl1.2debian \
  nodejs \
  npm \
  python3-pip \
  python3-venv

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

uv tool install --force pebble-tool --python 3.13

sdk_inventory="$(pebble sdk list)"
printf '%s\n' "$sdk_inventory"
latest_sdk="$({
  printf '%s\n' "$sdk_inventory" |
    sed -nE 's/^[[:space:]]*([0-9]+(\.[0-9]+)+)( \(active\))?$/\1/p'
} | sort -V | tail -n 1)"

if [[ -z "$latest_sdk" ]]; then
  echo "Could not determine the latest Pebble SDK version." >&2
  exit 1
fi

if pebble sdk activate "$latest_sdk" >/dev/null 2>&1; then
  echo "Activated installed Pebble SDK $latest_sdk."
else
  pebble sdk install "$latest_sdk"
fi

pebble --version
pebble sdk list
