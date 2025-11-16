#!/bin/bash
# HyprArch Installation Script
# Custom Arch Linux installation with Hyprland, LUKS encryption, Btrfs, and Plymouth
#
# This script automates the installation of Arch Linux with:
# - LUKS2 full disk encryption
# - Btrfs filesystem with 7 subvolumes
# - Limine bootloader with snapshot support
# - Hyprland with UWSM session manager
# - Plymouth boot splash
#
# Usage: bash hyprarch-install.sh

set -e  # Exit on error
set -o pipefail  # Catch errors in pipes

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Prompt for user input
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"

    if [ -n "$default" ]; then
        read -r -p "$(echo -e "${CYAN}${prompt}${NC} [${default}]: ")" input
        eval "$var_name=\"${input:-$default}\""
    else
        read -r -p "$(echo -e "${CYAN}${prompt}${NC}: ")" input
        eval "$var_name=\"$input\""
    fi
}

# Prompt for password
prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local password
    local password_confirm

    while true; do
        read -r -s -p "$(echo -e "${CYAN}${prompt}${NC}: ")" password
        echo
        read -r -s -p "$(echo -e "${CYAN}Confirm password${NC}: ")" password_confirm
        echo

        if [ "$password" = "$password_confirm" ]; then
            eval "$var_name=\"$password\""
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
    fi
}

