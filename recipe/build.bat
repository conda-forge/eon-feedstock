@echo on

:: conda-forge/eon-feedstock#15: enable IN-TREE Fortran on win-64 (not skip it).
:: Strategy (see https://rgoswami.me/posts/windows-compat-sci-cpp/):
::   - C++/Python/torch/metatomic: MSVC (conda-forge default win-64 compilers)
::   - In-tree Fortran pots (EAM/GAGAFE/CuH2 etc.): compiler('fortran') — currently
::     conda-forge win ships llvm-flang; C++/link stay MSVC (cl.exe / link.exe)
::   - Archiver: MUST be MSVC lib.exe. Enabling fortran pulls flang which otherwise
::     selects llvm-ar; MSVC link then fails with LNK1107 on .a files (libptlrpc etc.)
::   - MinGW-built xtb: generate MSVC import lib from DLL exports (ABI boundary)
::   - Stack: meson sets /STACK:16777216 for MSVC link (Windows 1 MB default overflows
::     legacy Fortran stack arrays; Linux default is 8 MB)
:: Cargo: HTTP/1.1 + retries (crates.io HTTP2 framing fails on some runners, incl. aarch64).

set "CARGO_HTTP_MULTIPLEXING=false"
set "CARGO_NET_RETRY=10"
set "CARGO_HTTP_TIMEOUT=300"

:: cbindgen has no conda-forge win-64 build; grab it via cargo into the host
:: prefix so readcon-core's meson subproject can generate its C header.
set "CARGO_ATTEMPT=0"
:cargo_install_cbindgen
set /a CARGO_ATTEMPT+=1
cargo install --root "%LIBRARY_PREFIX%" cbindgen
if errorlevel 1 (
    if %CARGO_ATTEMPT% GEQ 5 (
        echo ERROR: cargo install cbindgen failed after %CARGO_ATTEMPT% attempts
        exit 1
    )
    echo WARN: cargo install cbindgen attempt %CARGO_ATTEMPT% failed; retrying...
    timeout /t 10 /nobreak >nul
    goto cargo_install_cbindgen
)

:: Remove wrap files to prevent meson from building subprojects from source
del /q subprojects\xtb.wrap 2>nul
del /q subprojects\vesin.wrap 2>nul
del /q subprojects\rgpot.wrap 2>nul

:: Generate MSVC-compatible import library from MinGW-built xtb DLL
set "XTB_DLL_NAME="
for %%F in ("%LIBRARY_BIN%\libxtb-*.dll") do (
    if not defined XTB_DLL_NAME set "XTB_DLL_NAME=%%~nxF"
)
if not defined XTB_DLL_NAME (
    if exist "%LIBRARY_BIN%\libxtb.dll" (
        set "XTB_DLL_NAME=libxtb.dll"
    ) else (
        echo ERROR: Cannot find xtb DLL in %LIBRARY_BIN%
        exit 1
    )
)
dumpbin /EXPORTS "%LIBRARY_BIN%\%XTB_DLL_NAME%" > xtb_exports.txt
echo LIBRARY %XTB_DLL_NAME% > xtb.def
echo EXPORTS >> xtb.def
for /f "skip=19 tokens=4" %%A in (xtb_exports.txt) do (
    if not "%%A"=="" echo     %%A >> xtb.def
)
lib /DEF:xtb.def /OUT:"%LIBRARY_LIB%\xtb.lib" /MACHINE:X64
if errorlevel 1 exit 1

set "PYTHONPATH=%SP_DIR%;%PYTHONPATH%"

:: Keep C/C++/link on MSVC even though compiler('fortran') injects flang/llvm-ar.
:: Without this, meson archives with llvm-ar and final MSVC link fails (LNK1107).
set "CC=cl.exe"
set "CXX=cl.exe"
set "AR=lib"
set "ARFLAGS="
set "NM=dumpbin"
set "RANLIB=:"
:: Prefer MSVC link over lld-link from the flang/clang activation.
where link >nul 2>&1
if errorlevel 1 (
    echo ERROR: MSVC link.exe not on PATH; vsenv/activation missing
    exit 1
)

meson subprojects download readcon-core
if errorlevel 1 exit 1
python -c "import pathlib; p=pathlib.Path('subprojects/readcon-core/meson.build'); t=p.read_text(); old='\"/cargo-target/release/\"'; new='\"/cargo-target/\" + (__import__(\"os\").environ.get(\"CARGO_BUILD_TARGET\", \"\") + \"/\" if __import__(\"os\").environ.get(\"CARGO_BUILD_TARGET\") else \"\") + \"release/\"'; p.write_text(t.replace(old, new))"
if errorlevel 1 exit 1

pushd subprojects\readcon-core
set "CARGO_ATTEMPT=0"
:cargo_fetch_readcon
set /a CARGO_ATTEMPT+=1
cargo fetch --locked
if errorlevel 1 cargo fetch
if errorlevel 1 (
    if %CARGO_ATTEMPT% GEQ 5 (
        echo ERROR: cargo fetch readcon-core failed after %CARGO_ATTEMPT% attempts
        popd & exit 1
    )
    echo WARN: cargo fetch attempt %CARGO_ATTEMPT% failed; retrying...
    timeout /t 10 /nobreak >nul
    goto cargo_fetch_readcon
)
set "CARGO_ATTEMPT=0"
:cargo_bundle_licenses
set /a CARGO_ATTEMPT+=1
cargo-bundle-licenses --format yaml --output THIRDPARTY.yml
if errorlevel 1 (
    if %CARGO_ATTEMPT% GEQ 5 (
        echo ERROR: cargo-bundle-licenses failed after %CARGO_ATTEMPT% attempts
        popd & exit 1
    )
    echo WARN: cargo-bundle-licenses attempt %CARGO_ATTEMPT% failed; retrying...
    timeout /t 10 /nobreak >nul
    goto cargo_bundle_licenses
)
popd

:: In-tree Fortran ON including CuH2 (issue #15). Static default-library; MSVC AR above.
meson setup -Dpython.install_env=prefix ^
    --prefix="%PREFIX%" ^
    --default-library=static ^
    -Dwith_metatomic=True ^
    -Dwith_xtb=True ^
    -Dwith_serve=True ^
    -Dwith_fortran=true ^
    -Dwith_cuh2=true ^
    -Dpip_metatomic=False ^
    -Dtorch_path="%LIBRARY_PREFIX%" ^
    --pkg-config-path="%LIBRARY_LIB%\pkgconfig" ^
    --cmake-prefix-path="%LIBRARY_PREFIX%" ^
    --buildtype=release ^
    build
if errorlevel 1 exit 1

meson compile -C build -v
if errorlevel 1 exit 1

meson install -C build
if errorlevel 1 exit 1
