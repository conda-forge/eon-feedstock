#!/usr/bin/env bash

set -o xtrace -o nounset -o pipefail -o errexit

# cbindgen is not packaged on conda-forge for any subdir; bootstrap it via
# cargo into the build prefix so readcon-core's meson subproject can
# generate its C header. Matches the ensure_cbindgen fallback in the
# upstream pixi.toml.
cargo install --root "${BUILD_PREFIX}" cbindgen
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

meson setup -Dpython.install_env=prefix \
    --native-file native.ini \
    -Dwith_metatomic=True \
    -Dwith_xtb=True \
    -Dwith_serve=True \
    -Dpip_metatomic=False \
    -Dtorch_path="${PREFIX}" \
    -Dcpp_link_args="${LDFLAGS}" \
    ${MESON_ARGS} build
meson compile -C build -v
meson install -C build
