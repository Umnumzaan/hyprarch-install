#!/bin/bash
# HyprArch Configuration Script
# Configures a base HyprArch installation with Hyprland, Plymouth, and essential applications
#
# This script configures a base Arch system installed with hyprarch-install.sh:
# - Installs yay (AUR helper)
# - Configures zram swap
# - Installs all essential packages
# - Configures snapper for snapshots
# - Sets up Plymouth boot splash
# - Creates minimal Hyprland configuration
# - Configures auto-login and UWSM
#
# Prerequisites:
# - Base system installed with hyprarch-install.sh
# - Network connection active
# - Run as normal user (not root)
#
# Usage: bash hyprarch-config.sh

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory (where plymouth-theme folder is)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
print_step() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}==>${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
    exit 1
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if running as root
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "This script should NOT be run as root. Run as normal user."
    fi
}

# Check network connection
check_network() {
    print_step "Checking network connection..."
    if ping -c 1 archlinux.org &> /dev/null; then
        print_success "Network connection established"
        return 0
    else
        print_error "No network connection. Please configure network and try again."
    fi
}

# Check if base install was done
check_base_install() {
    print_step "Checking base installation..."

    if [ ! -f /boot/limine.conf ]; then
        print_error "Limine not found. Please run hyprarch-install.sh first."
    fi

    if ! systemctl is-enabled NetworkManager &> /dev/null; then
        print_error "NetworkManager not enabled. Please run hyprarch-install.sh first."
    fi

    print_success "Base installation detected"
}

# Update system and check for kernel update
update_system() {
    print_step "Updating system..."
    print_info "This may take several minutes..."

    sudo pacman -Syu --noconfirm

    print_success "System updated"

    # Check if kernel was updated
    if [ ! -d "/lib/modules/$(uname -r)" ]; then
        print_warning "Kernel was updated. Reboot required before continuing."
        echo
        read -r -p "$(echo -e "${YELLOW}Reboot now? [Y/n]:${NC} ")" do_reboot

        if [[ ! "$do_reboot" =~ ^[Nn]$ ]]; then
            print_info "Rebooting in 3 seconds..."
            print_info "After reboot, run this script again to continue configuration."
            sleep 3
            sudo reboot
        else
            print_error "Cannot continue without reboot. Please reboot and run script again."
        fi
    fi
}

# Install yay AUR helper
install_yay() {
    print_step "Installing yay AUR helper..."

    if command -v yay &> /dev/null; then
        print_success "yay already installed"
        return 0
    fi

    # Ensure base-devel is installed
    sudo pacman -S --needed --noconfirm base-devel git

    # Clone and build yay
    cd /tmp
    rm -rf yay 2>/dev/null || true
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay

    print_success "yay installed"
}

# Configure zram swap
configure_zram() {
    print_step "Configuring zram swap..."

    # Install zram-generator
    sudo pacman -S --needed --noconfirm zram-generator

    # Create config
    sudo tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = ram / 4
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    # Start zram
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service

    # Verify
    if swapon --show | grep -q zram0; then
        print_success "zram configured successfully"
        swapon --show | grep zram0
    else
        print_warning "zram setup completed but not showing in swapon"
    fi
}

# Install provider dependencies first to avoid prompts
install_providers() {
    print_step "Installing provider dependencies..."

    sudo pacman -S --needed --noconfirm pipewire-jack noto-fonts jre-openjdk

    print_success "Provider dependencies installed"
}

# Install packages from official repos
install_official_packages() {
    print_step "Installing official repository packages..."
    print_info "This will take several minutes..."

    local packages=(
        # Core Wayland/Hyprland
        hyprland uwsm xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
        qt5-wayland qt6-wayland xorg-xwayland hypridle hyprlock hyprpolkitagent

        # Screenshots and clipboard
        grim slurp wl-clipboard

        # Notifications and OSD
        mako swayosd

        # System utilities
        neovim zoxide fzf bat btop htop

        # GUI applications
        nautilus imv evince nwg-look

        # Bluetooth
        bluez bluez-utils

        # Snapshots
        snapper snap-pac

        # Plymouth
        plymouth
    )

    sudo pacman -S --needed --noconfirm "${packages[@]}"

    print_success "Official packages installed"
}

