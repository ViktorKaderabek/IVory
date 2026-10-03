#!/bin/bash
# Start by double-clicking in Finder (without the app). For the options see scripts/run.sh.
cd "$(dirname "$0")" || exit 1
bash scripts/run.sh "$@"
echo
read -r -p "Enter pro zavření..." _
