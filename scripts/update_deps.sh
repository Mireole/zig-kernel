#!/bin/bash

set -e

scriptDir=$(dirname -- "$(readlink -f -- "$BASH_SOURCE")")

# limine
zig fetch --save=limine git+https://github.com/limine-bootloader/limnine#v9.x-binary
zig fetch --save git+https://github.com/uACPI/zuacpi?ref=mai

# ovmf
"$scriptDir/fetch_ovmf.sh"