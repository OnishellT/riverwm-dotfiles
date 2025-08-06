#!/bin/bash
# artix-labwc-install.sh
# Minimal Artix + labwc/foot/yambar with interactive disk picker
#   – supports BOTH UEFI and BIOS (Legacy) firmware
#   – enables services inside the installed system
# Run as root in the Artix live ISO.

set -euo pipefail

########################################
# 0.  Basic variables
########################################
HOSTNAME=artixbox
USERNAME=artix
USERPASS=artix
INIT=runit                   # runit | openrc | s6 | dinit
TIMEZONE=Europe/Berlin
KEYMAP=us

########################################
# 0-a. Interactive disk picker
########################################
echo
echo "=== Available block devices ==="
lsblk -p -n -o NAME,SIZE,TYPE | grep disk
echo
read -rp "Enter the full path of the target disk (e.g. /dev/sda): " DISK
[[ -b $DISK ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }

########################################
# 0-b. Firmware type (UEFI vs BIOS)
########################################
echo
echo "1) UEFI firmware  (needs ESP partition)"
echo "2) BIOS / Legacy firmware"
read -rp "Choose firmware type (1/2): " FW_TYPE
case $FW_TYPE in
  1) FW_TYPE=UEFI ;;
  2) FW_TYPE=BIOS ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

########################################
# 0-c. Partitioning
########################################
echo
echo "1) Auto-partition the entire disk"
echo "2) Use existing partitions"
read -rp "Choose (1/2): " MODE
case $MODE in
  1)
    read -rp "This will DESTROY all data on $DISK. Type 'yes' to proceed: " CONFIRM
    [[ $CONFIRM == "yes" ]] || { echo "Aborted."; exit 1; }
    wipefs -a "$DISK"
    if [[ $FW_TYPE == UEFI ]]; then
      parted "$DISK" --script \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart ROOT ext4 513MiB 100%
      EFI_PART="${DISK}1"
      ROOT_PART="${DISK}2"
      mkfs.fat -F32 "$EFI_PART"
    else
      parted "$DISK" --script \
        mklabel msdos \
        mkpart primary ext4 1MiB 100% \
        set 1 boot on
      ROOT_PART="${DISK}1"
      EFI_PART=""
    fi
    mkfs.ext4 -L ROOT "$ROOT_PART"
    ;;
  2)
    echo
    lsblk -p -n -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v loop
    read -rp "Enter root partition (e.g. ${DISK}1): " ROOT_PART
    [[ -b $ROOT_PART ]] || { echo "Invalid root partition"; exit 1; }
    if [[ $FW_TYPE == UEFI ]]; then
      read -rp "Enter EFI partition (e.g. ${DISK}1): " EFI_PART
      [[ -b $EFI_PART ]] || { echo "Invalid EFI partition"; exit 1; }
    else
      EFI_PART=""
    fi
    ;;
  *)
    echo "Invalid choice"; exit 1 ;;
esac

########################################
# 1.  Mount & bootstrap base
########################################
mount "$ROOT_PART" /mnt
if [[ $FW_TYPE == UEFI ]]; then
  mkdir -p /mnt/boot/efi
  mount "$EFI_PART" /mnt/boot/efi
fi

basestrap /mnt \
  base base-devel linux linux-firmware "$INIT" elogind-"$INIT" \
  vim efibootmgr grub

fstabgen -U /mnt >> /mnt/etc/fstab

########################################
# 2.  Chroot configuration
########################################
artix-chroot /mnt /bin/bash <<EOF
set -euo pipefail
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP"  > /etc/vconsole.conf

# root password
echo "root:$USERPASS" | chpasswd

# new user + sudo
useradd -m -G wheel,video,input "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# bootloader
if [[ $FW_TYPE == UEFI ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
else
  grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# enable services inside the installed system
case "$INIT" in
  runit)
    ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/
    ln -s /etc/runit/sv/elogind        /etc/runit/runsvdir/default/
    ln -s /etc/runit/sv/seatd          /etc/runit/runsvdir/default/
    ;;
  openrc)
    rc-update add NetworkManager default
    rc-update add elogind default
    rc-update add seatd default
    ;;
  s6|dinit)
    echo "FIXME: add s6/dinit service enablement"
    ;;
esac
EOF

########################################
# 3.  Install graphics stack & apps
########################################
artix-chroot /mnt /bin/bash <<EOF
set -euo pipefail
# Mesa + wayland
pacman -S --needed --noconfirm \
  mesa wlroots seatd xorg-xwayland

# compositor, terminal, panel
pacman -S --needed --noconfirm \
  labwc foot yambar swaybg wofi

# extra helpers
pacman -S --needed --noconfirm \
  firefox dmenu grim slurp brightnessctl

# enable seatd service (already done in step 2 for runit/openrc)
EOF

########################################
# 4.  Minimal dotfiles skeleton
########################################
artix-chroot /mnt /bin/bash <<EOF
set -euo pipefail
cd /home/$USERNAME
sudo -u $USERNAME mkdir -p .config/{labwc,foot,yambar}

# labwc rc
sudo -u $USERNAME tee .config/labwc/rc.xml >/dev/null <<'LABWC'
<labwc_config>
  <keyboard>
    <default />
    <keybind key="A-d"><action name="Execute" command="wofi --show drun" /></keybind>
    <keybind key="A-Return"><action name="Execute" command="foot" /></keybind>
    <keybind key="A-Shift-q"><action name="Close" /></keybind>
  </keyboard>
</labwc_config>
LABWC

# foot.ini
sudo -u $USERNAME tee .config/foot/foot.ini >/dev/null <<'FOOT'
[main]
font=JetBrainsMono Nerd Font:size=10
FOOT

# yambar.yml
sudo -u $USERNAME tee .config/yambar/config.yml >/dev/null <<'YAMBAR'
bar:
  height: 24
  background: '#1e1e2e'
  foreground: '#cdd6f4'
  modules:
    left:
      - label:
          content: "labwc"
    right:
      - clock:
          format: "%H:%M"
YAMBAR

chown -R $USERNAME:$USERNAME .config
EOF

########################################
# 5.  Finish
########################################
umount -R /mnt
echo
echo "Installation complete. Remove media and reboot."
