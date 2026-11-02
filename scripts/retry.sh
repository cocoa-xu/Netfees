#!/bin/bash
set -euo pipefail

for attempt in 1 2 3 4 5; do
  if "$@"; then
    exit 0
  else
    status=$?
  fi

  if [[ "$attempt" -eq 5 ]]; then
    exit "$status"
  fi

  delay=$((attempt * 10))
  echo "::warning::Attempt $attempt failed with exit code $status; retrying in $delay seconds."
  sleep "$delay"
done
