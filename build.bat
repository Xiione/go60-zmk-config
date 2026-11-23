@echo off
setlocal
set IMAGE=go60-zmk-config-docker
if not "%~1"=="" set "ZMK_REF=%~1"
docker build -t "%IMAGE%" . || exit /b 1
docker run --rm -v "%cd%:/config" -e ZMK_REPOSITORY -e ZMK_REF "%IMAGE%"
exit /b %ERRORLEVEL%
