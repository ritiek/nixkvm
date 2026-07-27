This builds an Image for a Raspberry Pi 4 or Pi Zero 2 W that runs PiKVM.

This is a fork of [matthewcroughan/nixkvm](https://github.com/matthewcroughan/nixkvm), with the
real PiKVM daemon (`kvmd`) wired up: custom kernel patches, HDMI-to-CSI capture (TC358743),
USB-OTG HID/mass-storage emulation, and MJPEG/H.264/WebRTC streaming.

# Usage

1. Clone this repo, enter it and build an SD card image for your board:
```
# Pi Zero 2 W -- tested end-to-end on real hardware in this fork: custom kernel patches,
# HDMI-to-CSI capture, USB-OTG HID/mass-storage emulation, and MJPEG/H.264/WebRTC streaming
# are all confirmed working.
nix build .#nixosConfigurations.pizero2w.config.system.build.sdImage

# Pi 4 -- WARNING: NOT tested with the changes made in this fork (custom kernel, device-tree
# overlay merging, kvmd wiring). Has not even been built, let alone flashed/booted, since
# those changes landed. Will likely need further debugging before it works -- in particular,
# double check the `boardDtbRelPath` used for bcm2711-rpi-4-b.dtb against the same board-DTB
# naming ambiguity that had to be fixed for the Zero 2 W, and expect the custom kernel build
# to need its own debugging pass.
nix build .#nixosConfigurations.pi4.config.system.build.sdImage
```

Or just do it remotely without cloning this repo:
```
nix build github:ritiek/nixkvm#nixosConfigurations.pizero2w.config.system.build.sdImage
```
