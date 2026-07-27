This builds an Image for a Raspberry Pi 3, Pi 4, or Pi Zero 2 W that runs PiKVM.

# Usage

1. Clone this repo, enter it and
```
nix build .#images.pi
```

Or just do it remotely without cloning this repo: `nix build github:matthewcroughan/nixkvm#images.pi`
