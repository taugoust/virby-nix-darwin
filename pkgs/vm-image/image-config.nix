{
  _lib,
  cfg,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (_lib.constants)
    sshHostPrivateKeyFileName
    sshUserPublicKeyFileName
    vmHostName
    vmUser
    ;

  sshDirPath = "/etc/ssh/";
  sshHostPrivateKeyPath = sshDirPath + sshHostPrivateKeyFileName;
  qemuGuestAgent = pkgs.callPackage ./qemu-guest-agent.nix { };
  timeSync =
    cfg.timeSync or {
      enable = false;
      vsockPort = 1025;
    };
in

{
  imports = [ "${inputs.nixpkgs}/nixos/modules/image/file-options.nix" ];

  boot = {
    enableContainers = lib.mkDefault false;
    kernelParams = [ "console=hvc0" ];
    loader = {
      efi.canTouchEfiVariables = true;
      systemd-boot.enable = true;
      timeout = 0;
    };
  };

  documentation = {
    enable = false;
    nixos.enable = false;
    man.enable = false;
    info.enable = false;
    doc.enable = false;
  };

  environment = {
    defaultPackages = lib.mkDefault [ ];
    systemPackages = lib.optionals timeSync.enable [ pkgs.util-linux ];
    stub-ld.enable = lib.mkDefault false;
  };

  fileSystems = {
    "/".options = [
      "discard"
      "noatime"
    ];
    "/boot".options = [
      "discard"
      "noatime"
      "umask=0077"
    ];
  };

  image = lib.mkForce {
    baseName = "virby-vm-nixos-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
    extension = "img";
  };

  networking = {
    hostName = lib.mkForce vmHostName;
    dhcpcd.extraConfig = lib.mkForce ''
      clientid ""
    '';
  };

  nix = {
    channel.enable = false;
    registry.nixpkgs.flake = inputs.nixpkgs;

    settings =
      let
        gibibyte = 1024 * 1024 * 1024;
      in
      {
        auto-optimise-store = true;
        experimental-features = [
          "flakes"
          "nix-command"
        ];
        min-free = gibibyte * 5;
        max-free = gibibyte * 7;
        trusted-users = [ vmUser ];
      };
  };

  programs = {
    less.lessopen = lib.mkDefault null;
    command-not-found.enable = lib.mkDefault false;
    fish.generateCompletions = lib.mkDefault false;
  };

  security.sudo = {
    enable = cfg.debug;
    wheelNeedsPassword = !cfg.debug;
  };

  services = {
    getty = lib.optionalAttrs cfg.debug { autologinUser = vmUser; };
    logrotate.enable = lib.mkDefault false;

    openssh = {
      enable = true;
      hostKeys = [ ]; # disable automatic host key generation

      settings = {
        HostKey = sshHostPrivateKeyPath;
        PasswordAuthentication = false;
      };
    };

    udisks2.enable = lib.mkDefault false;
  };

  system = {
    disableInstallerTools = true;
    nixos.revision = null;
    stateVersion = "25.05";
    systemBuilderArgs.allowSubstitutes = true;
  };

  # Virtualization.framework's virtiofs implementation will grant any guest user access
  # to mounted files; they always appear to be owned by the effective UID and so access cannot
  # be restricted.
  # To protect the guest's SSH host key, the VM is configured to prevent any logins (via
  # console, SSH, etc) by default.  This service then runs before sshd, mounts virtiofs,
  # copies the keys to local files (with appropriate ownership and permissions), and unmounts
  # the filesystem before allowing SSH to start.
  # Once SSH has been allowed to start (and given the guest user a chance to log in), the
  # virtiofs must never be mounted again (as the user could have left some process active to
  # read its secrets). This is prevented by `unitconfig.ConditionPathExists` below.
  systemd.services = {
    install-sshd-keys =
      let
        mountTag = "sshd-keys";
        mountPoint = "/var/${mountTag}";
        authorizedKeysDir = "${sshDirPath}/authorized_keys.d";
      in
      {
        description = "Install sshd's host and authorized keys";

        path = with pkgs; [
          coreutils
          mount
          umount
        ];

        before = [ "sshd.service" ];
        requiredBy = [ "sshd.service" ];

        enableStrictShellChecks = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -euo pipefail

          cleanup() {
            umount ${mountPoint} 2>/dev/null || true
            rm -rf ${mountPoint}
          }
          trap cleanup EXIT

          mkdir -p ${mountPoint}

          for attempt in $(seq 1 20); do
            if mount -t virtiofs -o nodev,noexec,nosuid,ro ${mountTag} ${mountPoint}; then
              if [ -r ${mountPoint}/${sshHostPrivateKeyFileName} ] && [ -r ${mountPoint}/${sshUserPublicKeyFileName} ]; then
                break
              fi
              umount ${mountPoint} 2>/dev/null || true
            fi
            if [ "$attempt" -eq 20 ]; then
              echo "sshd key virtiofs mount did not contain required keys" >&2
              exit 1
            fi
            sleep 0.25
          done

          install -Dm600 -t ${sshDirPath} ${mountPoint}/${sshHostPrivateKeyFileName}
          install -Dm644 ${mountPoint}/${sshUserPublicKeyFileName} ${authorizedKeysDir}/${vmUser}
        '';
      };
  }
  // lib.optionalAttrs timeSync.enable {
    virby-time-sync-agent = {
      description = "Synchronize Virby guest time after macOS wakes";

      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      after = [ "systemd-modules-load.service" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${qemuGuestAgent.ga}/bin/qemu-ga"
          "--method=vsock-listen"
          "--path=4294967295:${toString timeSync.vsockPort}"
          "--allow-rpcs=guest-set-time"
          "--statedir=/run/virby-time-sync-agent"
          "--pidfile=/run/virby-time-sync-agent/qemu-ga.pid"
        ];
        Restart = "always";
        RestartSec = "1s";
        RuntimeDirectory = "virby-time-sync-agent";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";

        CapabilityBoundingSet = [ "CAP_SYS_TIME" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = false;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_VSOCK"
        ];
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
  }
  // lib.mapAttrs' (
    tag: copy:
    let
      mountPoint = "/run/virby-copy/${tag}";
      fileCopies = lib.concatMapStringsSep "\n" (file: ''
        src="$mount_point/${file}"
        dst=${lib.escapeShellArg "${copy.target}/${file}"}
        if [ -r "$src" ]; then
          install -d -m ${copy.directoryMode} -o ${copy.owner} -g ${copy.group} "$(dirname "$dst")"
          install -m ${copy.fileMode} -o ${copy.owner} -g ${copy.group} "$src" "$dst"
        fi
      '') copy.files;
    in
    lib.nameValuePair "copy-virby-directory-${tag}" {
      description = "Copy selected files from Virby directory '${tag}'";

      path = with pkgs; [
        coreutils
        mount
        umount
      ];

      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      before = [
        "multi-user.target"
        "home-manager-${copy.owner}.service"
      ];
      wantedBy = [ "multi-user.target" ];

      enableStrictShellChecks = true;
      serviceConfig.Type = "oneshot";

      script = ''
        set -euo pipefail

        mount_point=${lib.escapeShellArg mountPoint}

        cleanup() {
          umount "$mount_point" 2>/dev/null || true
          rm -rf "$mount_point"
        }
        trap cleanup EXIT

        install -d -m 0700 "$mount_point"
        mount -t virtiofs -o nodev,noexec,nosuid,ro ${lib.escapeShellArg tag} "$mount_point"
        install -d -m ${copy.directoryMode} -o ${copy.owner} -g ${copy.group} ${lib.escapeShellArg copy.target}

      ''
      + fileCopies
      + "";
    }
  ) cfg.copyDirectories;

  systemd.mounts = lib.mapAttrsToList (
    tag: _hostPath:
    let
      mountPoint = "/mnt/virtiofs/${tag}";
    in
    {
      description = "Mount Virby shared directory '${tag}'";
      what = tag;
      where = mountPoint;
      type = "virtiofs";
      options = "nodev,nosuid";
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" ];
    }
  ) cfg.sharedDirectories;

  systemd.tmpfiles.rules = lib.mapAttrsToList (
    tag: _hostPath: "d /mnt/virtiofs/${tag} 0755 root root - -"
  ) cfg.sharedDirectories;

  users = {
    allowNoPasswordLogin = true;
    mutableUsers = false;

    users.${vmUser} = {
      isNormalUser = true;
      extraGroups = lib.optional cfg.debug "wheel";
    };
  };

  virtualisation = {
    rosetta.enable = cfg.rosetta;
  };

  xdg = {
    autostart.enable = lib.mkDefault false;
    icons.enable = lib.mkDefault false;
    mime.enable = lib.mkDefault false;
    sounds.enable = lib.mkDefault false;
  };
}
