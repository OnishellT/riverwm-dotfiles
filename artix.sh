artix-chroot /mnt /bin/bash <<CHROOT_EOF
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

curl -fsSL https://raw.githubusercontent.com/artix-linux/mirrorlist/master/mirrorlist \
  -o /etc/pacman.d/mirrorlist || \
  cat > /etc/pacman.d/mirrorlist <<'FALLBACK'
Server = https://mirrors.dotsrc.org/artix-linux/repos/$repo/os/$arch
Server = https://mirror.accum.se/mirror/artix-linux/repos/$repo/os/$arch
Server = https://mirrors.atlas.net.co/artix-linux/repos/$repo/os/$arch
FALLBACK

curl -fsSL https://archlinux.org/mirrorlist/all/ \
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
