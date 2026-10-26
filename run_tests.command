#!/bin/bash
# Bygger og kører MODULRs tests (kernelogikken) på din Mac.
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$(dirname "$0")"
FP="$HOME/Library/Application Support/MODULR/fpcalc-1.6.2"
[ -x "$FP" ] && export FPCALC="$FP"
OUT="$(mktemp -d)/modulr-tests"
echo "Bygger tests..."
xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" Core/*.swift Tests/main.swift -o "$OUT"
"$OUT"
echo
echo "USB-modulet (Python):"
/usr/bin/python3 -c "import ast; ast.parse(open('usb/pioneer_usb.py').read()); print('  ✅ pioneer_usb.py kan indlæses')"
