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
    install -d {{build-dir}}/MouseGauge.app/Contents/MacOS
    install -d {{build-dir}}/MouseGauge.app/Contents/Resources
    cp -f {{build-dir}}/debug/MouseGauge {{build-dir}}/MouseGauge.app/Contents/MacOS/MouseGauge
    cp -f Packaging/Info.plist {{build-dir}}/MouseGauge.app/Contents/Info.plist
    codesign --force --deep --sign "${MOUSEGAUGE_SIGN_IDENTITY:-${WLMOUSE_SIGN_IDENTITY:--}}" {{build-dir}}/MouseGauge.app

install: app
    bash scripts/install.sh "{{build-dir}}/MouseGauge.app"

repair-permissions:
    bash scripts/install.sh --repair-permissions

launch: app
    open {{build-dir}}/MouseGauge.app

open:
    open "$HOME/Applications/MouseGauge.app"

run:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} MouseGauge

once:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} MouseGauge --once

devices:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} MouseGauge --devices

probe:
    {{swift-env}} {{swift}} run --scratch-path {{build-dir}} MouseGauge --probe

clean:
    swift package clean
