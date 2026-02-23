#!/bin/sh

# 1. Create the environment
echo "Setting up virtual environment..."
python3 -m venv venv

# 2. Install everything using the DIRECT path to the venv's pip
# This bypasses the need for the user to "source" anything during setup
echo "Installing dependencies..."
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r ../requirements.txt

echo "------------------------------------------------"
echo "Setup complete! The environment is ready."
echo "------------------------------------------------"
echo "To use this environment:"
echo "  BASH/ZSH:  source venv/bin/activate"
echo "  FISH:      source venv/bin/activate.fish"
echo ""
echo "OR run any script directly using:"
echo "  ./venv/bin/python3 your_script.py"
echo "------------------------------------------------"