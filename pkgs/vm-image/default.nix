{
  _lib,
  inputs,
  lib,
  pkgs,

  copyDirectories ? { },
  debug ? false,
  extraConfig ? { },
  onDemand ? {
    enable = false;
    ttl = 180;
  },
  rosetta ? false,
  sharedDirectories ? { },
  timeSync ? {
    enable = true;
    vsockPort = 1025;
  },
}:

let
  cfg = {
    inherit
      copyDirectories
      debug
      onDemand
      rosetta
      sharedDirectories
      timeSync
      ;
  };

  nixosSystem = lib.nixosSystem {
    inherit pkgs;
    specialArgs = { inherit _lib cfg inputs; };
    modules = [
      ./image-config.nix
      extraConfig
    ];
  };
  image = nixosSystem.config.system.build.images.raw-efi;
in

image
// {
  nixosConfiguration = nixosSystem;
  passthru = (image.passthru or { }) // {
    nixosConfiguration = nixosSystem;
  };
}
