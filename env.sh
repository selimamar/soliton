# Soliton development environment. Load it in every new terminal:
#
#   source env.sh
#
# Everything this project downloads stays inside this folder: the Python
# interpreter, the virtual environment (.venv), the pip/uv and Dart/Flutter
# package caches, temporary files and the local server's database. Nothing
# is installed system-wide. Delete .venv, .cache and .data to remove it all.
#
# First-time setup, after sourcing:
#
#   uv sync --all-packages     # Python 3.12, logger, server, test tools
#   flutter pub get            # Dart packages

SOLITON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export SOLITON_ROOT

# The Flutter SDK is installed separately; override if yours is elsewhere.
export SOLITON_FLUTTER="${SOLITON_FLUTTER:-$HOME/Development/flutter}"

# Caches and downloads, all inside the project.
export PUB_CACHE="$SOLITON_ROOT/.cache/pub"
export UV_CACHE_DIR="$SOLITON_ROOT/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$SOLITON_ROOT/.cache/python"
export UV_PYTHON_PREFERENCE=only-managed # Never use the system Python.
export UV_PYTHON_INSTALL_BIN=0 # No python3.x shortcuts in ~/.local/bin.
export UV_PYTHON_BIN_DIR="$SOLITON_ROOT/.cache/python/bin" # (just in case)
export UV_PROJECT_ENVIRONMENT="$SOLITON_ROOT/.venv"
export PIP_CACHE_DIR="$SOLITON_ROOT/.cache/pip"
export PYTHONNOUSERSITE=1 # Ignore packages in ~/Library/Python.
export TMPDIR="$SOLITON_ROOT/.cache/tmp"
mkdir -p "$TMPDIR"

# Where the local server keeps its database and API token.
export SOLITON_DATA_DIR="${SOLITON_DATA_DIR:-$SOLITON_ROOT/.data}"

export PATH="$SOLITON_ROOT/.venv/bin:$SOLITON_FLUTTER/bin:$PATH"
