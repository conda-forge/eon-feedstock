#!/usr/bin/env bash

set -o xtrace -o nounset -o pipefail -o errexit

# Offline readcon-core C-API via cargo-c + vendored crates (no crates.io / github).
# Vendor tree is extracted from recipe/readcon-vendor.tar.xz into $SRC_DIR/readcon-vendor.
export CARGO_NET_OFFLINE=true
export CARGO_HOME="${SRC_DIR}/.cargo-home"
mkdir -p "${CARGO_HOME}"
cp -f "${RECIPE_DIR}/readcon-cargo-config/config.toml" "${CARGO_HOME}/config.toml"
# cargo config directory path is relative to the readcon-core crate root.
if [[ ! -d "${SRC_DIR}/readcon-vendor" ]]; then
    echo "ERROR: readcon-vendor not found under ${SRC_DIR}; recipe source missing?" >&2
    exit 1
fi

# Remove wrap files to prevent meson from building subprojects from source.
# All dependencies are provided by conda packages; readcon-core is prebuilt via cargo-c.
rm -f subprojects/xtb.wrap
rm -f subprojects/vesin.wrap
rm -f subprojects/rgpot.wrap
rm -f subprojects/readcon-core.wrap

export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
if [[ $(uname) == "Linux" ]]; then
    # NOTE: force the linker to use the generic libtorch.so instead of
    # libtorch_cpu.so allows switching to the CUDA version at runtime
    export LDFLAGS="${LDFLAGS} -Wl,--no-as-needed,${PREFIX}/lib/libtorch.so -Wl,--as-needed"
fi

# Ensure host python can find its own site-packages (numpy)
export PYTHONPATH="${SP_DIR}:${PYTHONPATH:-}"

# Build/install readcon-core C API into a staging prefix meson/pkg-config can see.
# GitHub source tarball extracts as readcon-core-src/readcon-core-<ver>/; accept either layout.
READCON_SRC="${SRC_DIR}/readcon-core-src"
if [[ ! -f "${READCON_SRC}/Cargo.toml" ]]; then
    _inner="$(find "${READCON_SRC}" -maxdepth 2 -name Cargo.toml -print -quit 2>/dev/null || true)"
    if [[ -n "${_inner}" ]]; then
        READCON_SRC="$(dirname "${_inner}")"
    fi
fi
if [[ ! -f "${READCON_SRC}/Cargo.toml" ]]; then
    echo "ERROR: readcon-core Cargo.toml not found under ${SRC_DIR}/readcon-core-src" >&2
    exit 1
fi

# Point the vendored-sources directory at the absolute vendor path (config.toml uses a relative name).
cat > "${CARGO_HOME}/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "${SRC_DIR}/readcon-vendor"

[net]
offline = true
EOF

# Install C API directly into $PREFIX so dylib install names live under the conda
# prefix (conda-build can rewrite them on package). A side readcon-prefix left
# absolute paths that survived into the test env (osx_64 dyld abort).
(
    cd "${READCON_SRC}"
    # Lockfile must match the pre-vendored crate set shipped in readcon-vendor.tar.xz.
    cp -f "${RECIPE_DIR}/readcon-core-Cargo.lock" Cargo.lock
    # License bundle for every transitive Rust dep (conda-forge policy); offline via vendor.
    cargo-bundle-licenses --format yaml --output "${SRC_DIR}/readcon-THIRDPARTY.yml"
    # conda-forge rust activation sets CARGO_BUILD_TARGET even on native builds; cargo-c
    # then looks for target/<triple>/release/*.pc while cargo wrote target/release/ (host).
    # Only pass --target when actually cross-compiling; otherwise clear it for this step.
    cinstall_extra=()
    if [[ -n "${CARGO_BUILD_TARGET:-}" && "${build_platform:-}" != "${target_platform:-}" ]]; then
        cinstall_extra+=(--target "${CARGO_BUILD_TARGET}")
    else
        unset CARGO_BUILD_TARGET
    fi
    cargo cinstall \
        --offline \
        --locked \
        --release \
        ${cinstall_extra[@]+"${cinstall_extra[@]}"} \
        --prefix "${PREFIX}" \
        --libdir lib \
        --includedir include \
        --pkgconfigdir lib/pkgconfig
)

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export CPATH="${PREFIX}/include:${CPATH:-}"
export CPLUS_INCLUDE_PATH="${PREFIX}/include:${CPLUS_INCLUDE_PATH:-}"

tee native.ini <<EOF
[binaries]
python = '${PREFIX}/bin/python'
EOF

meson setup -Dpython.install_env=prefix \
    --native-file native.ini \
    --pkg-config-path="${PREFIX}/lib/pkgconfig" \
    -Dwith_metatomic=True \
    -Dwith_xtb=True \
    -Dwith_serve=True \
    -Dpip_metatomic=False \
    -Dtorch_path="${PREFIX}" \
    -Dcpp_link_args="${LDFLAGS}" \
    ${MESON_ARGS} build
meson compile -C build -v
meson install -C build

# macOS: force @rpath ids/loads for readcon dylibs already under $PREFIX/lib.
if [[ "$(uname)" == "Darwin" ]]; then
    fix_readcon_install_names() {
        local target="$1"
        [[ -f "${target}" && ! -L "${target}" ]] || return 0
        while IFS= read -r old; do
            [[ -z "${old}" ]] && continue
            install_name_tool -change "${old}" "@rpath/$(basename "${old}")" "${target}" 2>/dev/null || true
        done < <(otool -L "${target}" 2>/dev/null | awk '/libreadcon_core/ && $1 ~ /^\// {print $1}')
    }
    shopt -s nullglob
    for dylib in "${PREFIX}/lib/"libreadcon_core*.dylib; do
        [[ -L "${dylib}" ]] && continue
        install_name_tool -id "@rpath/$(basename "${dylib}")" "${dylib}" || true
        fix_readcon_install_names "${dylib}"
    done
    if [[ -x "${PREFIX}/bin/eonclient" ]]; then
        fix_readcon_install_names "${PREFIX}/bin/eonclient"
        install_name_tool -add_rpath "@loader_path/../lib" "${PREFIX}/bin/eonclient" 2>/dev/null || true
    fi
    shopt -u nullglob
fi
