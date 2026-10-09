#!/bin/bash
# SymbiOS - Build the OpenWrt KVM image and define the VM.
#
# Two subcommands, called from services/openwrt-vm.yml (KVM hosts only):
#   patch    grow the raw image, patch GRUB serial console, inject
#            first-boot scripts + root credentials (prints progress tokens)
#   define   write the libvirt domain XML and virsh-define it
# The password hash travels via OWRT_ROOT_PW_HASH (never argv). An EXIT
# trap releases the loop device and the mount when patch fails midway
# (the playbook version leaked both on errors).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <patch|define> [options]

  patch --root DIR --image FILE --disk-gb N --serial DEV --pubkey-file FILE
      Grow the raw image to N GB, grow p2, patch GRUB, inject uci-defaults
      + postconfig + root password + host SSH key. Template inputs are read
      from /tmp/ow-uci-network, /tmp/ow-uci-preconfig,
      /tmp/ow-postconfig-trigger, /tmp/ow-postconfig (written by the
      playbook). Root password hash via OWRT_ROOT_PW_HASH environment.

  define --root DIR --ram MB --vcpus N --arch ARCH --machine MACHINE --uefi FILE --cpu MODEL
      Write /tmp/openwrt-vm.xml and virsh-define the openwrt domain.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

# Loop/mount state for the EXIT trap (released on failure paths)
g_loop=""
g_mounted=""

function f_owrt_release {
  if [[ "${g_mounted}" == "yes" ]]
  then
    umount /tmp/ow-mount 2>/dev/null || true
    g_mounted=""
  fi
  if [[ -n "${g_loop}" ]]
  then
    losetup -d "${g_loop}" 2>/dev/null || true
    g_loop=""
  fi
}

function f_owrt_patch {
  local f_root="" f_image="" f_disk="" f_serial="" f_pubkey=""
  while [[ $# -gt 0 ]]
  do
    case "${1}" in
      --root) f_root="${2}"; shift 2;;
      --image) f_image="${2}"; shift 2;;
      --disk-gb) f_disk="${2}"; shift 2;;
      --serial) f_serial="${2}"; shift 2;;
      --pubkey-file) f_pubkey="${2}"; shift 2;;
      *) g_echo_error "unknown option: ${1}"; return 1;;
    esac
  done
  if [[ -z "${f_root}" || -z "${f_image}" || -z "${f_disk}" || -z "${f_serial}" || -z "${f_pubkey}" ]]
  then
    g_echo_error "patch needs --root/--image/--disk-gb/--serial/--pubkey-file"
    return 1
  fi
  if [[ -z "${OWRT_ROOT_PW_HASH:-}" ]]
  then
    g_echo_error "OWRT_ROOT_PW_HASH environment missing"
    return 1
  fi
  set -e
  trap f_owrt_release EXIT
  local f_raw="${f_root}/iso/${f_image}" f_loop f_i f_name f_src

  # Grow the raw image file to the requested disk size. The filesystem
  # and rootfs partition (p2) are grown below to fill the whole disk,
  # so the resulting qcow2 presents the disk size to the VM.
  truncate -s "${f_disk}G" "${f_raw}"

  # Attach raw image to loop device with partition scanning
  f_loop=$(losetup -fP --show "${f_raw}")
  g_loop="${f_loop}"
  echo "Loop device: ${f_loop}"

  # Wait for partition devices to appear
  sleep 2
  for f_i in $(seq 1 10)
  do
    [[ -b "${f_loop}p1" ]] && [[ -b "${f_loop}p2" ]] && break
    sleep 1
  done
  if [[ ! -b "${f_loop}p1" ]]
  then
    echo "ERROR: Partition devices not found on ${f_loop}"
    return 1
  fi

  # --- Grow rootfs partition (p2) + filesystem to full disk size ---
  # After truncate the backup GPT is no longer at the end of the disk.
  # sgdisk -e relocates it, then parted can resize non-interactively.
  sgdisk -e "${f_loop}"
  parted -s "${f_loop}" resizepart 2 100%
  partprobe "${f_loop}" 2>/dev/null || partx -u "${f_loop}"
  e2fsck -fy "${f_loop}p2" >/dev/null 2>&1 || true
  resize2fs "${f_loop}p2" >/dev/null
  echo "rootfs-grown"

  # --- Patch GRUB for serial console ---
  mkdir -p /tmp/ow-mount
  mount "${f_loop}p1" /tmp/ow-mount
  g_mounted="yes"
  if grep -q "console=${f_serial}" /tmp/ow-mount/EFI/openwrt/grub.cfg
  then
    echo "GRUB already patched"
  else
    sed -i "s/console=tty1/console=${f_serial},115200n8/g" \
      /tmp/ow-mount/EFI/openwrt/grub.cfg
    echo "GRUB patched"
  fi
  cat /tmp/ow-mount/EFI/openwrt/grub.cfg
  umount /tmp/ow-mount
  g_mounted=""

  # --- Patch root filesystem (p2): first-boot scripts + credentials ---
  mkdir -p /tmp/ow-mount
  mount "${f_loop}p2" /tmp/ow-mount
  g_mounted="yes"

  # Inject the first-boot scripts (98 network, 99 preconfig, postconfig
  # hotplug trigger + main script). Always overwrite so a previously
  # baked raw image gets the current templates (no stale first-boot
  # config from an older build).
  for f_pair in \
    98-openwrt-network:/tmp/ow-uci-network \
    99-openwrt-preconfig:/tmp/ow-uci-preconfig
  do
    f_name="${f_pair%%:*}"
    f_src="${f_pair#*:}"
    mkdir -p /tmp/ow-mount/etc/uci-defaults
    cp "${f_src}" "/tmp/ow-mount/etc/uci-defaults/${f_name}"
    chmod 755 "/tmp/ow-mount/etc/uci-defaults/${f_name}"
    echo "uci-defaults injected: ${f_name}"
  done
  mkdir -p /tmp/ow-mount/etc/hotplug.d/iface
  cp /tmp/ow-postconfig-trigger /tmp/ow-mount/etc/hotplug.d/iface/80-openwrt-postconfig
  chmod 644 /tmp/ow-mount/etc/hotplug.d/iface/80-openwrt-postconfig
  echo "postconfig trigger injected"
  cp /tmp/ow-postconfig /tmp/ow-mount/etc/openwrt-postconfig.sh
  chmod 755 /tmp/ow-mount/etc/openwrt-postconfig.sh
  echo "openwrt-postconfig.sh injected"

  # Set root password in /etc/shadow (pre-computed SHA-512 hash).
  # Applied unconditionally so a re-baked image always matches the env
  # file even if a previous bake already hashed a different password.
  # Full 9-field shadow line required by shadow-utils/login:
  # login:passwd:lastchg:min:max:warn:inactive:expire:flag
  # The default factory line is root::0:0:99999:7::: so we must keep
  # the extra min-age field (0) or LuCI/auth cannot parse the entry.
  sed -i '1s|^root:.*|root:'"${OWRT_ROOT_PW_HASH}"':0:0:99999:7:::|' \
    /tmp/ow-mount/etc/shadow
  echo "root password set"

  # Deploy host SSH public key (idempotent overwrite)
  mkdir -p /tmp/ow-mount/etc/dropbear
  cat "${f_pubkey}" > /tmp/ow-mount/etc/dropbear/authorized_keys
  chmod 600 /tmp/ow-mount/etc/dropbear/authorized_keys
  echo "SSH key deployed"

  umount /tmp/ow-mount
  g_mounted=""
  rmdir /tmp/ow-mount || true

  # Detach loop device
  losetup -d "${f_loop}"
  g_loop=""
  trap - EXIT
  echo "image-patched"
}