# Install GPU drivers
install_gpu_drivers() {
    local gpu_type="$1"

    print_step "Installing GPU drivers..."

    case $gpu_type in
        amd)
            print_info "Installing AMD drivers..."
            sudo pacman -S --needed --noconfirm mesa vulkan-radeon libva-mesa-driver mesa-vdpau
            ;;
        nvidia)
            print_info "Installing NVIDIA drivers..."
            sudo pacman -S --needed --noconfirm nvidia nvidia-utils nvidia-settings
            ;;
        intel)
            print_info "Installing Intel drivers..."
            sudo pacman -S --needed --noconfirm mesa vulkan-intel libva-intel-driver
            ;;
        none)
            print_info "Skipping GPU drivers..."
            ;;
    esac

    print_success "GPU drivers installed"
}

# Install Bluetooth
install_bluetooth() {
    print_step "Installing Bluetooth..."

    sudo pacman -S --needed --noconfirm blueberry

    # Enable bluetooth service
    sudo systemctl enable bluetooth.service
    sudo systemctl start bluetooth.service

    print_success "Bluetooth configured"
}

# Install AUR packages
install_aur_packages() {
    print_step "Installing AUR packages..."
    print_info "This will take several minutes..."

    local packages=(
        satty
        wiremix
        walker-bin
        elephant
        elephant-calc
        elephant-clipboard
        elephant-desktopapplications
        elephant-files
        elephant-menus
        elephant-providerlist
        elephant-runner
        elephant-symbols
        elephant-websearch
        limine-snapper-sync
        brave-bin
        ghostty
    )

    yay -S --needed --noconfirm "${packages[@]}"

    print_success "AUR packages installed"
}

# Configure snapper
configure_snapper() {
    print_step "Configuring snapper..."

    # Temporarily disable limine-snapper-sync plugin
    if [ -f /usr/lib/snapper/plugins/10-limine-snapper-sync ]; then
        print_info "Temporarily disabling limine-snapper-sync plugin..."
        sudo mv /usr/lib/snapper/plugins/10-limine-snapper-sync /usr/lib/snapper/plugins/10-limine-snapper-sync.disabled
    fi

    # Create snapper configs
    print_info "Creating snapper configs..."
    sudo snapper -c root create-config /
    sudo snapper -c home create-config /home

    # Re-enable limine-snapper-sync plugin
    if [ -f /usr/lib/snapper/plugins/10-limine-snapper-sync.disabled ]; then
        print_info "Re-enabling limine-snapper-sync plugin..."
        sudo mv /usr/lib/snapper/plugins/10-limine-snapper-sync.disabled /usr/lib/snapper/plugins/10-limine-snapper-sync
    fi

    # Configure root
    sudo sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root

    # Configure home
    sudo sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/home
    sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/home
    sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/home
    sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/home
    sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/home
    sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/home

    # Enable timers
    sudo systemctl enable --now snapper-timeline.timer
    sudo systemctl enable --now snapper-cleanup.timer

    print_success "Snapper configured"
}

# Configure Plymouth
configure_plymouth() {
    print_step "Configuring Plymouth boot splash..."

    # Check if plymouth-theme directory exists
    if [ ! -d "$SCRIPT_DIR/plymouth-theme" ]; then
        print_error "plymouth-theme directory not found in $SCRIPT_DIR"
    fi

    # Copy theme
    print_info "Installing Plymouth theme..."
    sudo cp -r "$SCRIPT_DIR/plymouth-theme" /usr/share/plymouth/themes/hyprarch

    # Set as default (regenerates initramfs)
    print_info "Setting default theme and regenerating initramfs..."
    sudo plymouth-set-default-theme -R hyprarch

    # Add plymouth to mkinitcpio HOOKS (before encrypt)
    print_info "Updating mkinitcpio configuration..."
    sudo sed -i 's/^\(HOOKS=.*\)block encrypt/\1plymouth block encrypt/' /etc/mkinitcpio.conf

    # Add quiet splash to kernel parameters
    print_info "Updating bootloader configuration..."
    sudo sed -i 's/^\(    kernel_cmdline: cryptdevice\)/    kernel_cmdline: quiet splash cryptdevice/' /boot/limine.conf

    # Regenerate initramfs
    print_info "Regenerating initramfs..."
    sudo mkinitcpio -P

    print_success "Plymouth configured"
}

# Create minimal Hyprland configuration
create_hyprland_config() {
    print_step "Creating minimal Hyprland configuration..."

    mkdir -p ~/.config/hypr

    cat > ~/.config/hypr/hyprland.conf << 'EOF'
# Minimal HyprArch config - launch terminal on startup and with keybind
exec-once = ghostty

# Keybindings
bind = SUPER, RETURN, exec, ghostty
bind = SUPER, Q, killactive
bind = SUPER, M, exit

# Input
input {
    kb_layout = us
}
EOF

    print_success "Hyprland config created"
}

