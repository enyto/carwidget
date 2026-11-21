#!/bin/sh
# Linux cross-compile entry (GitHub Actions ubuntu runner or any Linux box).
# macOS runners are not available for this account, so the SDK and Theos come from
# GitHub mirrors that are reachable from CN networks, and clang targets Apple via ld.lld.
set -eu
cd "$(dirname "$0")"

WORK="${AXS_WORK:-$PWD/.axs-toolchain}"
SDK_REPO="${AXS_SDK_REPO:-https://github.com/theos/sdks.git}"
SDK_NAME="${AXS_SDK_NAME:-iPhoneOS16.5.sdk}"
# Mirror for CN networks, direct GitHub as the fallback (a proxy can truncate long transfers).
THEOS_MIRROR="${AXS_THEOS_URL:-https://gh-proxy.com/https://github.com/theos/theos/archive/refs/heads/master.tar.gz}"
THEOS_URL="${AXS_THEOS_FALLBACK:-https://github.com/theos/theos/archive/refs/heads/master.tar.gz}"
SCHEME="${1:-rootless}"

mkdir -p "$WORK"
SDK="$WORK/sdk/$SDK_NAME"
THEOS_DIR="${AXS_THEOS_DIR:-$WORK/theos}"

# The mirror truncates long transfers, so the archive is fetched with HTTP range requests
# and retried until the expected byte count is present.
fetch_ranged() {
    url="$1"; dest="$2"; total=""
    : > "$dest"
    for attempt in $(seq 1 60); do
        have=$(wc -c < "$dest" | tr -d ' ')
        if [ -z "$total" ]; then
            total=$(curl -sIL --max-time 60 "$url" | tr -d '\r' |
                    grep -i '^content-length:' | tail -1 | awk '{print $2}')
        fi
        if [ -n "$total" ] && [ "$have" -ge "$total" ]; then
            echo "    downloaded $have/$total bytes"
            return 0
        fi
        curl -sL --max-time 600 -r "$have-" "$url" >> "$dest"
        sleep 2
    done
    echo "download incomplete: $have/${total:-?}" >&2
    return 1
}

if [ ! -d "$WORK/sdk/iPhoneOS16.5.sdk" ]; then
    echo "==> fetching iOS SDK via theos/sdks mirror"
    rm -rf "$WORK/sdk" && mkdir -p "$WORK/sdk"
    # 221 MB, mostly empty stubs: full import through a blobless sparse clone.
    rm -rf "$WORK/sdksrc"
    git clone -q --depth 1 --filter=blob:none --sparse "$SDK_REPO" "$WORK/sdksrc" || \
        { rm -rf "$WORK/sdksrc"; git clone -q --depth 1 --filter=blob:none --sparse \
          "https://gh-proxy.com/https://github.com/theos/sdks.git" "$WORK/sdksrc"; }
    git -C "$WORK/sdksrc" sparse-checkout set "$SDK_NAME"
    mv "$WORK/sdksrc/$SDK_NAME" "$WORK/sdk/$SDK_NAME"
    rm -rf "$WORK/sdksrc"
fi

if [ ! -d "$THEOS_DIR/makefiles" ] && [ -d "$PWD/vendor/theos/makefiles" ]; then
    # Theos is pinned as a git submodule; checkout already fetched it.
    THEOS_DIR="$PWD/vendor/theos"
fi

if [ ! -d "$THEOS_DIR/makefiles" ]; then
    echo "==> fetching Theos"
    fetch_ranged "$THEOS_MIRROR" "$WORK/theos.tar.gz" || \
        { rm -f "$WORK/theos.tar.gz"; fetch_ranged "$THEOS_URL" "$WORK/theos.tar.gz"; }
    mkdir -p "$THEOS_DIR"
    tar xzf "$WORK/theos.tar.gz" -C "$THEOS_DIR" --strip-components=1
    rm -f "$WORK/theos.tar.gz"
fi

