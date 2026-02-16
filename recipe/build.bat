@echo on

:: Remove wrap files to prevent meson from building subprojects from source
:: All dependencies are provided by conda packages
del /q subprojects\xtb.wrap 2>nul
del /q subprojects\vesin.wrap 2>nul

:: Generate MSVC-compatible import library from MinGW-built xtb DLL
:: The xtb conda package is built with m2w64 and only ships libxtb.dll.a
dumpbin /EXPORTS "%LIBRARY_BIN%\libxtb-6.dll" > xtb_exports.txt
echo LIBRARY libxtb-6.dll > xtb.def
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