function f_owrt_define {
  local f_root="" f_ram="" f_vcpus="" f_arch="" f_machine="" f_uefi="" f_cpu=""
  while [[ $# -gt 0 ]]
  do
    case "${1}" in
      --root) f_root="${2}"; shift 2;;
      --ram) f_ram="${2}"; shift 2;;
      --vcpus) f_vcpus="${2}"; shift 2;;
      --arch) f_arch="${2}"; shift 2;;
      --machine) f_machine="${2}"; shift 2;;
      --uefi) f_uefi="${2}"; shift 2;;
      --cpu) f_cpu="${2}"; shift 2;;
      *) g_echo_error "unknown option: ${1}"; return 1;;
    esac
  done
  if [[ -z "${f_root}" || -z "${f_ram}" || -z "${f_vcpus}" || -z "${f_arch}" || -z "${f_machine}" || -z "${f_uefi}" || -z "${f_cpu}" ]]
  then
    g_echo_error "define needs --root/--ram/--vcpus/--arch/--machine/--uefi/--cpu"
    return 1
  fi
  local f_acpi=""
  if [[ "${f_arch}" == "aarch64" ]]
  then
    f_acpi="<acpi state='off'/>"
  fi
  cat > /tmp/openwrt-vm.xml << XMLEOF
<domain type='kvm'>
  <name>openwrt</name>
  <memory unit='MiB'>${f_ram}</memory>
  <vcpu>${f_vcpus}</vcpu>
  <os>
    <type arch='${f_arch}' machine='${f_machine}'>hvm</type>
    <loader readonly='yes' type='pflash'>${f_uefi}</loader>
    <nvram>${f_root}/ovmf/OVMF_VARS.fd</nvram>
  </os>
  <features>
    ${f_acpi}
  </features>
  <cpu mode='${f_cpu}'/>
  <clock offset='utc'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='${f_root}/images/openwrt.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='base-services'/>
      <model type='virtio'/>
      <rom bar='off'/>
    </interface>
    <interface type='bridge'>
      <source bridge='openwrt-lan'/>
      <model type='virtio'/>
      <rom bar='off'/>
    </interface>
    <interface type='bridge'>
      <source bridge='openwrt-iot'/>
      <model type='virtio'/>
      <rom bar='off'/>
    </interface>
    <interface type='bridge'>
      <source bridge='openwrt-tor'/>
      <model type='virtio'/>
      <rom bar='off'/>
    </interface>
    <interface type='bridge'>
      <source bridge='openwrt-misc'/>
      <model type='virtio'/>
      <rom bar='off'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
  </devices>
</domain>
XMLEOF
  virsh define /tmp/openwrt-vm.xml
  rm -f /tmp/openwrt-vm.xml
  echo "vm-defined"
}

# Main: dispatch subcommand
f_cmd="${1:-}"
shift || true
case "${f_cmd}" in
  patch)
    f_owrt_patch "$@"
    ;;
  define)
    f_owrt_define "$@"
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
