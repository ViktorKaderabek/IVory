#!/bin/bash
# Spuštění z Finderu dvojklikem (bez aplikace). Parametry viz scripts/run.sh.
cd "$(dirname "$0")" || exit 1
bash scripts/run.sh "$@"
echo
read -r -p "Enter pro zavření..." _
