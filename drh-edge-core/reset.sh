#!/usr/bin/env bash

echo "Stopping any active Python processes..."
# Kill lingering processes to release file locks on the .venv
pkill -9 python3 2>/dev/null || true

echo "Cleaning up local database and cache..."
rm -f resource-surveillance.sqlite.db dev-src.auto *.db-shm *.db-wal

echo "Ensuring all taps are executable..."
chmod +x singer-tap/*.py

echo "Removing the virtual environment..." 
# Targets the .venv folder in the same directory as this script
rm -rf "$(dirname "$0")/.venv"

if [ -d "$(dirname "$0")/.venv" ]; then
    echo "⚠️ Warning: .venv directory could not be removed. Try manual removal: sudo rm -rf .venv"
else
    echo "Environment reset. You can now run the pipeline."
fi