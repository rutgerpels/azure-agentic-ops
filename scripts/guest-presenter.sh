#!/bin/bash
# Bash launcher for the same guarded PowerShell presenter engine; requires pwsh 7.5+.
set -euo pipefail

if [[ $# -eq 0 || "${1}" == "--help" || "${1}" == "-h" ]]; then
    printf '%s\n' 'Usage: bash scripts/guest-presenter.sh Configure|Ready|Fault|Status|Reset [PowerShell parameters]'
    exit 0
fi
case "${1}" in
    Configure|Ready|Fault|Status|Reset) ;;
    *) printf '%s\n' 'Unknown presenter operation.' >&2; exit 2 ;;
esac
if ! command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' 'PowerShell 7.5+ (pwsh) must be on PATH; Bash uses the shared guard engine.' >&2
    exit 127
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
exec pwsh -NoProfile -File "${script_dir}/Invoke-GuestPresenter.ps1" "$@"
