@echo on

:: Remove wrap files to prevent meson from building subprojects from source
:: All dependencies are provided by conda packages
del /q subprojects\xtb.wrap 2>nul
del /q subprojects\vesin.wrap 2>nul

:: Diagnostic: List available xtb files
dir /s "%LIBRARY_PREFIX%\*xtb*"

:: Generate MSVC-compatible import library from MinGW-built xtb DLL
:: The xtb conda package is built with m2w64 and only ships libxtb.dll.a
if exist "%LIBRARY_BIN%\libxtb-6.dll" (
    set "XTB_DLL_NAME=libxtb-6.dll"
) else if exist "%LIBRARY_BIN%\libxtb.dll" (
    set "XTB_DLL_NAME=libxtb.dll"
) else (
    echo "ERROR: libxtb DLL not found"
    exit 1
)

dumpbin /EXPORTS "%LIBRARY_BIN%\%XTB_DLL_NAME%" > xtb_exports.txt
if errorlevel 1 exit 1

echo LIBRARY %XTB_DLL_NAME% > xtb.def
echo EXPORTS >> xtb.def
for /f "skip=19 tokens=4" %%A in (xtb_exports.txt) do (
    if not "%%A"=="" echo     %%A >> xtb.def
)
lib /DEF:xtb.def /OUT:"%LIBRARY_LIB%\xtb.lib" /MACHINE:X64
if errorlevel 1 exit 1

meson setup -Dpython.install_env=prefix ^
    --prefix="%PREFIX%" ^
    --default-library=static ^
    -Dwith_metatomic=True ^
    -Dwith_xtb=True ^
    -Dwith_fortran=false ^
    -Dwith_cuh2=false ^
    -Dpip_metatomic=False ^
    -Dtorch_path="%LIBRARY_PREFIX%" ^
    --pkg-config-path="%LIBRARY_LIB%\pkgconfig" ^
    --cmake-prefix-path="%LIBRARY_PREFIX%" ^
    --buildtype=release ^
    --wrap-mode=nofallback ^
    build
if errorlevel 1 exit 1

meson compile -C build -v
if errorlevel 1 exit 1

meson install -C build
if errorlevel 1 exit 1
