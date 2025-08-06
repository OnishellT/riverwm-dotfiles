#!/bin/bash
# artix-labwc-guide.sh  – minimal Artix + labwc/foot/yambar
set -euo pipefail

###############################
# 0.  USER-EDITABLE VARS
###############################
HOSTNAME=artixbox
USERNAME=artix
USERPASS=artix
INIT=runit
TIMEZONE=Europe/Berlin
KEYMAP=us

###############################
# 0-a. DISK & FIRMWARE PICKER
###############################
lsblk -p -n -o NAME,SIZE,TYPE | grep disk
read -rp "Target disk (e.g. /dev/sda): " DISK
[[ -b $DISK ]] || { echo "Bad disk"; exit 1; }

echo "1) UEFI   2) BIOS"
read -rp "Firmware type (1/2): " FW_TYPE
case $FW_TYPE in
  1) FW_TYPE=UEFI ;;
  2) FW_TYPE=BIOS ;;
  *) echo "Bad choice"; exit 1 ;;
esac

###############################
# 0-b. PARTITIONING
###############################
echo "1) Auto-partition whole disk   2) Use existing partitions"
read -rp "Choose (1/2): " MODE
case $MODE in
  1)
    read -rp "DESTROYS DATA. Type 'yes' to proceed: " CONFIRM
    [[ $CONFIRM == "yes" ]] || exit 1
    wipefs -a "$DISK"
    if [[ $FW_TYPE == UEFI ]]; then
      parted "$DISK" --script \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB set 1 esp on \
        mkpart ROOT ext4 513MiB 100%
      EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"
      mkfs.fat -F32 "$EFI_PART"
    else
      parted "$DISK" --script \
        mklabel msdos \
        mkpart primary ext4 1MiB 100% set 1 boot on
      EFI_PART=""; ROOT_PART="${DISK}1"
    fi
    mkfs.ext4 -L ROOT "$ROOT_PART"
    ;;
  2)
    lsblk -p -n -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v loop
    read -rp "Root partition: " ROOT_PART
    [[ -b $ROOT_PART ]] || { echo "Bad root"; exit 1; }
    if [[ $FW_TYPE == UEFI ]]; then
      read -rp "EFI partition: " EFI_PART
      [[ -b $EFI_PART ]] || { echo "Bad EFI"; exit 1; }
    else
      EFI_PART=""
    fi
    ;;
  *) echo "Bad choice"; exit 1 ;;
esac

###############################
# 1.  BASE INSTALL
###############################
mount "$ROOT_PART" /mnt
[[ $FW_TYPE == UEFI ]] && { mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi; }

basestrap /mnt \
  base base-devel linux linux-firmware "$INIT" elogind-"$INIT" \
  vim efibootmgr grub

fstabgen -U /mnt >> /mnt/etc/fstab

###############################
# 2.  CHROOT CONFIGURATION
###############################
artix-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail

# export once, use everywhere
export HOSTNAME=$HOSTNAME USERNAME=$USERNAME USERPASS=$USERPASS \
       TIMEZONE=$TIMEZONE KEYMAP=$KEYMAP INIT=$INIT FW_TYPE=$FW_TYPE DISK=$DISK

# basic system
echo "$HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# users
echo "root:$USERPASS" | chpasswd
useradd -m -G wheel,video,input "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# bootloader
if [[ $FW_TYPE == UEFI ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
               --bootloader-id=GRUB --removable
else
  grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# ---------- repositories ----------
cat > /etc/pacman.conf <<'PAC'
# Artix (first)
[system]
Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist

[lib32]
Include = /etc/pacman.d/mirrorlist

# Arch (after)
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
PAC

curl -fsSL https://raw.githubusercontent.com/artix-linux/mirrorlist/master/mirrorlist   \
  -o /etc/pacman.d/mirrorlist || \
  cat > /etc/pacman.d/mirrorlist <<'FALLBACK'
Server = https://mirrors.dotsrc.org/artix-linux/repos/  $repo/os/$arch
Server = https://mirror.accum.se/mirror/artix-linux/repos/  $repo/os/$arch
Server = https://mirrors.atlas.net.co/artix-linux/repos/  $repo/os/$arch
FALLBACK

curl -fsSL https://archlinux.org/mirrorlist/all/   \
  | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist-arch

pacman-key --init
pacman-key --populate archlinux artix

# ---------- packages ----------
pacman -Syu --needed --noconfirm \
  mesa wlroots0.18 seatd xorg-xwayland \
  labwc foot yambar swaybg wofi \
  firefox dmenu grim slurp brightnessctl

# ---------- services ----------
case "$INIT" in
  runit)
    ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/
    ln -s /etc/runit/sv/elogind /etc/runit/runsvdir/default/
    ln -s /etc/runit/sv/seatd /etc/runit/runsvdir/default/
    ;;
  openrc)
    rc-update add NetworkManager default
    rc-update add elogind default
    rc-update add seatd default
    ;;
  *)
    echo "Manual service setup required for $INIT"
    ;;
esac
CHROOT_EOF

###############################
# 3.  DOTFILES
###############################
artix-chroot /mnt /bin/bash <<'DOTFILES_EOF'
cd "/home/$USERNAME"
mkdir -p .config/{labwc,foot,yambar}

cat > .config/labwc/rc.xml <<'EOF'
<labwc_config>
  <keyboard>
    <default />
    <keybind key="A-d"><action name="Execute" command="wofi --show drun" /></keybind>
    <keybind key="A-Return"><action name="Execute" command="foot" /></keybind>
    <keybind key="A-Shift-q"><action name="Close" /></keybind>
  </keyboard>
</labwc_config>
EOF

cat > .config/foot/foot.ini <<'EOF'
[main]
font=JetBrainsMono Nerd Font:size=10
EOF

cat > .config/yambar/config.yml <<'EOF'
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
EOF

chown -R "$USERNAME:$USERNAME" .config
DOTFILES_EOF

###############################
# 4.  DONE
###############################
umount -R /mnt
echo
echo "Installation complete. Remove media and reboot."
