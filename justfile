set dotenv-load

build-dir := env_var_or_default("SWIFTPM_BUILD_DIR", ".build")
swift := "/Library/Developer/CommandLineTools/usr/bin/swift"
swift-env := "env -u SDKROOT DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH=$PWD/.build/module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/swiftpm-module-cache"

default:
    just --list

list:
    just --list

build:
    {{swift-env}} {{swift}} build --scratch-path {{build-dir}}

app: build
    install -d {{build-dir}}/WLMouseMenuBar.app/Contents/MacOS
    install -d {{build-dir}}/WLMouseMenuBar.app/Contents/Resources
    cp -f {{build-dir}}/debug/WLMouseMenuBar {{build-dir}}/WLMouseMenuBar.app/Contents/MacOS/WLMouseMenuBar
    cp -f Packaging/Info.plist {{build-dir}}/WLMouseMenuBar.app/Contents/Info.plist
    codesign --force --deep --sign "${WLMOUSE_SIGN_IDENTITY:--}" {{build-dir}}/WLMouseMenuBar.app

install: app
    bash scripts/install.sh "{{build-dir}}/WLMouseMenuBar.app"

repair-permissions:
    bash scripts/install.sh --repair-permissions

launch: app
    open {{build-dir}}/WLMouseMenuBar.app

open:
    open "$HOME/Applications/WLMouseMenuBar.app"

run:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} WLMouseMenuBar

once:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} WLMouseMenuBar --once

devices:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} WLMouseMenuBar --devices

probe:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} WLMouseMenuBar --probe

clean:
    swift package clean
