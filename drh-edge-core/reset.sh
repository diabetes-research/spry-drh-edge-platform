#!/usr/bin/env bash

echo "Cleaning up local database and cache..."
rm -f resource-surveillance.sqlite.db dev-src.auto *.db-shm *.db-wal

echo "Ensuring all taps are executable..."
# Ensure all taps are executable just in case
chmod +x singer-tap/*.py

echo "Environment reset. You can now run the pipeline."