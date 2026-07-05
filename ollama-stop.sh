#!/usr/bin/env bash
# Stop the main ollama systemd service.
# For isolated per-model servers, use: ./ollama-isolated.sh stop-all
set -euo pipefail

if ! systemctl is-active --quiet ollama; then
    echo "ollama is not running"
    exit 0
fi

sudo systemctl stop ollama
echo "ollama stopped"
