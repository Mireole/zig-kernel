#!/bin/bash

set -e

echo "Fetching OVMF firmware..."

mkdir -p ovmf

# x86_64
curl -Lso ovmf/ovmf-code-x86_64.fd https://github.com/osdev0/edk2-ovmf-nightly/releases/latest/download/ovmf-code-x86_64.fd

# aarch64
curl -Lso ovmf/ovmf-code-aarch64.fd https://github.com/osdev0/edk2-ovmf-nightly/releases/latest/download/ovmf-code-aarch64.fd
dd if=/dev/zero of=ovmf/ovmf-code-aarch64.fd bs=1 count=0 seek=67108864 2>/dev/null

# riscv64
curl -Lso ovmf/ovmf-code-riscv64.fd https://github.com/osdev0/edk2-ovmf-nightly/releases/latest/download/ovmf-code-riscv64.fd
dd if=/dev/zero of=ovmf/ovmf-code-riscv64.fd bs=1 count=0 seek=33554432 2>/dev/null

echo "Done."

exit 0