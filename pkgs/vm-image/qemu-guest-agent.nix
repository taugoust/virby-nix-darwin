{ qemu_kvm }:

qemu_kvm.overrideAttrs (oldAttrs: {
  patches = (oldAttrs.patches or [ ]) ++ [ ./qemu-ga-hwclock-noadjfile.patch ];
})
