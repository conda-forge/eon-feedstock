#!/usr/bin/env bash

set -o xtrace -o nounset -o pipefail -o errexit

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

# Ensure host python can find its own site-packages (numpy, ase)
export PYTHONPATH="${SP_DIR}:${PYTHONPATH:-}"

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
    # Cross: host python is foreign arch, use build python
    # cross-python patches sys.path so build python can import host packages
    tee native.ini <<EOF
[binaries]
python = '${BUILD_PREFIX}/bin/python'
EOF
else
    tee native.ini <<EOF
[binaries]
python = '${PREFIX}/bin/python'
EOF
fi

meson setup -Dpython.install_env=prefix \
    --native-file native.ini \
    -Dwith_metatomic=True \
    -Dwith_xtb=True \
    -Dwith_ase=True \
    -Dwith_serve=True \
    -Dpip_metatomic=False \
    -Dtorch_path="${PREFIX}" \
    -Dcpp_link_args="${LDFLAGS}" \
    ${MESON_ARGS} build
meson compile -C build -v
meson install -C build
