#!/bin/bash
# Bumps the package version, keeping lib/src/version.dart in sync with
# pubspec.yaml. Requires the `dart_bump` global tool.
#
# Usage: ./bump.sh <pub-api-key> [dart_bump args...]
APIKEY=$1
shift
dart_bump . \
  --extra-file "lib/src/version.dart=omnyHubVersion\\s*=\\s*['\"](.*)['\"]" \
  --api-key "$APIKEY" \
  "$@"
