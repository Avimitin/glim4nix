#!/bin/bash
#
# BASH. It's what I know best, sorry.
#

# Check that we are *NOT* running as root
if [[ `id -u` -eq 0 ]]; then
  echo "ERROR: Don't run as root, use a user with full sudo access."
  exit 1
fi

resolve_command() {
  command -v "$1" 2>/dev/null
}

canonical_path() {
  if command -v realpath &>/dev/null; then
    realpath "$1"
  elif command -v readlink &>/dev/null; then
    readlink -f "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

grub_module_dir_usable() {
  local dir="$1"

  [[ -d "$dir" && -f "$dir/modinfo.sh" && -f "$dir/normal.mod" ]]
}

grub_install_default_module_dir() {
  LC_ALL=C "$GRUB2_INSTALL" --help 2>/dev/null | awk '
    /--directory=DIR/ { looking = 1 }
    looking && index($0, "[default=") {
      sub(/^.*\[default=/, "")
      sub(/\].*$/, "")
      print
      exit
    }
  '
}

grub_module_dir_override_var() {
  case "$1" in
    i386-pc)
      echo "GLIM_GRUB_I386_PC_DIR"
      ;;
    x86_64-efi)
      echo "GLIM_GRUB_X86_64_EFI_DIR"
      ;;
  esac
}

find_grub_module_dir() {
  local target="$1"
  local override_var override default_dir install_path install_prefix candidate

  override_var="$(grub_module_dir_override_var "$target")"
  if [[ -n "$override_var" && -n "${!override_var}" ]]; then
    override="${!override_var}"
    if grub_module_dir_usable "$override"; then
      echo "$override"
      return 0
    fi
    echo "WARNING: ${override_var}=${override} is not a usable GRUB2 module directory for ${target}" >&2
    return 1
  fi

  default_dir="$(grub_install_default_module_dir)"
  if [[ -n "$default_dir" ]]; then
    candidate="${default_dir//<platform>/$target}"
    if grub_module_dir_usable "$candidate"; then
      echo "$candidate"
      return 0
    fi
  fi

  install_path="$(resolve_command "$GRUB2_INSTALL")"
  if [[ -n "$install_path" ]]; then
    install_path="$(canonical_path "$install_path")"
    install_prefix="$(dirname "$(dirname "$install_path")")"
    candidate="${install_prefix}/lib/grub/${target}"
    if grub_module_dir_usable "$candidate"; then
      echo "$candidate"
      return 0
    fi
  fi

  for candidate in "/usr/lib/grub/${target}" "/usr/lib/grub2/${target}"; do
    if grub_module_dir_usable "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

run_grub_install() {
  local target="$1"
  local module_dir="$2"
  shift 2

  local cmd=(
    "$GRUB2_INSTALL"
    "--target=${target}"
    "--directory=${module_dir}"
    "--boot-directory=${USBMNT}/boot"
    "$@"
    "$USBDEV"
  )

  echo "Running sudo ${cmd[*]} ..."
  sudo "${cmd[@]}"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: ${GRUB2_INSTALL} returned with an error exit status."
    exit 1
  fi
}

# Sanity check : GRUB2
if [[ -n "$GLIM_GRUB_INSTALL" ]]; then
  if resolve_command "$GLIM_GRUB_INSTALL" &>/dev/null; then
    GRUB2_INSTALL="$GLIM_GRUB_INSTALL"
  else
    echo "ERROR: GLIM_GRUB_INSTALL command not found: ${GLIM_GRUB_INSTALL}"
    exit 1
  fi
elif resolve_command grub2-install &>/dev/null; then
  GRUB2_INSTALL="grub2-install"
elif resolve_command grub-install &>/dev/null; then
  GRUB2_INSTALL="grub-install"
fi
if [[ -z "$GRUB2_INSTALL" ]]; then
  echo "ERROR: grub2-install or grub-install commands not found."
  exit 1
fi
case "$(basename "$GRUB2_INSTALL")" in
  grub2-install)
    GRUB2_DIR="grub2"
    ;;
  *)
    GRUB2_DIR="grub"
    ;;
esac

# Sanity check : Our GRUB2 configuration
GRUB2_CONF="`dirname $0`/grub2"
if [[ ! -f ${GRUB2_CONF}/grub.cfg ]]; then
  echo "ERROR: grub2/grub.cfg to use not found."
  exit 1
fi

#
# Find GLIM device (use the first if multiple found, you've asked for trouble!)
#

# Sanity check : blkid command
if ! which blkid &>/dev/null; then
  echo "ERROR: blkid command not found."
  exit 1
fi
USBDEV1=`blkid -L GLIM | head -n 1`

# Sanity check : we found one partition to use with matching label
if [[ -z "$USBDEV1" ]]; then
  echo "ERROR: no partition found with label 'GLIM', please create one."
  exit 1
