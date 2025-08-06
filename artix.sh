#!/bin/bash
# artix-labwc-install.sh  – minimal Artix + labwc/foot/yambar
# Run as root from the Artix live ISO.

set -euo pipefail

########################################
# 0.  Basic variables – EDIT THESE
########################################
DISK=/dev/sda                # install target disk
ROOT_PART=${DISK}2           # adjust to your layout
EFI_PART=${DISK}1            # UEFI only
HOSTNAME=artixbox
USERNAME=artix
USERPASS=artix
INIT=runit                   # or openrc / s6 / dinit
TIMEZONE=Europe/Berlin
KEYMAP=us

########################################
# 1.  Partitioning (simple UEFI example)
########################################
# If you want to keep existing partitions or use BIOS/LUKS, skip this block
wipefs -a "$DISK"
parted "$DISK" --script \
  mklabel gpt \
  mkpart ESP fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart ROOT ext4 512MiB 100%

mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -L ROOT "$ROOT_PART"

########################################
# 2.  Mount & bootstrap base
########################################
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART"  /mnt/boot/efi

basestrap /mnt \
  base base-devel linux linux-firmware "$INIT" elogind-"$INIT" \
  vim efibootmgr grub

fstabgen -U /mnt >> /mnt/etc/fstab

########################################
# 3.  Chroot configuration
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
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# enable basic services
case "$INIT" in
  runit)
    ln -s /etc/runit/sv/NetworkManager /run/runit/service/
    ln -s /etc/runit/sv/elogind        /run/runit/service/
    ;;
  openrc)
    rc-update add NetworkManager default
    rc-update add elogind        default
    ;;
  s6)
    s6-rc-bundle-update add default NetworkManager elogind
    ;;
esac
EOF

########################################
# 4.  Install graphics stack & apps
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

# seatd service
case "$INIT" in
  runit) ln -s /etc/runit/sv/seatd /run/runit/service/ ;;
  openrc) rc-update add seatd default ;;
  s6)     s6-rc-bundle-update add default seatd ;;
esac
EOF

########################################
# 5.  Minimal dotfiles skeleton
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
# 6.  Finish
########################################
umount -R /mnt
echo
echo "Installation complete. Remove media and reboot."