# Configure auto-login
configure_autologin() {
    print_step "Configuring auto-login..."

    # Create systemd override directory
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/

    # Create auto-login override
    sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin $USER %I \$TERM
EOF

    print_success "Auto-login configured"
}

# Configure UWSM launch
configure_uwsm() {
    print_step "Configuring UWSM Hyprland launch..."

    # Add to .bash_profile
    if ! grep -q "uwsm start hyprland.desktop" ~/.bash_profile 2>/dev/null; then
        cat >> ~/.bash_profile << 'EOF'

# Launch Hyprland on TTY1
if [ -z "$DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
  exec uwsm start hyprland.desktop
fi
EOF
        print_success "UWSM launch configured in .bash_profile"
    else
        print_success "UWSM already configured in .bash_profile"
    fi
}

# Cleanup script directory
cleanup_script_dir() {
    print_step "Cleaning up installation files..."

    # Get parent directory (the repo clone directory)
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"

    # Only delete if this looks like a temporary clone
    if [[ "$PARENT_DIR" == "/tmp"* ]] || [[ "$PARENT_DIR" == *"hyprarch"* ]]; then
        print_info "Removing $PARENT_DIR..."
        rm -rf "$PARENT_DIR"
        print_success "Cleanup complete"
    else
        print_info "Script directory appears to be a persistent location, skipping cleanup"
        print_info "Location: $SCRIPT_DIR"
    fi
}

# Main configuration function
main() {
    clear
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                   ║${NC}"
    echo -e "${GREEN}║      HyprArch Configuration Script                ║${NC}"
    echo -e "${GREEN}║                                                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}\n"

    # Pre-configuration checks
    check_not_root
    check_network
    check_base_install

    # Get user input
    print_step "Configuration options..."
    echo

    echo -e "${CYAN}Select GPU type:${NC}"
    echo "  1) AMD"
    echo "  2) NVIDIA"
    echo "  3) Intel"
    echo "  4) None (VM/Other)"
    read -r -p "$(echo -e "${CYAN}Enter choice [1-4]:${NC} ")" gpu_choice

    case $gpu_choice in
        1) GPU_TYPE="amd" ;;
        2) GPU_TYPE="nvidia" ;;
        3) GPU_TYPE="intel" ;;
        4) GPU_TYPE="none" ;;
        *) print_error "Invalid choice" ;;
    esac

    # Summary
    echo
    print_step "Configuration Summary:"
    echo -e "  ${CYAN}GPU Type:${NC} $GPU_TYPE"
    echo

    read -r -p "$(echo -e "${YELLOW}Proceed with configuration? [Y/n]:${NC} ")" confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_error "Configuration cancelled by user"
    fi

    echo
    print_info "Starting configuration... This will take 10-15 minutes."
    print_info "Some steps may take a while without visible progress."
    echo

    # Configuration steps
    update_system
    install_yay
    configure_zram
    install_providers
    install_official_packages
    install_gpu_drivers "$GPU_TYPE"
    install_bluetooth
    install_aur_packages
    configure_snapper
    configure_plymouth
    create_hyprland_config
    configure_autologin
    configure_uwsm

    # Success message
    echo
    print_success "Configuration completed successfully!"
    echo
    print_info "Your system is now configured with:"
    print_info "  ✓ Hyprland window manager with UWSM"
    print_info "  ✓ Plymouth boot splash"
    print_info "  ✓ Snapper snapshots"
    print_info "  ✓ Essential applications"
    print_info "  ✓ Auto-login to Hyprland"
    echo
    print_info "Boot flow:"
    print_info "  1. Plymouth LUKS password (graphical)"
    print_info "  2. Auto-login to TTY1"
    print_info "  3. Hyprland launches automatically"
    print_info "  4. Ghostty terminal opens"
    echo
    print_info "Next steps:"
    print_info "  1. Reboot to test the full setup"
    print_info "  2. In Hyprland, open Brave browser"
    print_info "  3. Set up SSH keys and add to GitHub"
    print_info "  4. Clone your private dotfiles repo"
    print_info "  5. Use stow to deploy your full configurations"
    echo

    # Cleanup
    cleanup_script_dir

    # Prompt for reboot
    read -r -p "$(echo -e "${YELLOW}Reboot now to test the setup? [Y/n]:${NC} ")" do_reboot

    if [[ ! "$do_reboot" =~ ^[Nn]$ ]]; then
        print_info "Rebooting in 3 seconds..."
        sleep 3
        sudo reboot
    else
        print_info "Configuration complete. Reboot when ready with: sudo reboot"
    fi
}

# Run main function
main "$@"