fi
echo "Found partition with label 'GLIM' : ${USBDEV1}"

# Sanity check : our partition is the first and only one on the block device
USBDEV=${USBDEV1%1}
if [[ ! -b "$USBDEV" ]]; then
  echo "ERROR: ${USBDEV} block device not found."
  exit 1
fi
echo "Found block device where to install GRUB2 : ${USBDEV}"
if [[ `ls -1 ${USBDEV}* | wc -l` -ne 2 ]]; then
  echo "ERROR: ${USBDEV1} isn't the only partition on ${USBDEV}"
  exit 1
fi

# Sanity check : our partition is mounted
if ! grep -q -w ${USBDEV1} /proc/mounts; then
  echo "ERROR: ${USBDEV1} isn't mounted"
  exit 1
fi
USBMNT=`grep -w ${USBDEV1} /proc/mounts | cut -d ' ' -f 2`
if [[ -z "$USBMNT" ]]; then
  echo "ERROR: Couldn't find mount point for ${USBDEV1}"
  exit 1
fi
echo "Found mount point for filesystem : ${USBMNT}"

BIOS=false
EFI=false

# Check BIOS support
BIOS_GRUB_DIR="$(find_grub_module_dir i386-pc)"
if [[ -n "$BIOS_GRUB_DIR" ]]; then
  BIOS=true
  echo "Found GRUB2 BIOS modules : ${BIOS_GRUB_DIR}"
else
  echo "WARNING: no usable GRUB2 i386-pc module dir. Skipping Grub BIOS support"
fi

# Check EFI support
EFI_GRUB_DIR="$(find_grub_module_dir x86_64-efi)"
if [[ -n "$EFI_GRUB_DIR" ]]; then
  EFI_AVAILABLE=true
  echo "Found GRUB2 EFI modules : ${EFI_GRUB_DIR}"
else
  EFI_AVAILABLE=false
  echo "WARNING: no usable GRUB2 x86_64-efi module dir. Skipping Grub EFI support"
fi

if [[ $BIOS == false && $EFI_AVAILABLE == false ]]; then
  echo "ERROR: neither support for BIOS or EFI was found"
  exit 1
fi

#
# EFI or regular?
#

if [[ $BIOS == true && $EFI_AVAILABLE == true ]]; then
  # Set the target
  read -n 1 -s -p "Install for EFI in addition to standard BIOS? (Y/n) " EFI
  if [[ "$EFI" == "n" ]]; then
      EFI=false
      echo "n"
  else
    EFI=true
    echo "y"
  fi
elif [[ $EFI_AVAILABLE == true ]]; then
  EFI=true
fi


#
# Get serious. If we get here, things are looking sane
#

# Sanity check : human will read the info and confirm
read -n 1 -s -p "Ready to install GLIM. Continue? (Y/n) " PROCEED
if [[ "$PROCEED" == "n" ]]; then
  echo "n"
  exit 2
else
  echo "y"
fi

# Install GRUB2
if [[ $BIOS == true ]]; then
  run_grub_install i386-pc "$BIOS_GRUB_DIR"
fi
if [[ $EFI == true ]]; then
  run_grub_install x86_64-efi "$EFI_GRUB_DIR" "--efi-directory=${USBMNT}" --removable
fi

# Check USB mount dir write permission, to use sudo if missing
if [[ -w "${USBMNT}" ]]; then
  CMD_PREFIX=""
else
  CMD_PREFIX="sudo"
fi

# Copy GRUB2 configuration
echo "Running rsync -rt --delete --exclude=i386-pc --exclude=x86_64-efi --exclude=fonts ${GRUB2_CONF}/ ${USBMNT}/boot/${GRUB2_DIR} ..."
${CMD_PREFIX} rsync -rt --delete --exclude=i386-pc --exclude=x86_64-efi --exclude=fonts ${GRUB2_CONF}/ ${USBMNT}/boot/${GRUB2_DIR}
if [[ $? -ne 0 ]]; then
  echo "ERROR: the rsync copy returned with an error exit status."
  exit 1
fi

# Be nice and pre-create the directory, and mention it
[[ -d ${USBMNT}/boot/iso ]] || ${CMD_PREFIX} mkdir ${USBMNT}/boot/iso
echo "GLIM installed! Time to populate the boot/iso/ sub-directories."

# Now also pre-create all supported sub-directories since empty are ignored
args=(
  -E -n
  '/\(distro-list-start\)/,/\(distro-list-end\)/{s,^\* \[`([a-z0-9]+)`\].*$,\1,p}'
)

for DIR in $(sed "${args[@]}" "$(dirname "$0")"/README.md); do
  [[ -d ${USBMNT}/boot/iso/${DIR} ]] || ${CMD_PREFIX} mkdir ${USBMNT}/boot/iso/${DIR}
done
