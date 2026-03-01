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

tee native.ini <<EOF
[binaries]
python = '${PREFIX}/bin/python'
EOF

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
