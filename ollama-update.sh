#!/usr/bin/env bash
set -euo pipefail

# Update all installed ollama models
mapfile -t models < <(ollama list | tail -n +2 | awk '{print $1}')

if [[ ${#models[@]} -eq 0 ]]; then
    echo "No models installed"
    exit 0
fi

echo "Updating ${#models[@]} model(s)..."

for model in "${models[@]}"; do
    echo "--- Pulling $model ---"
    ollama pull "$model"
done

echo "All models updated"
ollama list
