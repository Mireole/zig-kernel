#!/bin/bash

set -e

git -C "limine" pull || git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1

exit 0