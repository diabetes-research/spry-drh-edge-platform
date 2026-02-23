#!/bin/sh

# 1. Create the environment using the hidden .venv name
# This matches your reset.sh and .gitignore logic
echo "Setting up virtual environment in .venv..."
python3 -m venv .venv

# 2. Install dependencies
# Pointing to ../requirements.txt because setup.sh is in drh-edge-core/
echo "Installing dependencies..."
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r ../requirements.txt

echo "------------------------------------------------"
echo "Setup complete! The environment is ready."
echo "------------------------------------------------"
echo "To use this environment manually:"
echo "   BASH/ZSH:  source .venv/bin/activate"
echo "   FISH:      source .venv/bin/activate.fish"
echo ""
echo "Note: Your spry tasks and Singer taps will use this "
echo "environment automatically via the bootstrap logic."
echo "------------------------------------------------"