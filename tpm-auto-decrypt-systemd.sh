#!/bin/bash

###############################################################################
# TPM2 LUKS Auto-Unlock Configuration Script
# Version: 4.0
#
# Features:
# - Detailed logging of all operations
# - Configuration file backups
# - Pre-operation validation checks
# - Color-coded status output
# - Automatic dependency installation
# - Support for multiple PCR configurations
###############################################################################

# Initialize logging
LOG_FILE="/tmp/tpm2-luks-config-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Color codes
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# Configuration
DEVICE=""
PCRS="7"
ACTION="setup"
FORCE=false
BACKUP_DIR="/etc/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Logging functions
log_info() {
    echo -e "${CYAN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

show_help() {
    echo -e "${GREEN}TPM2 LUKS Auto-Unlock Configuration Script${NC}"
    echo -e "${YELLOW}Version: 4.0${NC}\n"
    echo -e "Usage: $0 [OPTIONS]\n"
    echo -e "${YELLOW}Required Options:${NC}"
    echo -e "  ${BLUE}--device DEVICE${NC}    LUKS encrypted device (e.g., /dev/sda1)"
    echo -e "${YELLOW}Additional Options:${NC}"
    echo -e "  ${BLUE}--pcrs PCR_LIST${NC}    PCR banks to use (default: 7)"
    echo -e "  ${BLUE}--remove${NC}           Remove TPM2 binding"
    echo -e "  ${BLUE}--force${NC}            Skip confirmations"
    echo -e "  ${BLUE}--help${NC}             Show this help"
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device) DEVICE="$2"; shift 2 ;;
            --pcrs) PCRS="$2"; shift 2 ;;
            --remove) ACTION="remove"; shift ;;
            --force) FORCE=true; shift ;;
            --help) show_help ;;
            *) log_error "Unknown option: $1"; show_help ;;
        esac
    done

    [ -z "$DEVICE" ] && { log_error "--device argument required"; show_help; }
}

setup_environment() {
    log_info "Creating backup directory $BACKUP_DIR"
    sudo mkdir -p "$BACKUP_DIR"
    
    log_info "Backing up critical files:"
    backup_file "/etc/crypttab"
    backup_file "/etc/fstab"
    backup_file "/etc/default/grub"
}

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        sudo cp "$file" "$BACKUP_DIR/$(basename "$file").$TIMESTAMP.bak"
        log_info "Backed up $file to $BACKUP_DIR/$(basename "$file").$TIMESTAMP.bak"
    fi
}

install_dependencies() {
    log_info "Checking system requirements"
    local pkgs=("cryptsetup" "tpm2-tools")
    local missing=()

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing missing packages: ${missing[*]}"
        sudo apt-get update || { log_error "Failed to update packages"; exit 1; }
        sudo apt-get install -y "${missing[@]}" || { log_error "Failed to install packages"; exit 1; }
    fi

    if ! command -v systemd-cryptenroll >/dev/null; then
        log_error "systemd-cryptenroll not found (requires systemd 247+)"
        exit 1
    fi
}

verify_device() {
    log_info "Verifying device: $DEVICE"
    
    [ ! -b "$DEVICE" ] && { log_error "Not a block device: $DEVICE"; exit 1; }
    sudo cryptsetup isLuks "$DEVICE" || { log_error "Not a LUKS device: $DEVICE"; exit 1; }
    
    LUKS_UUID=$(sudo blkid -s UUID -o value "$DEVICE")
    [ -z "$LUKS_UUID" ] && { log_error "Could not get UUID for $DEVICE"; exit 1; }
    
    log_info "Device verified:"
    log_info "  Path: $DEVICE"
    log_info "  UUID: $LUKS_UUID"
    log_info "  LUKS Version: $(sudo cryptsetup luksDump "$DEVICE" | grep Version)"
}

check_existing_binding() {
    if sudo cryptsetup luksDump "$DEVICE" | grep -q "TPM2"; then
        log_warning "Existing TPM2 binding found"
        if ! $FORCE; then
            read -p "Overwrite existing binding? (y/N) " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || exit 0
        fi
    fi
}

configure_tpm_binding() {
    if [ "$ACTION" = "remove" ]; then
        log_info "Removing TPM2 binding from $DEVICE"
        sudo systemd-cryptenroll --wipe-slot=tpm2 "$DEVICE" || {
            log_error "Failed to remove TPM2 binding"
            exit 1
        }
        log_success "TPM2 binding removed"
    else
        log_info "Adding TPM2 binding to $DEVICE with PCRs: $PCRS"
        local opts=("--tpm2-device=auto")
        IFS=',' read -ra pcrs <<< "$PCRS"
        for pcr in "${pcrs[@]}"; do
            opts+=("--tpm2-pcrs=$pcr")
        done

        log_info "Executing: systemd-cryptenroll ${opts[*]} $DEVICE"
        sudo systemd-cryptenroll "${opts[@]}" "$DEVICE" || {
            log_error "Failed to add TPM2 binding"
            exit 1
        }
        log_success "TPM2 binding added"
    fi
}

update_crypttab() {
    local crypt_name="luks-$(basename "$DEVICE")"
    
    if [ "$ACTION" = "remove" ]; then
        log_info "Removing TPM2 options from crypttab"
        sudo sed -i "/$crypt_name/s/,tpm2-device=auto//g" /etc/crypttab
    else
        local entry="$crypt_name UUID=$LUKS_UUID none luks,discard,tpm2-device=auto"
        
        if grep -q "^$crypt_name" /etc/crypttab; then
            log_info "Updating existing crypttab entry"
            sudo sed -i "/^$crypt_name/c\\$entry" /etc/crypttab
        else
            log_info "Adding new crypttab entry"
            echo "$entry" | sudo tee -a /etc/crypttab >/dev/null
        fi
    fi
    
    log_info "Current crypttab contents:"
    cat /etc/crypttab | sed 's/^/  /'
}

update_initramfs() {
    log_info "Updating initramfs"
    sudo update-initramfs -u -k all || {
        log_error "Failed to update initramfs"
        exit 1
    }
    log_success "Initramfs updated"
}

show_system_info() {
    log_info "System Information:"
    log_info "  Kernel: $(uname -r)"
    log_info "  Systemd: $(systemd --version | head -n1)"
    log_info "  Cryptsetup: $(cryptsetup --version)"
    log_info "  TPM2 Tools: $(tpm2_getcap -v | head -n1)"
    
    log_info "\nCurrent fstab contents:"
    cat /etc/fstab | sed 's/^/  /'
    
    log_info "\nCurrent crypttab contents:"
    cat /etc/crypttab | sed 's/^/  /'
    
    log_info "\nLUKS device details:"
    sudo cryptsetup luksDump "$DEVICE" | sed 's/^/  /'
}

main() {
    echo -e "\n${GREEN}=== TPM2 LUKS Configuration Script ===${NC}"
    echo -e "Log file: $LOG_FILE\n"
    
    parse_arguments "$@"
    setup_environment
    show_system_info
    install_dependencies
    verify_device
    
    if [ "$ACTION" != "remove" ]; then
        check_existing_binding
    fi
    
    configure_tpm_binding
    update_crypttab
    update_initramfs
    
    log_success "\nOperation completed successfully"
    log_info "Next steps:"
    log_info "1. Verify you have a working recovery key"
    log_info "2. Reboot the system to test the configuration"
    log_info "3. Check console output during boot for errors"
    log_info "Full log available at: $LOG_FILE"
}

main "$@"
