{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    matthewcroughan.url = "github:matthewcroughan/nixcfg";
    kvmd-nix.url = "github:aostanin/kvmd.nix";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, matthewcroughan, kvmd-nix, nixos-hardware, ... }@inputs:
    let
      # PiKVM kernel patches shared across all boards.
      mkPiKvmKernel = { pkgs, rpiVersion }: let
        system = pkgs.stdenv.hostPlatform.system;
        patchDir = "${kvmd-nix.packages.${system}.pikvm-packages}/packages/linux-rpi-pikvm";
        pikvmKernelPatches = [
          { name = "pikvm-hid-remote-wakeup"; patch = "${patchDir}/1001-pikvm-hid-remote-wakeup-support.patch"; }
          { name = "pikvm-hid-clean-set-report-buf"; patch = "${patchDir}/1002-pikvm-hid-clean-set_report_buf-on-hidg-disabling.patch"; }
          { name = "pikvm-msd-dvd-support"; patch = "${patchDir}/2001-pikvm-msd-dvd-support.patch"; }
          { name = "pikvm-msd-inquiry-flash-cdrom"; patch = "${patchDir}/2002-pikvm-msd-inquiry-for-flash-and-cdrom.patch"; }
        ];
        baseKernel = pkgs.callPackage "${nixos-hardware}/raspberry-pi/common/kernel.nix" {
          inherit rpiVersion;
        };
      in pkgs.linuxPackagesFor (baseKernel.override {
        argsOverride.kernelPatches = baseKernel.kernelPatches ++ pikvmKernelPatches;
      });

      # NixOS's U-Boot + generic-extlinux-compatible boot chain loads DTBs
      # straight from a static FDTDIR (the plain kernel-package dtbs),
      # completely bypassing whatever RPi firmware would have constructed
      # from config.txt `dtoverlay=` at boot time. Overlays must instead be
      # merged into the DTB files themselves at Nix build time.
      #
      # nixpkgs' hardware.deviceTree.overlays (pkgs.deviceTree.applyOverlays)
      # requires each overlay's root "compatible" string to intersect the
      # target DTB's "compatible" list. RPi's own overlays (tc358743.dtbo
      # included) all declare a bare `compatible = "brcm,bcm2835";` (the
      # original Pi1 SoC) regardless of which board they're actually for,
      # because RPi's own firmware dtoverlay mechanism never checks
      # "compatible" at merge time. That means applyOverlays silently SKIPS
      # our overlays on every real modern board DTB (bcm2837/bcm2711/etc.
      # never match "brcm,bcm2835") -- a silent no-op, not a build failure.
      #
      # So instead we call `fdtoverlay` (from pkgs.dtc) directly: the same
      # underlying libfdt merge RPi firmware itself uses, which does NOT
      # check "compatible" at all. We only touch the one board DTB we
      # actually boot, leaving the rest of the kernel's dtbs tree untouched.
      mkMergedDeviceTree = { pkgs, kernelPackages, boardDtbRelPath }: let
        dwc2PeripheralDts = pkgs.writeText "dwc2-peripheral.dts" ''
          /dts-v1/;
          /plugin/;
          / {
            compatible = "brcm,bcm2835";
            fragment@0 {
              target = <&usb>;
              __overlay__ {
                compatible = "brcm,bcm2835-usb";
                dr_mode = "peripheral";
                g-np-tx-fifo-size = <32>;
                g-rx-fifo-size = <558>;
                g-tx-fifo-size = <512 512 512 512 512 256 256>;
                status = "okay";
              };
            };
          };
        '';
      in pkgs.runCommand "device-tree-merged" {
        nativeBuildInputs = [ pkgs.dtc ];
      } ''
        cp -r ${kernelPackages.kernel}/dtbs $out
        chmod -R u+w $out
        dtc -@ -I dts -O dtb -o dwc2-peripheral.dtbo ${dwc2PeripheralDts}
        fdtoverlay -i "$out/${boardDtbRelPath}" -o merged.dtb \
          ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/tc358743.dtbo \
          dwc2-peripheral.dtbo
        mv merged.dtb "$out/${boardDtbRelPath}"
      '';

      # Modules shared by every board target (Pi 4 and Pi Zero 2 W).
      sharedModules = [
        "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        "${matthewcroughan}/mixins/common.nix"
        kvmd-nix.nixosModules.kvmd
        (
          { pkgs, lib, ... }:
          {
            system.stateVersion = "25.11";
            environment.systemPackages = with pkgs; [ vim git ];
            nix = {
              package = pkgs.nixVersions.latest;
              extraOptions = ''
                experimental-features = nix-command flakes
              '';
            };
            zramSwap = {
              memoryPercent = 90;
              enable = true;
              algorithm = "zstd";
            };
            services.tailscale.enable = true;
            services.ttyd.enable = true;
            services.ttyd.writeable = true;
            # Log in to the ttyd web terminal as our own user (not root),
            # matching the password set below.
            services.ttyd.user = "ritiek";
            services.openssh = {
              enable = true;
              settings = {
                PermitRootLogin = "no";
                PasswordAuthentication = false;
                KexAlgorithms = [
                  "curve25519-sha256"
                  "curve25519-sha256@libssh.org"
                  "diffie-hellman-group-exchange-sha256"
                ];
              };
            };
            hardware.enableRedistributableFirmware = true;
            services.avahi = {
              enable = true;
              openFirewall = true;
              nssmdns4 = true;
              publish = {
                enable = true;
                addresses = true;
                workstation = true;
              };
            };
            networking = {
              useDHCP = true;
              firewall.allowedTCPPorts = [ 7681 ];
              wireless = {
                enable = true;
                interfaces = [ "wlan0" ];
              };
              interfaces = {
                "wlan0".useDHCP = true;
                "eth0".useDHCP = true;
              };
              hostName = "pikvm";
            };
            security = {
              sudo.enable = false;
              sudo-rs = {
                enable = true;
                wheelNeedsPassword = false;
              };
            };
            documentation = {
              enable = false;
              man.enable = false;
              doc.enable = false;
              dev.enable = false;
              info.enable = false;
              nixos.enable = false;
            };
            boot.tmp = {
              useTmpfs = false;
              cleanOnBoot = true;
            };
            users = {
              mutableUsers = false;
              users.ritiek = {
                isNormalUser = true;
                # OS login password, used for both console/ttyd login.
                password = "pikvm";
                openssh.authorizedKeys.keys = [
                  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAINmHZVbmzdVkoONuoeJhfIUDRvbhPeaSkhv0LXuNIyFfAAAAEXNzaDpyaXRpZWtAeXViaWth"
                  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHVwHXOotXjPLC/fXIEu/Xnc5ZiIwOKK4Amas/rb9/ZGAAAAEnNzaDpyaXRpZWtAeXViaWtrbw=="
                  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAUVNBe5AkMEPT9fell8hjKrRh6CNaZBDNeBozB8TJseAAAAFHNzaDpyaXRpZWtAeXViaXNjdWl0"
                  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEDg65I7F0cj4CFSbIlJ004zwq4IsxtAgyPlzFGXOUOUAAAAEnNzaDpyaXRpZWtAeXViaXNlYQ=="
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8R2qe15XyGUVQSHlPsDg6lE9ekfoB+qRA6jjw9pXD5"
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG8pxSJhzTQav5ZHhaqDMy3zMcOBRyXdvNAE2gXM8y6h"
                ];
                extraGroups = [ "wheel" ]; # Enable 'sudo' for the user.
              };
            };

            # --- Real PiKVM (kvmd) daemon + board-agnostic capture/OTG wiring ---
            # We deliberately do NOT use kvmd-nix's own `modules/variants/*.nix` or
            # its `nixos-hardware` dependency: those hardcode Pi4/bcm2711-specific
            # hand-derived device-tree overlays with no Pi Zero 2 W equivalent.
            # Instead we wire the hardware ourselves using the official, generic,
            # precompiled Raspberry Pi firmware overlays (dtoverlay=), which are
            # confirmed portable across the Pi 3/4/Zero-2W family.
            services.kvmd.enable = true;

            boot.kernelModules = [ "dwc2" "tc358743" ];
            boot.kernelParams = [ "cma=192M" ];
            # sd-image-aarch64's cross-SBC initrd list FATALs on modules the rpi
            # kernel lacks; force the minimal set it actually has.
            boot.initrd.availableKernelModules = lib.mkForce [ "ext4" "mmc_block" "usbhid" "usb_storage" "xhci_hcd" "vc4" "pcie-brcmstb" "reset-raspberrypi" ];
            services.udev.extraRules = ''
              KERNEL=="vcio", GROUP="video", MODE="0660"
            '';

            # (Device-tree overlay merging into FDTDIR is handled per-board
            # below via mkMergedDeviceTree, since fdtoverlay needs to know
            # which single board DTB to patch. See mkMergedDeviceTree's
            # comment above for the full rationale.)

            # Append our overlays to the config.txt already written by
            # sd-image-aarch64.nix (populateFirmwareCommands has no declared
            # type, so plain string concatenation applies; mkAfter guarantees
            # our lines land after the base module's script runs).
            sdImage.populateFirmwareCommands = lib.mkAfter ''
              # sd-image-aarch64.nix copies config.txt from the Nix store,
              # which lands read-only; make it writable before appending.
              chmod +w firmware/config.txt
              cat >> firmware/config.txt << 'CONFIGTXT'

              [all]
              dtoverlay=dwc2,dr_mode=peripheral
              dtoverlay=tc358743
              CONFIGTXT

              # sd-image-aarch64.nix doesn't copy overlays/ from raspberrypifw,
              # but dtoverlay=tc358743 and dtoverlay=dwc2 need the .dtbo files.
              cp -r ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays firmware/
            '';
          }
        )
      ];
    in
    {
      nixosConfigurations = {
        pi4 = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          system = "aarch64-linux";
          modules = sharedModules ++ [
            ({ pkgs, lib, config, ... }: {
              boot.kernelPackages = mkPiKvmKernel { inherit pkgs; rpiVersion = 4; };
              services.kvmd.variant = "v2-hdmi-rpi4";
              hardware.deviceTree.package = lib.mkForce (mkMergedDeviceTree {
                inherit pkgs;
                inherit (config.boot) kernelPackages;
                boardDtbRelPath = "broadcom/bcm2711-rpi-4-b.dtb";
              });
            })
          ];
        };
        pizero2w = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          system = "aarch64-linux";
          modules = sharedModules ++ [
            ({ pkgs, lib, config, ... }: {
              boot.kernelPackages = mkPiKvmKernel { inherit pkgs; rpiVersion = 3; };
              services.kvmd.variant = "v2-hdmi-zero2w";
              hardware.deviceTree.package = lib.mkForce (mkMergedDeviceTree {
                inherit pkgs;
                inherit (config.boot) kernelPackages;
                boardDtbRelPath = "broadcom/bcm2837-rpi-zero-2-w.dtb";
              });
            })
          ];
        };
      };
      images = {
        pi4 = self.nixosConfigurations.pi4.config.system.build.sdImage;
        pizero2w = self.nixosConfigurations.pizero2w.config.system.build.sdImage;
      };
    };
}
