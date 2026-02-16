@echo on

:: Remove wrap files to prevent meson from building subprojects from source
:: All dependencies are provided by conda packages
del /q subprojects\xtb.wrap 2>nul
del /q subprojects\vesin.wrap 2>nul

meson setup -Dpython.install_env=prefix ^
    --default-library=static ^
    -Dwith_metatomic=True ^
    -Dwith_xtb=True ^
    -Dwith_fortran=false ^
    -Dwith_cuh2=false ^
    -Dpip_metatomic=False ^
    -Dtorch_path="%PREFIX%" ^
    %MESON_ARGS% build
if errorlevel 1 exit 1

meson compile -C build -v
if errorlevel 1 exit 1

meson install -C build
if errorlevel 1 exit 1
