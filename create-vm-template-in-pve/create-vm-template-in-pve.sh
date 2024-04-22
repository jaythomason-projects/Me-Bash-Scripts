#!/bin/bash

# This was built using documentation on 'UntouchedWagons' github repo: https://github.com/UntouchedWagons/Ubuntu-CloudInit-Docs
# In a nutshell, it creates a ready to boot VM template in Proxmox VE, with cloud-init settings applied
# It uses a config file to specify VM settings, and define cloud-init settings
# The script will look for your ISO file in /var/lib/vz/template/iso/, which is the default location for uploaded ISOs in Proxmox
# You must pass the path to a config file as an argument when running the script, or it will be upset

#--------------------------------------------------
# Begin
#--------------------------------------------------
# Check the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Check if the user has provided a config file as an argument
if [ "$#" -ne 1 ] || [[ ! "$1" =~ \.(yml|yaml)$ ]]; then
    echo "Usage: $0 <path_to_config.yml> (e.g. $0 /home/user/config.yml)"
    exit 1
fi
CONFIG_FILE="$1"

# Check if 'yq' is installed, and if not, install it. This is required to parse the config file
if ! command -v yq &> /dev/null; then
    echo "yq is not installed. Installing..."
    apt update
    apt install -y yq
fi

# Check if the iso file exists at the path specified in the config file
ISO=$(yq -re '.iso' "$CONFIG_FILE")
ISO_PATH="/var/lib/vz/template/iso/$ISO"
if [ ! -f "$ISO_PATH" ]; then
    echo "iso file not found at: $ISO_PATH. Please check the config file to ensure the iso file is correct."
    exit 1
fi

#--------------------------------------------------
# Functions
#--------------------------------------------------
copy_iso_to_tmp() {
    DISK_IMAGE_PATH="/tmp/$ISO"

    if [ ! -f "$DISK_IMAGE_PATH" ]; then
        trap 'catch_errors "cp" $?' ERR
        
        echo "Copying iso file to /tmp/..."
        cp "$ISO_PATH" /tmp/
        
        trap - ERR
        
        echo "iso file copied to /tmp/$ISO"
    fi
}

resize_disk_image() {
    trap 'catch_errors "qemu-img" $?' ERR

    echo "Resizing image file to 32GB..."
    qemu-img resize $DISK_IMAGE_PATH 32G

    trap - ERR
}

create_vm() {
    TEMPLATE_NAME=$(yq -re '.template_name' "$CONFIG_FILE")
    TEMPLATE_ID=$(yq -re '.template_id' "$CONFIG_FILE")
    NODE_STORAGE=$(yq -re '.node_storage' "$CONFIG_FILE")
    CORES=$(yq -re '.cores' "$CONFIG_FILE")
    MEMORY=$(yq -re '.memory' "$CONFIG_FILE")

    # Check if VM with the given ID already exists
    if qm status $TEMPLATE_ID &> /dev/null; then
        echo "VM with ID $TEMPLATE_ID already exists."
        catch_errors "qm status" 1
    fi

    trap 'catch_errors "qm create" $?' ERR
    
    echo "Creating a new VM..."
    qm create $TEMPLATE_ID \
    --name $TEMPLATE_NAME \
    --cpu host \
    --sockets 1 \
    --cores $CORES \
    --memory $MEMORY \
    --bios ovmf \
    --ostype l26 \
    --machine q35 \
    --agent 1 \
    --efidisk0 $NODE_STORAGE:0,pre-enrolled-keys=0 \
    --net0 virtio,bridge=vmbr0,firewall=1 \
    # --vga serial0 --serial0 socket \ # uncomment if you want to use serial console

    trap - ERR

    echo "VM created successfully."
    echo "--------------------"
}

import_disks() {
    NODE_STORAGE=$(yq -re '.node_storage' "$CONFIG_FILE")
    TEMPLATE_ID=$(yq -re '.template_id' "$CONFIG_FILE")

    trap 'catch_errors "qm importdisk" $?' ERR

    echo "Importing disks (including cloudinit)..."
    qm importdisk $TEMPLATE_ID $DISK_IMAGE_PATH $NODE_STORAGE
    qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --virtio0 $NODE_STORAGE:vm-$TEMPLATE_ID-disk-1,iothread=1
    qm set $TEMPLATE_ID --boot c --bootdisk virtio0
    qm set $TEMPLATE_ID --ide2 $NODE_STORAGE:cloudinit

    trap - ERR

    echo "Disks imported successfully."
    echo "--------------------"
}

create_snippets_file() {
    SNIPPETS_DIR="/var/lib/vz/snippets/"

    if [ ! -d "$SNIPPETS_DIR" ]; then
        mkdir "$SNIPPETS_DIR"
    fi

    echo "Creating snippets file..."
    yq -re '.cloudinit_config' $CONFIG_FILE | tee /var/lib/vz/snippets/vendor.yaml

    echo "Snippets file created successfully."
    echo "--------------------"
}

set_cloud_init_settings() {
    DEFAULT_USERNAME=$(yq -re '.cloudinit_user' "$CONFIG_FILE")
    CLEARTEXT_PASSWORD=$(yq -re '.cloudinit_password' "$CONFIG_FILE")
    TAGS=$(yq -re '.tags | join(",")' "$CONFIG_FILE") # Convert tags to comma separated string

    trap 'catch_errors "qm set" $?' ERR
    
    echo "Setting cloud-init settings..."
    qm set $TEMPLATE_ID --cicustom "vendor=local:snippets/vendor.yaml"
    qm set $TEMPLATE_ID --tags $TAGS
    qm set $TEMPLATE_ID --ciuser $DEFAULT_USERNAME
    qm set $TEMPLATE_ID --cipassword $(openssl passwd -6 $CLEARTEXT_PASSWORD)
    qm set $TEMPLATE_ID --sshkeys ~/.ssh/authorized_keys
    qm set $TEMPLATE_ID --ipconfig0 ip=dhcp

    trap - ERR

    echo "Cloud-init settings set successfully."
    echo "--------------------"
}

clean_up() {
    rm -rf $DISK_IMAGE_PATH
}

#--------------------------------------------------
# Process
#--------------------------------------------------
main() {
    copy_iso_to_tmp
    resize_disk_image
    create_vm
    import_disks
    create_snippets_file
    set_cloud_init_settings
    
    # Convert VM to a template
    qm template $TEMPLATE_ID

    echo "Template created successfully!"
}

catch_errors() {
    COMMAND=$1
    EXIT_CODE=$2
    echo "Error: Command '$COMMAND' failed with exit code $EXIT_CODE"
    clean_up
    exit $EXIT_CODE
}

main

#--------------------------------------------------
# End
#--------------------------------------------------
clean_up

exit 0