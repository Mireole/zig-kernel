#!/bin/bash

set -e

scriptDir=$(dirname -- "$(readlink -f -- "$BASH_SOURCE")")

# limine
zig fetch --save=limine git+https://github.com/limine-bootloader/limine#v8.x-binary

# ovmf
"$scriptDir/fetch_ovmf.sh"