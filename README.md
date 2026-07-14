# Virby - Linux Builder for Nix-darwin

Virby is a module for [nix-darwin](https://github.com/nix-darwin/nix-darwin) that configures a lightweight, [vfkit](https://github.com/crc-org/vfkit)-based linux VM as a remote build machine for nix, allowing linux packages to be built on macOS. This project is modeled after [nix-rosetta-builder](https://github.com/cpick/nix-rosetta-builder), which provides a similar service, using lima to manage the VM. Some parts of the code in this repository are directly borrowed and adapted from that project.

## Quick Start

Add virby to your flake inputs:

```nix
{
  inputs = {
    virby.url = "github:quinneden/virby-nix-darwin";
    # It is important that you dont add the line:
    # 
    #   inputs.nixpkgs.follows = "nixpkgs";
    #
    # until after you've activated with `darwin-rebuild`. This way, the cached
    # image can be used and you won't have to build from source (which requires
    # an existing aarch64-linux builder).
  };

  outputs = { virby, ... }: {
    darwinConfigurations."myHost" = {
      # Import the module
      modules = [ virby.darwinModules.default ];
    };
  };
}
```

> [!Important]
> When enabling Virby for the first time, you must add the binary cache to your Nix configuration. This ensures that the prebuilt VM image is available for download, rather than having to be built locally, which requires an existing linux builder. You can do this in one of two ways:

Add the binary cache to your configuration **before** enabling Virby:

```nix
{
  nix.settings.extra-substituters = [ "https://virby-nix-darwin.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [
    "virby-nix-darwin.cachix.org-1:z9GiEZeBU5bEeoDQjyfHPMGPBaIQJOOvYOOjGMKIlLo="
  ];
  
  services.virby.enable = false;
}
```

Run `darwin-rebuild`, then enable Virby:

```nix
{
  nix.settings.extra-substituters = [ "https://virby-nix-darwin.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [
    "virby-nix-darwin.cachix.org-1:z9GiEZeBU5bEeoDQjyfHPMGPBaIQJOOvYOOjGMKIlLo="
  ];
  
  # Don't configure any other Virby options until after you've switched to the new
  # configuration. If the hash for the disk image derivation doesn't match the one
  # in the binary cache, then nix will try to build the image locally.
  services.virby.enable = true;
}
```

Finally, rebuild again.

**OR**

Run the `darwin-rebuild` command with the following options:

```bash
sudo darwin-rebuild switch --flake .#myHost \
  --option "extra-substituters" "https://virby-nix-darwin.cachix.org" \
  --option "extra-trusted-public-keys" "virby-nix-darwin.cachix.org-1:z9GiEZeBU5bEeoDQjyfHPMGPBaIQJOOvYOOjGMKIlLo="
```

If you prefer building the image locally, you can enable the `nix.linux-builder` option before enabling Virby:

```nix
{
  nix.linux-builder.enable = true;

  services.virby.enable = false;
}
```

## Key Features

- **On-demand activation** (optional) - VM is started when needed, then shuts down after a period of inactivity
- **Rosetta support** (optional) - Build `x86_64-linux` packages on Apple Silicon using Rosetta translation
- **Secure by default** - Host-only access via loopback (i.e. `127.0.0.1`), with automatic ED25519 key generation
- **Fully configurable** - Adjust VM resources and add custom NixOS modules

## Configuration

### Basic Settings

| Option        | Type       | Default    | Description                                  |
|---------------|------------|------------|----------------------------------------------|
| `enable`      | _bool_       | `false`    | Enable the service                           |
| `cores`       | _int_        | `8`        | CPU cores allocated to VM                    |
| `memory`      | _int_ or _string_ | `6144`     | Memory in MiB or string format (e.g. "6GiB") |
| `diskSize`    | _string_     | `"100GiB"` | VM disk size                                 |
| `port`        | _int_        | `31222`    | SSH port for VM access                       |
| `speedFactor` | _int_        | `1`        | Speed factor for Nix build machine           |
| `timeSync.enable` | _bool_   | `true`     | Correct guest time immediately after macOS wakes |
| `timeSync.vsockPort` | _int_ | `1025`     | Dedicated host-to-guest time-sync vsock port |

### Other Settings

**On-demand Activation**

```nix
{
  services.virby.onDemand.enable = true;
  services.virby.onDemand.ttl = 180;  # Idle timeout in minutes
}
```

**Guest Time Synchronization**

Virby enables vfkit's macOS wake-time synchronization by default. A restricted QEMU Guest Agent
inside the NixOS image listens only for `guest-set-time` over a host-only virtio-vsock channel.
This avoids waiting for the guest's next NTP poll after the Mac wakes.

```nix
{
  services.virby.timeSync = {
    enable = true;
    vsockPort = 1025;
  };
}
```

Disable this only when the guest supplies an equivalent host-resume synchronization mechanism.
Changing the setting requires updating the VM image as well as restarting the host runner.

**Rosetta Support**

```nix
# Requires `aarch64-darwin` host
{
  services.virby.rosetta = true;
}
```

**Copy host files into the guest without a persistent mount**

```nix
{
  services.virby.copyDirectories.PiSecrets = {
    source = "/Users/alice/.pi/agent";
    target = "/Users/alice/.pi/agent";
    files = [ "auth.json" "oauth.json" "models.json" ];
    owner = "alice";
    group = "staff";
  };
}
```

`copyDirectories` exposes each source as a virtio-fs device, mounts it read-only in a one-shot guest service, copies the selected relative files to the target, and unmounts it again. Use `sharedDirectories` when the guest should keep seeing live host files; use `copyDirectories` when the guest should get local copies.

**Custom NixOS Configuration**


```nix
{
  services.virby.extraConfig = {
    inherit (config.nix) settings;
    # Some NixOS options which are defined in the default VM configuration cannot
    # be overridden, such as `networking.hostName`. Others may be overridden with
    # `lib.mkForce`. Also note that anything changed here will cause a rebuild of
    # the VM image, and SSH keys will be regenerated.
  };
}
```
> [!Warning]
> This option allows you to arbitrarily change the NixOS configuration, which could expose the VM to security risks.

**Debug Options** (insecure, for troubleshooting only)

```nix
{
  services.virby.debug = true;         # Enable verbose logging
  services.virby.allowUserSsh = true;  # Allow non-root SSH access with a separate shared key copy
}
```

## Architecture

Virby integrates three components:

- **nix-darwin Module** - Configures VM as a Nix build machine for host
- **VM Image** - Minimal NixOS disk image configured for secure ssh access and build isolation
- **VM Runner** - Python package managing VM lifecycle and SSH proxying

**Build workflow:** Linux build requested → VM started (if needed) → Build on VM → Results copied to host → VM shutdown (after idle timeout)

**Security model:**
- VM doesn't accept remote connections as it binds to the loopback interface
- SSH keys are generated and copied to the VM on first run.
- `builder` user has minimal permissions, root access is restricted by default

## Benchmarks

| Test | Command | Mean&nbsp;[s] | Min&nbsp;[s] | Max&nbsp;[s] | Relative |
|:-----|:--------|---------:|--------:|--------:|---------:|
| Boot | `ssh virby-vm -- true` (triggers startup in on-demand mode) | 9.203&nbsp;±&nbsp;0.703 | 7.795 | 9.818 | 1.00 |
| Build | `nix build --rebuild nixpkgs#hello` | 8.136 ±&nbsp;0.031 | 8.087 | 8.173 | 1.00 |

## Troubleshooting

**Debug logging**
```nix
{
  # Enable debug logging to `/tmp/virbyd.log`
  services.virby.debug = true;
}
```

```bash
# View daemon logs
tail -f /tmp/virbyd.log
```

**SSH into VM**

```bash
# Requires `allowUserSsh = true`
ssh virby-vm
# or use sudo
```

## Acknowledgments

- Inspired by [nix-rosetta-builder](https://github.com/cpick/nix-rosetta-builder)
- Uses [vfkit](https://github.com/crc-org/vfkit)

---

**License**: MIT - see [LICENSE](LICENSE) file for details.
