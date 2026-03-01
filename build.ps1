$DEPOT_TOOLS_REPO="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
$V8_TAG="13.6.233"

# Clone depot-tools
if (-not (Test-Path -Path "depot_tools" -PathType Container)) {
  git clone --single-branch --depth=1 "$DEPOT_TOOLS_REPO" "C:\tmp\depot_tools"
}

echo "C:\tmp\depot_tools" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
$env:Path = "C:\tmp\depot_tools;" + $env:Path

# Set up google's client and fetch v8
if (-not (Test-Path -Path "v8" -PathType Container)) {
  gclient 
  fetch v8
}

Set-Location v8

git checkout $V8_TAG 
gclient sync --with_branch_heads --with_tags

# Apply patches

$files = Get-ChildItem "../patches" -Filter *.patch 
foreach ($f in $files){
  git apply $f
}

gn gen out/release --args="is_debug=false v8_symbol_level=2 is_component_build=false is_official_build=false use_custom_libcxx=false use_custom_libcxx_for_host=true use_sysroot=false use_glib=false is_clang=false v8_expose_symbols=true v8_optimized_debug=false v8_enable_sandbox=false v8_enable_i18n_support=false v8_enable_gdbjit=false v8_use_external_startup_data=false v8_enable_pointer_compression=true
  treat_warnings_as_errors=false target_cpu=\"$ARCH\" v8_target_cpu=\"$ARCH\" target_os=\"$OS\""

# Showtime!
ninja -C out/release wee8

ls -laR out/release/obj

# Package the output into a proper directory structure
$DIST_DIR = "out\dist"
if (Test-Path $DIST_DIR) { Remove-Item -Recurse -Force $DIST_DIR }
New-Item -ItemType Directory -Force -Path "$DIST_DIR\include"
New-Item -ItemType Directory -Force -Path "$DIST_DIR\include\wasm-c-api"
New-Item -ItemType Directory -Force -Path "$DIST_DIR\lib"

# Copy V8 public headers (preserving subdirectory structure)
Copy-Item -Recurse -Path "include\*" -Destination "$DIST_DIR\include\" -Include "*.h"
# Copy subdirectories with headers
Get-ChildItem -Path "include" -Directory | ForEach-Object {
    $dest = "$DIST_DIR\include\$($_.Name)"
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest }
    Copy-Item -Recurse -Path "$($_.FullName)\*" -Destination $dest -Filter "*.h"
}

# Copy the patched wasm C API header
Copy-Item -Path "third_party\wasm-api\wasm.h" -Destination "$DIST_DIR\include\wasm-c-api\wasm.h"

# Copy the library (renamed from wee8.lib to v8.lib)
Copy-Item -Path "out\release\obj\wee8.lib" -Destination "$DIST_DIR\lib\v8.lib"

Write-Host "=== Distribution layout ==="
Get-ChildItem -Recurse -File $DIST_DIR | ForEach-Object { Write-Host $_.FullName }
