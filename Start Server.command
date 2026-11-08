#!/bin/bash
cd "$(dirname "$0")" || exit 1
echo "Direct.app is the iPhone app. This starts the server window on the Mac."
if ! command -v node >/dev/null 2>&1; then
  echo "Install Node.js 22 or newer from https://nodejs.org, then double-click this file again."
  read -r -p "Press return to close. "
  exit 1
fi
if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable
  corepack prepare pnpm@10.11.0 --activate
fi
pnpm install || {
  read -r -p "Press return to close. "
  exit 1
}
pnpm server
status=$?
if [ "$status" -ne 0 ]; then
  read -r -p "Press return to close. "
fi
exit "$status"
