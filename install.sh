#!/bin/bash
# RiverWM Dotfiles Installer for Artix Linux with runit
set -e

show_warning() {
    echo "WARNING: This script will overwrite existing configuration files."
    echo "Please back up your current dotfiles before proceeding."
    read -p "Continue? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

install_dependencies() {
    echo "Installing pacman dependencies..."
    sudo pacman -S --needed --noconfirm \
        river swaybg jq findutils waybar mpd ncmpcpp swayidle \
        wf-recorder dmenu brightnessctl mako cliphist grim slurp \
        pamixer polkit starship xdg-user-dirs xdg-utils \
        gvfs gvfs-mtp gvfs-nfs wl-clipboard playerctl foot \
        networkmanager network-manager-applet wpa_supplicant \
        grimshot seatd connman \
        pipewire pipewire-pulse pipewire-alsa wireplumber \
        bluez bluez-utils noto-fonts noto-fonts-cjk noto-fonts-emoji \
        dbus-runit elogind-runit seatd-runit connman-runit pipewire-runit \
        bluez-runit

    echo "Installing AUR dependencies..."
    # Install paru if not present
    if ! command -v paru >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm base-devel
        git clone https://aur.archlinux.org/paru.git /tmp/paru
        (cd /tmp/paru && makepkg -si --noconfirm)
    fi

    paru -S --needed --noconfirm \
        tela-circle-icon-theme-manjaro tokyonight-gtk-theme-git \
        wl-clipboard-history-git ttf-jetbrains-mono-nerd mpdris2 \
        rofi-lbonn-wayland swaylock-effects nwg-look rivercarro
}

install_zap_zsh() {
    echo "Installing Zap ZSH..."
    if ! command -v zsh >/dev/null 2>&1; then
        sudo pacman -S --noconfirm zsh
    fi
    # Run as current user
    sudo -u $USER zsh -c "$(curl -s https://raw.githubusercontent.com/zap-zsh/zap/master/install.zsh)" -- --branch release-v1
}

copy_config_files() {
    echo "Copying configuration files..."
    cp -vr .config/* ~/.config/
    cp -vr home/* ~/
    
    # Fix paths in river config
    sed -i "s|/usr/bin/|/bin/|g" ~/.config/river/init
}

setup_services() {
    echo "Configuring runit services..."
    
    # Enable seatd
    sudo ln -s /etc/runit/sv/seatd /run/runit/service/
    sudo usermod -aG seat $USER
    
    # Enable essential services
    sudo ln -s /etc/runit/sv/dbus /run/runit/service/
    sudo ln -s /etc/runit/sv/elogind /run/runit/service/
    sudo ln -s /etc/runit/sv/connmand /run/runit/service/
    sudo ln -s /etc/runit/sv/NetworkManager /run/runit/service/
    sudo ln -s /etc/runit/sv/bluetoothd /run/runit/service/
    sudo ln -s /etc/runit/sv/pipewire /run/runit/service/
    
    # Configure bluetooth
    sudo sed -i 's|#AutoEnable=false|AutoEnable=true|' /etc/bluetooth/main.conf
    
    echo "Services configured. Some changes require a logout/reboot to take effect."
}

configure_pipewire() {
    echo "Configuring PipeWire..."
    # Create pipewire config directory
    mkdir -p ~/.config/pipewire
    cp /usr/share/pipewire/*.conf ~/.config/pipewire/
    
    # Enable real-time processing
    echo "@audio - rtprio 99" | sudo tee -a /etc/security/limits.conf
    echo "@audio - memlock unlimited" | sudo tee -a /etc/security/limits.conf
    sudo usermod -aG audio $USER
}

setup_elogind() {
    echo "Configuring elogind..."
    # Add necessary elogind rules
    echo -e 'polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.login1.suspend" ||
        action.id == "org.freedesktop.login1.hibernate") {
        return subject.isInGroup("power") ? polkit.Result.YES : polkit.Result.NO;
    }
});' | sudo tee /etc/polkit-1/rules.d/10-enable-suspend.rules
}

main() {
    show_warning
    
    # Install dependencies
    install_dependencies
    
    # Install Zap ZSH
    install_zap_zsh
    
    # Copy config files
    copy_config_files
    
    # Configure services
    setup_services
    
    # Configure pipewire
    configure_pipewire
    
    # Setup elogind rules
    setup_elogind
    
    echo "Installation complete!"
    echo "Important: You must REBOOT for all changes to take effect."
    echo "After reboot, launch river with: seatd-launch river"
}

main
