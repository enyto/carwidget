#!/bin/sh
set -eu
cd "$(dirname "$0")"

usage() {
    printf 'usage: sh build.sh [rootful|rootless|roothide|all]...\n'
}

if [ "$#" -eq 0 ]; then
    set -- rootless
elif [ "$#" -eq 1 ] && [ "$1" = all ]; then
    set -- rootful rootless roothide
fi

# Validate every scheme before starting a build.
for scheme in "$@"; do
    case "$scheme" in
        rootful|rootless|roothide) ;;
        *) usage; exit 2 ;;
    esac
done

: "${THEOS:?Set THEOS to a compatible Theos toolchain first}"
for scheme in "$@"; do
    package_scheme="$scheme"
    if [ "$scheme" = rootful ]; then package_scheme=""; fi
    printf '\nBuilding %s\n' "$scheme"
    make clean THEOS_PACKAGE_SCHEME="$package_scheme"
    # The Control bundle lives inside Airaw's bundle tree, so packaging needs force mode.
    make package THEOS_PACKAGE_SCHEME="$package_scheme" FORCE_PACKAGE_NAME=yes \
        PACKAGE_BUILDNAME="$scheme"
done

printf '\nPackages:\n'
ls -1 packages/*.deb 2>/dev/null || true
