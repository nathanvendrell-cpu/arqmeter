#!/bin/zsh
set -euo pipefail

# Developer build only. Never replace installed apps or rotate old backups here.
# The new packaging embeds the pinned Sparkle framework with its internal links.
exec /bin/zsh "${0:A:h}/build-updater-candidate.sh"
