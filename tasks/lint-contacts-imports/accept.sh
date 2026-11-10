#!/usr/bin/env bash
set -euo pipefail
F=lib/ui/contacts_list.dart
flutter analyze --fatal-infos "$F"
! grep -nE '//\s*ignore(_for_file)?:' "$F" || { echo "ACCEPT FAIL: 不允许用 ignore 注释" >&2; exit 1; }
