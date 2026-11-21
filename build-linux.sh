#!/bin/sh
# Linux cross-compile entry (GitHub Actions ubuntu runner or any Linux box).
# macOS runners are not available for this account, so the SDK and Theos come from
# GitHub mirrors that are reachable from CN networks, and clang targets Apple via ld.lld.
set -eu
cd "$(dirname "$0")"

WORK="${AXS_WORK:-$PWD/.axs-toolchain}"
SDK_REPO="${AXS_SDK_REPO:-https://github.com/theos/sdks.git}"
SDK_NAME="${AXS_SDK_NAME:-iPhoneOS16.5.sdk}"
THEOS_URL="${AXS_THEOS_URL:-https://gh-proxy.com/https://github.com/theos/theos/archive/refs/heads/master.tar.gz}"
SCHEME="${1:-rootless}"

mkdir -p "$WORK"
SDK="$WORK/sdk/$SDK_NAME"
THEOS_DIR="$WORK/theos"

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
    git clone -q --depth 1 --filter=blob:none --sparse "$SDK_REPO" "$WORK/sdksrc"
    git -C "$WORK/sdksrc" sparse-checkout set "$SDK_NAME"
    mv "$WORK/sdksrc/$SDK_NAME" "$WORK/sdk/$SDK_NAME"
    rm -rf "$WORK/sdksrc"
fi

if [ ! -d "$THEOS_DIR/makefiles" ]; then
    echo "==> fetching Theos"
    fetch_ranged "$THEOS_URL" "$WORK/theos.tar.gz"
    mkdir -p "$THEOS_DIR"
    tar xzf "$WORK/theos.tar.gz" -C "$THEOS_DIR" --strip-components=1
    rm -f "$WORK/theos.tar.gz"
fi

export THEOS="$THEOS_DIR"
mkdir -p "$THEOS/sdks"
ln -sfn "$SDK" "$THEOS/sdks/$(basename "$SDK")"

# Toolchain shims: Theos expects a prefixed Darwin toolchain; on Linux clang + ld.lld do the work.
BIN="$THEOS/toolchain/linux/iphone/bin"
mkdir -p "$BIN"
cat > "$BIN/arm64-apple-darwin14-clang" <<'EOF'
#!/bin/sh
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
SDK="${AXS_SDK:-/tmp/theos/sdks/iPhoneOS16.5.sdk}"
# Theos drops -lobjc/-lSystem on the floor for Linux, and its -install_name points at the
# build directory; both are supplied here. The slice follows the requested -arch (arm64e is
# later patched into the fat header because ld64 on Linux falls back to plain arm64).
# Theos passes the build path as the install name; rewrite it to the on-device bundle path.
if [ -n "${AXS_INSTALL_NAME:-}" ]; then
  args="-Wl,-install_name,$AXS_INSTALL_NAME $args"
fi
exec /usr/bin/clang -target "arm64-apple-ios15.0" -fuse-ld=lld -shared \
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

# ldid: codesigning is not needed for a jailbreak bundle; a pass-through keeps packaging simple.
cat > "$BIN/ldid" <<'EOF'
#!/bin/sh
# Theos calls `ldid -S...` to attach signatures; jailbroken devices load unsigned bundles.
exit 0
EOF
chmod +x "$BIN/ldid"

echo "==> building $SCHEME"
make clean THEOS_PACKAGE_SCHEME="$SCHEME" >/dev/null 2>&1 || true
make THEOS_PACKAGE_SCHEME="$SCHEME"
