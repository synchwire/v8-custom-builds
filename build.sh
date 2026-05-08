#!/bin/bash

# Display all commands before executing them.
set -o errexit
set -o errtrace
set -x

DEPOT_TOOLS_REPO="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
DEPOT_TOOLS_DIR="/tmp/depot_tools"

V8_TAG=${V8_TAG:-"15.0.1"}

if [ -z "$1" ]; then 
  case $(uname -m) in
	"x86_64")
	  ARCH="x64"
      ;;
  
	*)
	  ARCH=$(uname -m)
      ;;
  esac
else 
  ARCH=$1
fi

if [ -z "$2" ]; then 
  case $(uname -s) in
	"Darwin")
	  OS="mac"
	  ;;
	"Linux")
	  OS="linux"
	  ;;
	*)
	  OS=$(uname -s)
  esac
else 
  OS=$2
fi


if [ ! -d "$DEPOT_TOOLS_DIR" ]
then 
  git clone "$DEPOT_TOOLS_REPO" "$DEPOT_TOOLS_DIR"
fi

export PATH="$PATH:$DEPOT_TOOLS_DIR"

# Set up google's client and fetch v8
if [ ! -d v8 ]
then 
  fetch v8
  if [ "$OS" == "android" ] 
  then
	echo "target_os = [\"android\"];" >> .gclient
	gclient sync
  fi
  if [ "$OS" == "ios" ] 
  then
	echo "target_os = [\"ios\"];" >> .gclient
	gclient sync
  fi
fi

cd v8
git reset --hard
git checkout $V8_TAG
# Sync deps without hooks to avoid downloading unnecessary test data
# (wasm-spec-tests, wasm-js) which can fail on musl/Alpine due to gsutil issues.
gclient sync --with_branch_heads --with_tags --nohooks
# Run only the hooks required for building
python3 build/util/lastchange.py -o build/util/LASTCHANGE

