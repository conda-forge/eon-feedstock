#!/usr/bin/env bash

set -o xtrace -o nounset -o pipefail -o errexit

# readcon-core C-API via cargo-c; crate deps resolve from crates.io pinned by
# the upstream Cargo.lock (same pattern as the readcon-core staged recipe).
export CARGO_HOME="${SRC_DIR}/.cargo-home"
mkdir -p "${CARGO_HOME}"

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

# Install C API directly into $PREFIX so dylib install names live under the conda
# prefix (conda-build can rewrite them on package). A side readcon-prefix left
# absolute paths that survived into the test env (osx_64 dyld abort).
(
    cd "${READCON_SRC}"
    # License bundle for every transitive Rust dep (conda-forge policy).
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
        --locked \
        --release \
        ${cinstall_extra[@]+"${cinstall_extra[@]}"} \
        --prefix "${PREFIX}" \
        --libdir lib \
        --includedir include \
        --pkgconfigdir lib/pkgconfig
)

# Tag v0.14.10 left Cargo.toml / meson project() at 0.14.9, so cargo-c writes
# Version: 0.14.9. eOn 3.2.1 meson requires >=0.14.10 (wrap revision v0.14.10).
pc="${PREFIX}/lib/pkgconfig/readcon-core.pc"
if [[ ! -f "${pc}" ]]; then
    echo "ERROR: ${pc} missing after cargo cinstall" >&2
    exit 1
fi
python3 -c "
from pathlib import Path
p = Path(r'''${pc}''')
t = p.read_text()
old, new = 'Version: 0.14.9', 'Version: 0.14.10'
if old not in t:
    raise SystemExit(f'{p} has no {old!r}')
p.write_text(t.replace(old, new, 1))
print(f'rewrote {p} {old} -> {new}')
"

# macOS: set @rpath ids on readcon dylibs in $PREFIX before meson links eonclient.
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
    shopt -u nullglob
fi

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
    -Dwith_rgpot=True \
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
