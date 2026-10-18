#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="${1:-models}"
mkdir -p "$MODELS_DIR/Timestral-5M"
mkdir -p "$MODELS_DIR/Timestral-209M"

echo "=== Downloading Timestral-5M ==="
if [ ! -f "$MODELS_DIR/Timestral-5M/config.json" ]; then
  curl -L -s -o "$MODELS_DIR/Timestral-5M/config.json" https://huggingface.co/mistralai/Timestral-5M/resolve/main/config.json
fi
if [ ! -f "$MODELS_DIR/Timestral-5M/model.safetensors" ]; then
  echo "Downloading Timestral-5M weights (~21MB)..."
  curl -L -o "$MODELS_DIR/Timestral-5M/model.safetensors" https://huggingface.co/mistralai/Timestral-5M/resolve/main/model.safetensors
fi

echo "=== Downloading Timestral-209M ==="
if [ ! -f "$MODELS_DIR/Timestral-209M/config.json" ]; then
  curl -L -s -o "$MODELS_DIR/Timestral-209M/config.json" https://huggingface.co/mistralai/Timestral-209M/resolve/main/config.json
fi
if [ ! -f "$MODELS_DIR/Timestral-209M/model.safetensors" ]; then
  echo "Downloading Timestral-209M weights (~837MB)..."
  curl -L -o "$MODELS_DIR/Timestral-209M/model.safetensors" https://huggingface.co/mistralai/Timestral-209M/resolve/main/model.safetensors
fi

echo "All Timestral models downloaded to $MODELS_DIR."