for patch in ../patches/*.patch; do
  git apply "$patch"
done

# V8 14.x+ headers (e.g. src/base/macros.h) use clang-only constructs like
# __has_warning(...) that GCC's preprocessor can't parse. Use clang on Linux.
# On glibc systems, download chromium's bundled clang (system clang's runtime
# library libclang_rt.builtins.a is often absent under apt's clang package).
# On musl/Alpine, the chromium prebuilt is glibc-linked and won't run, so use
# the system clang installed via apk and skip lld (chromium's clang assumes
# its bundled lld is on PATH; system clang doesn't ship it).
if [ "$OS" == "linux" ]; then
  if [ -f /etc/alpine-release ]; then
    # Approach modelled on Void Linux's chromium template + Alpine community
    # APKBUILD. Use chromium's `unbundle:default` toolchain — chromium's
    # built-in escape hatch that honours $CC/$CXX/$AR/$NM env. This avoids
    # fighting the clang_version / clang_base_path / compiler-rt-path /
    # bundled-clang-23-flags rabbit hole, since clang's own driver finds
    # its own resource dir, libc++, and lld.
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export NM=llvm-nm
    # Chromium's bundled build/ still pipes -Z (nightly-only) flags to
    # rustc in some rust_wrapper paths even after rustc_nightly_capability
    # is forced false (verified empirically — bundled libm / proc-macro2
    # build scripts still hit `error: option \`Z\` is only accepted on
    # the nightly compiler` without this env). RUSTC_BOOTSTRAP=1 makes
    # stable rustc accept -Z flags as if it were nightly. Standard
    # workaround used by many distro chromium packagers.
    export RUSTC_BOOTSTRAP=1
    # Chromium's buildtools/third_party/libc++/__config_site hardcodes
    # _LIBCPP_HAS_MUSL_LIBC 0 unless ANDROID_HOST_MUSL is set; that file
    # is force-included into every TU and overrides any -D from CXXFLAGS.
    # Flip it to 1 so libc++ reaches the musl rune-table path. Same as
    # Alpine selfisekai/copium cr147-is-musl-libcxx.patch.
    sed -i 's|#define _LIBCPP_HAS_MUSL_LIBC 0|#define _LIBCPP_HAS_MUSL_LIBC 1|' buildtools/third_party/libc++/__config_site
    # Chromium's compiler config still adds clang-23-only flags
    # unconditionally; clang 20 rejects them. Strip the ones we know
    # break the build. (Selfisekai/copium ships these as proper patches —
    # cr146 etc. — once we converge on a stable set, port to patches/.)
    sed -i 's|"-fdiagnostics-show-inlining-chain",\?||g' build/config/compiler/BUILD.gn
    sed -i 's|"-fno-lifetime-dse",\?||g' build/config/compiler/BUILD.gn
    sed -i 's|"-fsanitize-ignore-for-ubsan-feature=${invoker.sanitizer}",\?||g' build/config/sanitizers/sanitizers.gni
    # Chromium hardcodes --target=x86_64-unknown-linux-gnu for clang+linux+x64
    # (in compiler_cpu_abi.gn at HEAD, but file path varies across build/
    # revisions). Wrong on musl: clang then ignores its native
    # alpine-linux-musl triple, libc++ thinks it's on glibc, the rune
    # table lookup fails. Drop the --target= line wherever it lives so
    # clang uses its own default (already x86_64-alpine-linux-musl on Alpine).
    grep -rl '"--target=x86_64-unknown-linux-gnu"' build/config/ | xargs -r sed -i '/"--target=x86_64-unknown-linux-gnu"/d'
    # Same swap for rust_abi_target. Alpine ships rustlib at
    # /usr/lib/rustlib/x86_64-alpine-linux-musl, not the chromium-default
    # /usr/lib/rustlib/x86_64-unknown-linux-gnu. find_std_rlibs.py errors
    # FileNotFoundError without this swap.
    grep -rl 'rust_abi_target = "x86_64-unknown-linux-gnu"' build/config/ | xargs -r sed -i 's|rust_abi_target = "x86_64-unknown-linux-gnu"|rust_abi_target = "x86_64-alpine-linux-musl"|'
    # build/config/rust.gni asserts rust_abi_target appears in
    # build/rust/known-target-triples.txt. Add the alpine triple.
    grep -qxF 'x86_64-alpine-linux-musl' build/rust/known-target-triples.txt || echo 'x86_64-alpine-linux-musl' >> build/rust/known-target-triples.txt
    # rustc_nightly_capability is computed (not declare_args), so the gn-arg
    # override is ignored. Force false directly. Alpine ships stable rustc;
    # any -Z flag fails with "option `Z` is only accepted on the nightly
    # compiler".
    grep -rl 'rustc_nightly_capability = use_chromium_rust_toolchain || build_with_chromium' build/config/ | xargs -r sed -i 's#rustc_nightly_capability = use_chromium_rust_toolchain || build_with_chromium#rustc_nightly_capability = false#'
    CLANG_ARGS="custom_toolchain=\"//build/toolchain/linux/unbundle:default\" host_toolchain=\"//build/toolchain/linux/unbundle:default\" is_clang=true clang_use_chrome_plugins=false use_custom_libcxx=true use_custom_libcxx_for_host=true enable_rust=true rust_sysroot_absolute=\"/usr\" rust_bindgen_root=\"/usr\" rust_force_head_revision=true rustc_version=\"$(rustc --version | cut -d' ' -f2)\" use_partition_alloc_as_malloc=false use_allocator_shim=false"
  else
    python3 tools/clang/scripts/update.py
    CLANG_ARGS="is_clang=true use_custom_libcxx=false use_custom_libcxx_for_host=false"
  fi
elif [ "$OS" == "mac" ]; then
  # Apple's libc++ shipped with Xcode 16.x doesn't have std::atomic_ref (first
  # available in libc++ from LLVM 19). V8 14+ uses it internally. Setting
  # is_clang=true alone isn't enough — chromium's clang would still pick up
  # Apple's libc++ at compile time when use_custom_libcxx=false. Flip
  # use_custom_libcxx=true on macOS so V8 builds against chromium's bundled
  # libc++, which has atomic_ref.
  #
  # ABI note: this is safe for the wasmer downstream (Rust binary linking
  # libwee8.a, only the C wee8 surface crosses the boundary). For
  # generic-consumer use cases it would mean libwee8.a's C++ symbols come
  # from chromium's libc++ ABI rather than Apple's; revisit before any
  # upstream PR that's meant to serve other consumers.
  python3 tools/clang/scripts/update.py
  CLANG_ARGS="is_clang=true use_custom_libcxx=true use_custom_libcxx_for_host=true"
else
  CLANG_ARGS="is_clang=false use_custom_libcxx=false use_custom_libcxx_for_host=false"
fi

if [ "$OS" == "ios" ]
then
gn gen out/release --args="is_debug=false \
  v8_symbol_level=0 \
  symbol_level = 0 \
  is_component_build=false \
  is_official_build=false \
  use_sysroot=false \
  use_glib=false \
  $CLANG_ARGS \
  v8_expose_symbols=true \
  v8_optimized_debug=false \
  v8_enable_sandbox=false \
  v8_enable_i18n_support=true \
  icu_use_data_file=false \
  v8_enable_gdbjit=false \
  v8_use_external_startup_data=false \
  treat_warnings_as_errors=false \
  v8_enable_fast_mksnapshot = true \
  v8_enable_handle_zapping = false \
  v8_enable_pointer_compression = true \
  use_siso = false \
  v8_enable_short_builtin_calls = true \
  v8_monolithic = true \
  ios_enable_code_signing = false \
  target_cpu=\"$ARCH\" \
  v8_target_cpu=\"$ARCH\" \
  target_os=\"$OS\" \
  target_environment=\"device\" \
  "
else
gn gen out/release --args="is_debug=false \
  v8_symbol_level=0 \
  symbol_level = 0 \
  is_component_build=false \
  is_official_build=false \
  use_sysroot=false \
  use_glib=false \
  $CLANG_ARGS \
  v8_expose_symbols=true \
  v8_optimized_debug=false \
  v8_enable_sandbox=false \
  v8_enable_i18n_support=true \
  icu_use_data_file=false \
  v8_enable_gdbjit=false \
  v8_use_external_startup_data=false \
  treat_warnings_as_errors=false \
  v8_enable_fast_mksnapshot = true \
  v8_enable_handle_zapping = false \
  v8_enable_pointer_compression = true \
  use_siso = false \
  target_cpu=\"$ARCH\" \
  v8_target_cpu=\"$ARCH\" \
  target_os=\"$OS\" \
  "
fi

# Showtime!
if [ "$OS" == "ios" ]; then
  ninja -C out/release v8_monolith
else
  ninja -C out/release wee8
fi

ls -laR out/release/obj

# Package the output into a proper directory structure:
#   include/         - V8 public headers
#   include/wasm-c-api/wasm.h - Wasm C API header (patched)
#   lib/libv8.a      - The built library
DIST_DIR="out/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/include"
mkdir -p "$DIST_DIR/include/wasm-c-api"
mkdir -p "$DIST_DIR/lib"

# Copy V8 public headers (preserving subdirectory structure)
cp -R include/* "$DIST_DIR/include/"
# Remove non-header files
find "$DIST_DIR/include" -type f ! -name "*.h" -delete

# Copy the patched wasm C API header
cp third_party/wasm-api/wasm.h "$DIST_DIR/include/wasm-c-api/wasm.h"

# Copy the library (renamed to libv8.a)
if [ "$OS" == "ios" ]; then
  cp out/release/obj/libv8_monolith.a "$DIST_DIR/lib/libv8.a"
else
  cp out/release/obj/libwee8.a "$DIST_DIR/lib/libv8.a"
fi

echo "=== Distribution layout ==="
find "$DIST_DIR" -type f | sort
