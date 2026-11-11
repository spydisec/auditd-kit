#!/bin/sh
# Boot a cloud image in a VM on a GitHub Ubuntu runner and run real-kernel.sh inside it.
#
# Usage: sh tests/ci/vm-run.sh <image-url> <checksums-url> <minimal|medium|heavy>
#
# GitHub has no RHEL-family runners, so this is how the rules get loaded into such a kernel. The
# image is checked against the checksum file from the same server. That catches a broken
# download, and the VM is thrown away with the runner. It needs sudo for apt and for /dev/kvm.
set -eu

image_url=$1
sums_url=$2
profile=$3
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." >/dev/null && pwd)
work=$(mktemp -d)
cd "$work"

echo "== Install QEMU"
sudo apt-get update -q
sudo apt-get install -y -q --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils
sudo chmod 666 /dev/kvm

echo "== Download and check the image"
image=${image_url##*/}
curl -fsSL --retry 3 -o "$image" "$image_url"
curl -fsSL --retry 3 -o sums "$sums_url"
# The checksum file may list other images, in either the GNU or the BSD format.
grep -F -e "  $image" -e "($image)" sums >sum
[ "$(wc -l <sum)" -eq 1 ] || {
  echo "FAIL: no single checksum for $image" >&2
  exit 1
}
sha256sum -c sum

echo "== Boot the VM"
qemu-img create -q -f qcow2 -F qcow2 -b "$image" disk.qcow2 20G
ssh-keygen -q -t ed25519 -N '' -f key
cat >user-data <<USERDATA
#cloud-config
users:
  - name: ci
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat key.pub)
USERDATA
cloud-localds seed.iso user-data
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 -display none -daemonize \
  -drive file=disk.qcow2,if=virtio \
  -drive file=seed.iso,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
  -serial file:console.log

vm() {
  ssh -q -i key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 ci@127.0.0.1 "$@"
}
tries=0
until vm true 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 60 ]; then
    echo "FAIL: the VM didn't answer on ssh. The end of its console:" >&2
    tail -n 40 console.log >&2
    exit 1
  fi
  sleep 5
done
vm 'cat /etc/os-release; uname -r'

echo "== Run the test in the VM"
tar -czf - -C "$repo" scripts rules config tests/ci | vm 'mkdir akit && tar -xzf - -C akit'
vm "cd akit && sudo AKIT_CI_OK=yes sh tests/ci/real-kernel.sh $profile"
