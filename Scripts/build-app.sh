#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
case "$configuration" in
    debug|release) ;;
    *) print -u2 "usage: $0 [debug|release]"; exit 64 ;;
esac

build_dir="$project_dir/.build"
module_cache="$build_dir/ModuleCache"
app_dir="$project_dir/dist/OpenConnect Sandbox.app"
macos_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"
helpers_dir="$app_dir/Contents/Helpers"

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

swift build \
    --disable-sandbox \
    --scratch-path "$build_dir" \
    -c "$configuration"

bin_dir=$(swift build \
    --disable-sandbox \
    --scratch-path "$build_dir" \
    -c "$configuration" \
    --show-bin-path)

mkdir -p "$macos_dir" "$resources_dir" "$helpers_dir"
cp "$bin_dir/OpenConnectSandbox" "$macos_dir/OpenConnectSandbox"
cp "$bin_dir/OpenConnectSandboxSupervisor" "$macos_dir/OpenConnectSandboxSupervisor"
cp "$bin_dir/OpenConnectSandboxExec" "$macos_dir/OpenConnectSandboxExec"
cp "$bin_dir/vpnctl" "$macos_dir/vpnctl"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$resources_dir/SSOPatch"
cp "$project_dir/Resources/SSOPatch/sitecustomize.py" "$resources_dir/SSOPatch/sitecustomize.py"
cp "$project_dir/Resources/SSOPatch/bootstrap.py" "$resources_dir/SSOPatch/bootstrap.py"
chmod 755 "$macos_dir"/*
ln -sfn ../MacOS/vpnctl "$helpers_dir/ssh"
ln -sfn ../MacOS/vpnctl "$helpers_dir/scp"
ln -sfn ../MacOS/vpnctl "$helpers_dir/sftp"

identity=${CODESIGN_IDENTITY:--}
for executable in OpenConnectSandboxSupervisor OpenConnectSandboxExec vpnctl; do
    codesign --force --sign "$identity" --options runtime "$macos_dir/$executable"
done
codesign --force --sign "$identity" --options runtime "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

print "$app_dir"
