#!/bin/bash
# Runs the web app at http://localhost:8787 with the project environment
# (see env.sh). Used by .claude/launch.json; works from any terminal too.
source "$(dirname "$0")/../env.sh"
cd "$SOLITON_ROOT" || exit 1
exec flutter run -d web-server --web-port 8787 --web-hostname localhost "$@"
