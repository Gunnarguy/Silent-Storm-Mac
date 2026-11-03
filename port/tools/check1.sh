#!/bin/bash
# check1.sh <source file substring> : syntax-check one file with its exact build flags
B=~/Library/Developer/SilentStormMac-build
cmd=$(ninja -C $B -t commands 2>/dev/null | grep -F "$1" | grep -E ' -c ' | head -1)
[ -z "$cmd" ] && { echo "no command for $1"; exit 1; }
cmd=$(echo "$cmd" | sed -E 's/ -o [^ ]+//; s/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c / -fsyntax-only /')
eval "$cmd" 2>&1 | grep -E 'error|warning: .*(override|hides)' | head -${2:-25}
