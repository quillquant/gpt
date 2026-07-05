#!/usr/bin/env bash
# Start the main ollama systemd service.
# For isolated per-model servers, use: ./ollama-isolated.sh start-all
set -euo pipefail

if systemctl is-active --quiet ollama; then
    echo "ollama is already running"
    systemctl status ollama --no-pager -l | head -5
    exit 0
fi

sudo systemctl start ollama
echo "ollama started"
systemctl status ollama --no-pager -l | head -5