# Check if running in UEFI mode
check_uefi() {
    print_step "Checking boot mode..."
    if [ -d /sys/firmware/efi/efivars ]; then
        print_success "UEFI mode detected"
        return 0
    else
        print_error "BIOS mode detected. This script requires UEFI."
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

# Update system clock
update_clock() {
    print_step "Updating system clock..."
    timedatectl set-ntp true
    print_success "System clock synchronized"
}

# Display available disks
show_disks() {
    print_step "Available disks:"
    lsblk -d -o NAME,SIZE,TYPE | grep disk
}

# Partition disk
partition_disk() {
    local disk="$1"

    print_step "Partitioning disk $disk..."

    # Create GPT partition table and partitions
    print_info "Creating partitions..."
    (
        echo g      # Create GPT partition table
        echo n      # New partition 1 (EFI)
        echo 1
        echo        # Default start
        echo +512M
        echo t      # Change type
        echo 1      # EFI System
        echo n      # New partition 2 (root)
        echo 2
        echo        # Default start
        echo        # Default end (rest of disk)
        echo w      # Write changes
    ) | fdisk "$disk" > /dev/null 2>&1

    # Wait for partitions to be recognized
    sleep 2
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    print_success "Disk partitioned successfully"
}

# Setup LUKS encryption
setup_luks() {
    local partition="$1"
    local password="$2"

    print_step "Setting up LUKS2 encryption on $partition..."
    echo -n "$password" | cryptsetup luksFormat --type luks2 "$partition" -
    print_success "LUKS encryption created"

    print_info "Opening encrypted partition..."
    echo -n "$password" | cryptsetup open "$partition" root -
    print_success "Encrypted partition opened as /dev/mapper/root"
}

# Format filesystems
format_filesystems() {
    local efi_partition="$1"

    print_step "Formatting filesystems..."

    print_info "Formatting EFI partition..."
    mkfs.fat -F32 "$efi_partition" > /dev/null 2>&1

    print_info "Creating Btrfs filesystem..."
    mkfs.btrfs -f /dev/mapper/root > /dev/null 2>&1

    print_success "Filesystems created"
}

# Create Btrfs subvolumes
create_subvolumes() {
    print_step "Creating Btrfs subvolumes..."

    mount /dev/mapper/root /mnt

    btrfs subvolume create /mnt/@ > /dev/null
    btrfs subvolume create /mnt/@home > /dev/null
    btrfs subvolume create /mnt/@pkg > /dev/null
    btrfs subvolume create /mnt/@log > /dev/null
    btrfs subvolume create /mnt/@swap > /dev/null
    btrfs subvolume create /mnt/@docker > /dev/null
    btrfs subvolume create /mnt/@libvirt > /dev/null

    umount /mnt

    print_success "Created 7 subvolumes: @, @home, @pkg, @log, @swap, @docker, @libvirt"
}

# Mount filesystems
mount_filesystems() {
    local efi_partition="$1"

    print_step "Mounting filesystems..."

    # Mount options
    local opts="noatime,compress=zstd,space_cache=v2"

    # Mount root
    mount -o "${opts},subvol=@" /dev/mapper/root /mnt

    # Create directories
    mkdir -p /mnt/{boot,home,var/cache/pacman/pkg,var/log,swap,.snapshots,var/lib/docker,var/lib/libvirt}

    # Mount subvolumes
    mount -o "${opts},subvol=@home" /dev/mapper/root /mnt/home
    mount -o "${opts},subvol=@pkg" /dev/mapper/root /mnt/var/cache/pacman/pkg
    mount -o "${opts},subvol=@log" /dev/mapper/root /mnt/var/log
    mount -o "noatime,subvol=@swap" /dev/mapper/root /mnt/swap
    mount -o "${opts},subvol=@docker" /dev/mapper/root /mnt/var/lib/docker
    mount -o "${opts},subvol=@libvirt" /dev/mapper/root /mnt/var/lib/libvirt

    # Mount EFI
    mount "$efi_partition" /mnt/boot

    print_success "All filesystems mounted"
}

# Initialize pacman keyring
init_keyring() {
    print_step "Initializing pacman keyring..."
    pacman-key --init
    pacman-key --populate archlinux
    print_success "Keyring initialized"
}

# Install base system
install_base() {
    local cpu_type="$1"

    print_step "Installing base system..."
    print_info "This will take several minutes..."

    local packages=(base linux linux-firmware btrfs-progs neovim networkmanager iwd base-devel git)

    # Add CPU microcode if not VM
    if [ "$cpu_type" = "amd" ]; then
        packages+=(amd-ucode)
        print_info "Including AMD microcode"
    elif [ "$cpu_type" = "intel" ]; then
        packages+=(intel-ucode)
        print_info "Including Intel microcode"
    else
        print_info "Skipping CPU microcode (VM mode)"
    fi

    pacstrap -K /mnt "${packages[@]}"

    print_success "Base system installed"
}

# Generate fstab
generate_fstab() {
    print_step "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    print_success "fstab generated"
}

# Configure system in chroot
configure_system() {
    local hostname="$1"
    local username="$2"
    local user_password="$3"
    local luks_uuid="$4"

    print_step "Configuring system..."

    # Create configuration script to run in chroot
    cat > /mnt/configure.sh << 'EOFSCRIPT'
#!/bin/bash
set -e

HOSTNAME="$1"
USERNAME="$2"
USER_PASSWORD="$3"
LUKS_UUID="$4"

# Set timezone
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc

# Set locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set console keymap
echo "KEYMAP=us" > /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# Set root password (same as user password)
echo "root:${USER_PASSWORD}" | chpasswd

# Create user
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Configure mkinitcpio with udev-based encryption
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Install and configure Limine
pacman -S --noconfirm limine

# Create Limine configuration with Tokyo Night theme
cat > /boot/limine.conf << EOFLIMINE
timeout: 3
default_entry: 1
interface_branding: HyprArch Bootloader
interface_branding_color: 2

# Tokyo Night color scheme
term_background: 1a1b26
backdrop: 1a1b26
term_palette: 15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6
term_palette_bright: 414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5
term_foreground: c0caf5
term_foreground_bright: c0caf5
term_background_bright: 24283b

/+HyprArch Linux
  //linux
    comment: HyprArch
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/initramfs-linux.img
    kernel_cmdline: quiet splash cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rootflags=subvol=@ rw rootfstype=btrfs
EOFLIMINE

# Deploy Limine UEFI files
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

# Generate initramfs
mkinitcpio -P

# Enable NetworkManager
systemctl enable NetworkManager

echo "Configuration complete!"
EOFSCRIPT

    chmod +x /mnt/configure.sh

    # Run configuration in chroot
    arch-chroot /mnt /configure.sh "$hostname" "$username" "$user_password" "$luks_uuid"

    # Clean up
    rm /mnt/configure.sh

    print_success "System configured"
}

# Main installation function
main() {
    clear
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                   ║${NC}"
    echo -e "${GREEN}║        HyprArch Installation Script               ║${NC}"
    echo -e "${GREEN}║                                                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}\n"

    # Pre-installation checks
    check_root
    check_uefi
    check_network
    update_clock

    # Get user input
    print_step "Gathering installation information..."
    echo

    show_disks
    echo
    prompt_input "Enter disk to install on (e.g., /dev/vda, /dev/sda)" DISK

    # Validate disk exists
    if [ ! -b "$DISK" ]; then
        print_error "Disk $DISK does not exist"
    fi

    # Set partition names based on disk type
    if [[ "$DISK" == *"nvme"* ]]; then
        EFI_PARTITION="${DISK}p1"
        ROOT_PARTITION="${DISK}p2"
    else
        EFI_PARTITION="${DISK}1"
        ROOT_PARTITION="${DISK}2"
    fi

    echo
    prompt_input "Enter hostname" HOSTNAME "archlinux"

    echo
    prompt_input "Enter username" USERNAME

    echo
    prompt_password "Enter user password" USER_PASSWORD

    echo
    prompt_password "Enter disk encryption password" LUKS_PASSWORD

    echo
    echo -e "${CYAN}Select CPU type:${NC}"
    echo "  1) AMD"
    echo "  2) Intel"
    echo "  3) None (VM/Other)"
    read -r -p "$(echo -e "${CYAN}Enter choice [1-3]:${NC} ")" cpu_choice

    case $cpu_choice in
        1) CPU_TYPE="amd" ;;
        2) CPU_TYPE="intel" ;;
        3) CPU_TYPE="none" ;;
        *) print_error "Invalid choice" ;;
    esac

    # Summary
    echo
    print_step "Installation Summary:"
    echo -e "  ${CYAN}Disk:${NC} $DISK"
    echo -e "  ${CYAN}Hostname:${NC} $HOSTNAME"
    echo -e "  ${CYAN}Username:${NC} $USERNAME"
    echo -e "  ${CYAN}CPU Type:${NC} $CPU_TYPE"
    echo
    print_warning "This will COMPLETELY ERASE all data on $DISK!"
    print_warning "The disk will be partitioned, encrypted, and formatted."
    echo

    read -r -p "$(echo -e "${YELLOW}Type 'YES' (in uppercase) to confirm and begin installation:${NC} ")" final_confirm
    if [ "$final_confirm" != "YES" ]; then
        print_error "Installation cancelled by user"
    fi

    echo
    print_info "Starting installation... This will take several minutes."
    print_info "No further input is required."
    echo

    # Disk setup
    partition_disk "$DISK"
    setup_luks "$ROOT_PARTITION" "$LUKS_PASSWORD"
    format_filesystems "$EFI_PARTITION"
    create_subvolumes
    mount_filesystems "$EFI_PARTITION"

    # Initialize pacman keyring before installing
    init_keyring

    # Install system
    install_base "$CPU_TYPE"
    generate_fstab

    # Get LUKS UUID for bootloader configuration
    LUKS_UUID=$(blkid "$ROOT_PARTITION" -s UUID -o value)

    # Configure system
    configure_system "$HOSTNAME" "$USERNAME" "$USER_PASSWORD" "$LUKS_UUID"

    # Success message
    echo
    print_success "Installation completed successfully!"
    echo
    print_info "System is ready to boot. You can now:"
    print_info "  1. Install additional software"
    print_info "  2. Clone your dotfiles repository"
    print_info "  3. Run your configuration script"
    echo

    # Prompt for reboot
    read -r -p "$(echo -e "${YELLOW}Reboot now? [y/N]:${NC} ")" do_reboot

    if [[ "$do_reboot" =~ ^[Yy]$ ]]; then
        print_info "Unmounting filesystems..."
        umount -R /mnt
        cryptsetup close root

        print_info "Rebooting in 3 seconds..."
        sleep 3
        reboot
    else
        print_info "Installation complete. To reboot manually, run:"
        echo "  umount -R /mnt"
        echo "  cryptsetup close root"
        echo "  reboot"
    fi
}

# Run main function
main "$@"
