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
            services.udev.extraRules = ''
              KERNEL=="vcio", GROUP="video", MODE="0660"
            '';

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
            ({ pkgs, ... }: {
              boot.kernelPackages = mkPiKvmKernel { inherit pkgs; rpiVersion = 4; };
              services.kvmd.variant = "v2-hdmi-rpi4";
            })
          ];
        };
        pizero2w = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          system = "aarch64-linux";
          modules = sharedModules ++ [
            ({ pkgs, ... }: {
              boot.kernelPackages = mkPiKvmKernel { inherit pkgs; rpiVersion = 3; };
              services.kvmd.variant = "v2-hdmi-zero2w";
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
