#!/usr/bin/env bash

set -o xtrace -o nounset -o pipefail -o errexit

# crates.io / curl on some runners (esp. linux_aarch64 GHA) fails with
# "Error in the HTTP2 framing layer" during cargo install / cargo-bundle-licenses.
# HTTP/1.1 + retries makes aarch64 (and win) builds reliable without vendoring.
export CARGO_HTTP_MULTIPLEXING="${CARGO_HTTP_MULTIPLEXING:-false}"
export CARGO_NET_RETRY="${CARGO_NET_RETRY:-10}"
export CARGO_HTTP_TIMEOUT="${CARGO_HTTP_TIMEOUT:-300}"

# Retry a command up to N times with backoff (network to crates.io is flaky on aarch64).
cargo_retry() {
    local max="${1:-5}"
    shift
    local attempt=1
    local delay=5
    until "$@"; do
        if [[ "${attempt}" -ge "${max}" ]]; then
            echo "ERROR: command failed after ${max} attempts: $*" >&2
            return 1
        fi
        echo "WARN: attempt ${attempt}/${max} failed; retrying in ${delay}s: $*" >&2
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        if [[ "${delay}" -gt 60 ]]; then delay=60; fi
    done
}

# cbindgen is not packaged on conda-forge for any subdir; bootstrap it via
# cargo into the build prefix so readcon-core's meson subproject can
# generate its C header. Matches the ensure_cbindgen fallback in the
# upstream pixi.toml. On cross builds (osx_arm64 from osx_64 hosts) cargo
# honors CARGO_BUILD_TARGET and would build an arm64 binary that cannot
# run on the x86_64 build machine -- drop the target locally so cargo
# emits a build-native executable.
(
    unset CARGO_BUILD_TARGET
    cargo_retry 5 cargo install --root "${BUILD_PREFIX}" cbindgen
)
export PATH="${BUILD_PREFIX}/bin:${PATH}"

# Remove wrap files to prevent meson from building subprojects from source
# All dependencies are provided by conda packages
rm -f subprojects/xtb.wrap
rm -f subprojects/vesin.wrap
rm -f subprojects/rgpot.wrap

export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
if [[ $(uname) == "Linux" ]]; then
    # NOTE: force the linker to use the generic libtorch.so instead of
    # libtorch_cpu.so allows switching to the CUDA version at runtime
    export LDFLAGS="${LDFLAGS} -Wl,--no-as-needed,${PREFIX}/lib/libtorch.so -Wl,--as-needed"
fi

# Ensure host python can find its own site-packages (numpy)
export PYTHONPATH="${SP_DIR}:${PYTHONPATH:-}"

tee native.ini <<EOF
[binaries]
python = '${PREFIX}/bin/python'
rust = ['${BUILD_PREFIX}/bin/rustc']
EOF

# conda-forge's rust_compiler activation exports CARGO_BUILD_TARGET=<triple>,
# which makes cargo emit into target-dir/<triple>/release/. Upstream
# readcon-core's meson.build (v0.8.0) hardcodes target-dir/release/ in its
# shutil.copy2 step and fails otherwise. Download the subproject up front and
# rewrite the copy path to honor CARGO_BUILD_TARGET when it is set.
meson subprojects download readcon-core
sed -i.bak \
    -e 's|"/cargo-target/release/"|"/cargo-target/" + (__import__("os").environ.get("CARGO_BUILD_TARGET", "") + "/" if __import__("os").environ.get("CARGO_BUILD_TARGET") else "") + "release/"|' \
    subprojects/readcon-core/meson.build
rm -f subprojects/readcon-core/meson.build.bak

# Warm the registry/cache then bundle licenses (policy: THIRDPARTY.yml for Rust deps).
# cargo-bundle-licenses runs `cargo metadata` which hits crates.io; prime with fetch.
(
    cd subprojects/readcon-core
    cargo_retry 5 cargo fetch --locked 2>/dev/null || cargo_retry 5 cargo fetch
    cargo_retry 5 cargo-bundle-licenses --format yaml --output THIRDPARTY.yml
)

# On cross builds (osx_arm64 from osx_64 hosts) conda-forge passes a
# --cross-file via MESON_ARGS but does not populate [binaries] rust in it.
# readcon-core's `project('readcon-core', ['rust', 'c'], ...)` demands one.
# Append our own cross-file that adds the rust binary with --target, so
# meson resolves rustc for the host machine and cargo cross-compiles to
# the target triple.
meson_extra_args=()
if [[ -n "${CARGO_BUILD_TARGET:-}" && "${build_platform:-}" != "${target_platform:-}" ]]; then
    tee cross-rust.ini <<EOF
[binaries]
rust = ['${BUILD_PREFIX}/bin/rustc', '--target', '${CARGO_BUILD_TARGET}']
EOF
    meson_extra_args+=(--cross-file cross-rust.ini)
fi

meson setup -Dpython.install_env=prefix \
    --native-file native.ini \
    ${meson_extra_args[@]+"${meson_extra_args[@]}"} \
    -Dwith_metatomic=True \
    -Dwith_xtb=True \
    -Dwith_serve=True \
    -Dpip_metatomic=False \
    -Dtorch_path="${PREFIX}" \
    -Dcpp_link_args="${LDFLAGS}" \
    ${MESON_ARGS} build
meson compile -C build -v
meson install -C build
