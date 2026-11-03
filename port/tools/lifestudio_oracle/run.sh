#!/bin/bash
# run.sh [game dir] [work dir] : validate port/platform/src/lifestudio.cpp against the shipped LifeStudioHeadAPI.dll.
# Needs i686-w64-mingw32-g++, clang++, python3 and a Wine whose binary is in $WINE (default: the stock Wine 11 in
# /private/tmp/ssclean) with prefix $WINEPREFIX. The DLL runs only here, as a test oracle; the port never loads it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
GAME=${1:-"/private/tmp/ssclean/gog/app/Silent Storm"}
WORK=${2:-/private/tmp/lifestudio-oracle}
WINE=${WINE:-"/private/tmp/ssclean/wine/Wine Stable.app/Contents/Resources/wine/bin/wine"}
export WINEPREFIX=${WINEPREFIX:-/private/tmp/ssclean/test/prefix}
mkdir -p "$WORK"
for f in LifeStudioHeadAPI.dll IMorphFile.dll TriangLib.dll GDPFile.dll tree.mma; do cp "$GAME/$f" "$WORK/"; done
i686-w64-mingw32-g++ -O1 -std=c++17 -static -o "$WORK/oracle.exe" "$HERE/oracle.cpp"
clang++ -std=c++17 -O2 -D__stdcall= -I"$REPO/third_party/lifestudio/include" -o "$WORK/ntest" "$HERE/ntest.cpp" "$REPO/port/platform/src/lifestudio.cpp"
python3 -I "$HERE/gen.py" "$GAME" "$WORK"
cd "$WORK"
WINEDEBUG=-all taskpolicy -b "$WINE" oracle.exe LifeStudioHeadAPI.dll < oracle.cmd > oracle.log 2>&1
./ntest < native.cmd > native.log
python3 -I "$HERE/cmp.py" oracle native 10