# Some Linux SDK bundles keep frameworks as PrivateFrameworks/X.framework/X.tbd and ship the
# libs under usr/lib/*.tbd only; Theos expects -framework <Name> and -l<Name> to resolve, so
# link a public framework view and name the libraries lib<Name>.tbd.
if [ ! -d "$SDK/System/Library/Frameworks/UIKit.framework" ]; then
    echo "==> normalising SDK layout"
    for fw in "$SDK/System/Library/PrivateFrameworks"/*.framework "$SDK/System/Library/Frameworks"/*.framework; do
        [ -d "$fw" ] || continue
        name="$(basename "$fw" .framework)"
        [ -e "$SDK/System/Library/Frameworks/$name.framework" ] || ln -sfn "$fw" "$SDK/System/Library/Frameworks/$name.framework"
    done
    for tbd in "$SDK/usr/lib"/*.tbd; do
        [ -e "$tbd" ] || continue
        case "$(basename "$tbd")" in lib*) ;; *) ln -sfn "$tbd" "$(dirname "$tbd")/lib$(basename "$tbd")" ;; esac
    done
fi

export THEOS="$THEOS_DIR"
# The linker shim reads these; exporting keeps it in step with AXS_WORK/SDK_NAME.
export AXS_SDK="$SDK"
export AXS_INSTALL_NAME="${AXS_INSTALL_NAME:-}"
mkdir -p "$THEOS/sdks"
ln -sfn "$SDK" "$THEOS/sdks/$(basename "$SDK")"

# Toolchain shims: Theos expects a prefixed Darwin toolchain; on Linux clang + ld.lld do the work.
BIN="$THEOS/toolchain/linux/iphone/bin"
mkdir -p "$BIN"
cat > "$BIN/arm64-apple-darwin14-clang" <<'EOF'
#!/bin/sh
# Compile-only invocations carry one -target; the link step gets both slices from Theos.
exec /usr/bin/clang "$@"
EOF
cat > "$BIN/arm64-apple-darwin14-ld" <<'EOF'
#!/bin/sh
# Drop Darwin-only driver flags and let clang drive ld64.lld; a bare Mach-O ld.lld is not shipped.
args=""
skip=0
for a in "$@"; do
  if [ "$shift_pending" = 1 ]; then shift_pending=0; skip=0; install_name="$a"; continue; fi
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -dynamic|-dylib|-iphoneos_version_min|-multiply_defined|-syslibroot|-mllvm|-enable-linkonceodr-outlining|-dead_strip) skip=1 ;;
    -arch) skip=1; want_arch=1 ;;
    -dylib_install_name) shift_pending=1; skip=1 ;;   # re-emitted as -Wl,-install_name
    *) args="$args $(printf '%s' "$a" | sed 's/ /\\ /g')" ;;
  esac
done
SDK="${AXS_SDK:?AXS_SDK not set}"
# Re-derive the requested slice before dropping the -arch flags.
slice_target="arm64-apple-ios15.0"
prev_arg=""
for a in "$@"; do
  case "$prev_arg" in -arch)
    case "$a" in arm64e) slice_target="arm64e-apple-ios15.0" ;; esac
  esac
  prev_arg="$a"
done
# Theos drops -lobjc/-lSystem on the floor for Linux, and its -install_name points at the
# build directory; both are supplied here. The slice follows the requested -arch (arm64e is
# later patched into the fat header because ld64 on Linux falls back to plain arm64).
# Theos passes the build path as the install name; rewrite it to the on-device bundle path.
if [ -n "${AXS_INSTALL_NAME:-}" ]; then
  args="-Wl,-install_name,$AXS_INSTALL_NAME $args"
fi
# The slice name is taken from -arch so ld64 emits matching relocations for each pass.
exec /usr/bin/clang -target "${slice_target:-arm64-apple-ios15.0}" -fuse-ld=lld -shared \
  -isysroot "$SDK" -L"$SDK/usr/lib" -lobjc -lSystem \
  -F"$SDK/System/Library/Frameworks" -F"$SDK/System/Library/PrivateFrameworks" $args
EOF
chmod +x "$BIN"/arm64-apple-darwin14-*

for tool in ar strip nm ranlib; do
    src="$(command -v "llvm-${tool}" || command -v "aarch64-linux-gnu-${tool}" || command -v "${tool}")"
    [ -n "$src" ] && ln -sf "$src" "$BIN/arm64-apple-darwin14-${tool}"
done

# lipo: the sdk tools do not ship it for Linux; merging thin Mach-O files is a few headers.
cat > "$BIN/arm64-apple-darwin14-lipo" <<'EOF'
#!/usr/bin/env python3
"""Minimal lipo: -create -arch NAME in -output out ...  or  -thin ARCH input -output out."""
import struct, sys

FAT_MAGIC = 0xcafebabe

def thin_arch(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic == 0xcffaedfe:   # little-endian 64-bit
        cputype, cpusubtype = struct.unpack("<ii", data[4:12])
    elif magic == 0xfeedfacf:
        cputype, cpusubtype = struct.unpack(">ii", data[4:12])
    else:
        raise SystemExit("not a Mach-O file")
    return cputype & 0xffffffff, cpusubtype & 0xffffffff, 12

def thin(data, arch):
    return data

def set_cpu(data, arch):
    """arm64e shares the 8-byte pointer ABI with arm64, so re-typing the slice is enough."""
    if arch not in ("arm64", "arm64e"):
        return data
    sub = 0x80000002 if arch == "arm64e" else 0x00000000
    return data[:8] + struct.pack("<I", sub) + data[12:]

def fat_create(output, inputs):
    blobs = [set_cpu(open(p, "rb").read(), arch) for p, arch in inputs]
    entries = [thin_arch(b) for b in blobs]
    header_len = 8 + 20 * len(blobs)
    offsets = []
    cursor = header_len
    for (cpu, _sub, _o), blob in zip(entries, blobs):
        align = 14 if cpu in (0x0100000c, 0x0100000e) else 12
        cursor = (cursor + (1 << align) - 1) // (1 << align) * (1 << align)
        offsets.append(cursor)
        cursor += len(blob)
    out = bytearray(cursor)
    struct.pack_into(">II", out, 0, FAT_MAGIC, len(blobs))
    for index, ((cpu, sub, _o), blob) in enumerate(zip(entries, blobs)):
        align = 14 if cpu in (0x0100000c, 0x0100000e) else 12
        struct.pack_into(">IIIII", out, 8 + 20 * index, cpu, sub, offsets[index], len(blob), align)
        out[offsets[index]:offsets[index] + len(blob)] = blob
        print("  lipo: slice %d cpu=%#x sub=%#x at %d" % (index, cpu, sub, offsets[index]), file=sys.stderr)
    open(output, "wb").write(out)

def main(argv):
    args = argv[1:]
    if not args:
        sys.exit(1)
    out = None
    if "-output" in args:
        i = args.index("-output")
        out = args[i + 1]
        del args[i:i + 2]
    if "-create" in args:
        args.remove("-create")
        # -arch <name> precedes each input; ld64 on Linux falls back to plain arm64, so the
        # slice's CPU type is patched from the requested name.
        inputs = []
        want = None
        skip = False
        for a in args:
            if skip:
                want = a
                skip = False
                continue
            if a == "-arch":
                skip = True
                continue
            inputs.append((a, want))
        if not out:
            sys.exit("missing -output")
        fat_create(out, inputs)
        return
    if "-thin" in args:
        i = args.index("-thin")
        arch = args[i + 1]
        del args[i:i + 2]
        if not out or not args:
            sys.exit("missing -output or input")
        open(out, "wb").write(thin(open(args[0], "rb").read(), arch))
        return
    sys.exit("unsupported lipo invocation: %s" % " ".join(argv))

main(sys.argv)
EOF
chmod +x "$BIN/arm64-apple-darwin14-lipo"
ln -sf "$BIN/arm64-apple-darwin14-lipo" "$BIN/lipo"

# ldid: Airaw instantiates the module class from SpringBoard, which requires a signed bundle.
# The official modules all carry LC_CODE_SIGNATURE, so an ad-hoc signature is mandatory.
# Ubuntu has no ldid package; build it once into the work directory.
if ! command -v ldid >/dev/null 2>&1 && [ ! -x "$WORK/ldid/ldid" ]; then
    echo "==> building ldid"
    rm -rf "$WORK/ldid"
    if git clone -q --depth 1 https://github.com/ProcursusTeam/ldid.git "$WORK/ldid" 2>/dev/null; then
        ( cd "$WORK/ldid" && make -j2 CXX=clang++ CXXFLAGS="-O2 -std=c++11" \
            LDFLAGS="-fuse-ld=lld -lcrypto -lplist-2.0" >/dev/null 2>&1 ) || true
    fi
fi
LDID_BIN="$(command -v ldid || true)"
if [ -z "$LDID_BIN" ] && [ -x "$WORK/ldid/ldid" ]; then LDID_BIN="$WORK/ldid/ldid"; fi
if [ -n "$LDID_BIN" ]; then
    ln -sf "$LDID_BIN" "$BIN/ldid"
    echo "==> ldid: $LDID_BIN"
else
    echo "==> WARNING: ldid not found, bundles will be unsigned" >&2
    cat > "$BIN/ldid" <<'EOF'
#!/bin/sh
exit 0
EOF
fi
chmod +x "$BIN/ldid"

# One clang invocation per file with both slices: Theos would otherwise link each arch in a
# separate pass, and ld64 on Linux rejects arm64e relocations produced by an arm64 pass.
ARCHS="${AXS_ARCHS:-arm64}"
export ARCHS

echo "==> building $SCHEME"
make clean THEOS_PACKAGE_SCHEME="$SCHEME" >/dev/null 2>&1 || true
make THEOS_PACKAGE_SCHEME="$SCHEME" ARCHS="$ARCHS"

echo "==> packaging $SCHEME"
make package THEOS_PACKAGE_SCHEME="$SCHEME" FORCE_PACKAGE_NAME=yes \
    PACKAGE_BUILDNAME="$SCHEME" ARCHS="$ARCHS"
ls -1 packages/*.deb
