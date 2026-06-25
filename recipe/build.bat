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
:: readcon-core: offline cargo-c + vendored crates (no crates.io / github during build).

set "CARGO_NET_OFFLINE=true"
set "CARGO_HOME=%SRC_DIR%\.cargo-home"
if not exist "%CARGO_HOME%" mkdir "%CARGO_HOME%"
if not exist "%SRC_DIR%\readcon-vendor" (
    echo ERROR: readcon-vendor not found under %SRC_DIR%
    exit 1
)
if not exist "%SRC_DIR%\readcon-core-src" (
    echo ERROR: readcon-core-src not found under %SRC_DIR%
    exit 1
)
set "READCON_SRC=%SRC_DIR%\readcon-core-src"
if not exist "%READCON_SRC%\Cargo.toml" (
    for /d %%D in ("%SRC_DIR%\readcon-core-src\readcon-core-*") do (
        if exist "%%D\Cargo.toml" set "READCON_SRC=%%D"
    )
)
if not exist "%READCON_SRC%\Cargo.toml" (
    echo ERROR: readcon-core Cargo.toml not found
    exit 1
)

:: Write cargo offline config with absolute vendor path (Windows backslashes -> forward).
set "READCON_VENDOR=%SRC_DIR%\readcon-vendor"
set "READCON_VENDOR=%READCON_VENDOR:\=/%"
> "%CARGO_HOME%\config.toml" (
    echo [source.crates-io]
    echo replace-with = "vendored-sources"
    echo.
    echo [source.vendored-sources]
    echo directory = "%READCON_VENDOR%"
    echo.
    echo [net]
    echo offline = true
)

set "READCON_PREFIX=%SRC_DIR%\readcon-prefix"
if not exist "%READCON_PREFIX%" mkdir "%READCON_PREFIX%"

pushd "%READCON_SRC%"
copy /Y "%RECIPE_DIR%\readcon-core-Cargo.lock" Cargo.lock >nul
cargo-bundle-licenses --format yaml --output "%SRC_DIR%\readcon-THIRDPARTY.yml"
if errorlevel 1 (popd & exit 1)
cargo cinstall --offline --locked --release --prefix "%READCON_PREFIX%" --libdir lib --includedir include --pkgconfigdir lib/pkgconfig
if errorlevel 1 (popd & exit 1)
popd
copy /Y "%SRC_DIR%\readcon-THIRDPARTY.yml" "%READCON_PREFIX%\readcon-THIRDPARTY.yml" >nul

set "PKG_CONFIG_PATH=%READCON_PREFIX%\lib\pkgconfig;%PKG_CONFIG_PATH%"
set "LIB=%READCON_PREFIX%\lib;%LIB%"
set "INCLUDE=%READCON_PREFIX%\include;%INCLUDE%"
set "PATH=%READCON_PREFIX%\bin;%PATH%"

:: Remove wrap files to prevent meson from building subprojects from source
del /q subprojects\xtb.wrap 2>nul
del /q subprojects\vesin.wrap 2>nul
del /q subprojects\rgpot.wrap 2>nul
del /q subprojects\readcon-core.wrap 2>nul

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

:: flang_rt import libs live under clang resource dir; MSVC link needs LIBPATH
:: (LNK1104: cannot open file 'flang_rt.runtime.dynamic.lib' otherwise).
set "FLANG_RT_DIR="
for /f "delims=" %%R in ('flang -print-resource-dir 2^>nul') do set "FLANG_RT_DIR=%%R\lib\x86_64-pc-windows-msvc"
if defined FLANG_RT_DIR (
    if exist "%FLANG_RT_DIR%\flang_rt.runtime.dynamic.lib" (
        set "LIB=%FLANG_RT_DIR%;%LIB%"
        echo Using flang_rt LIBPATH: %FLANG_RT_DIR%
    )
)
if not defined FLANG_RT_DIR (
    for /d %%D in ("%LIBRARY_PREFIX%\lib\clang\*") do (
        if exist "%%D\lib\x86_64-pc-windows-msvc\flang_rt.runtime.dynamic.lib" (
            set "LIB=%%D\lib\x86_64-pc-windows-msvc;%LIB%"
            echo Using flang_rt LIBPATH: %%D\lib\x86_64-pc-windows-msvc
        )
    )
)

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
    --pkg-config-path="%READCON_PREFIX%\lib\pkgconfig;%LIBRARY_LIB%\pkgconfig" ^
    --cmake-prefix-path="%LIBRARY_PREFIX%" ^
    --buildtype=release ^
    build
if errorlevel 1 exit 1

meson compile -C build -v
if errorlevel 1 exit 1

meson install -C build
if errorlevel 1 exit 1

:: Ship readcon runtime DLLs next to eonclient.
if exist "%READCON_PREFIX%\bin" (
    if not exist "%LIBRARY_BIN%" mkdir "%LIBRARY_BIN%"
    copy /Y "%READCON_PREFIX%\bin\*.dll" "%LIBRARY_BIN%\" >nul 2>&1
)
if exist "%READCON_PREFIX%\lib" (
    if not exist "%LIBRARY_LIB%" mkdir "%LIBRARY_LIB%"
    copy /Y "%READCON_PREFIX%\lib\*.dll" "%LIBRARY_BIN%\" >nul 2>&1
    copy /Y "%READCON_PREFIX%\lib\*.lib" "%LIBRARY_LIB%\" >nul 2>&1
)
