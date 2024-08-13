#!/bin/sh
#
# zfs-update-boot.sh - Updates ZFS EFI and legacy boot code on GPT devices
#
# Designed by Morgan Davis for use with FreeBSD 14 or later.
#
# Usage: Run as root. For each GPT device with a freebsd-zfs partition, it shows
# you what steps will be performed, and asks you to type 'YES' before any
# updating takes place. Anything else skips that device.
#
# Both the legacy freebsd-boot and efi partitions can be updated.
#
# EFI updates are only offered if the existing installed boot code differs from
# the latest loader.efi file.

echo "----------------------------"
echo "ZFS BOOT CODE UPDATE UTILITY"
echo "----------------------------"
echo

# Get all GPT devices
gpt_devices=$(gpart show | grep '=>' | grep 'GPT' | awk '{print $4}')

if [ -z "$gpt_devices" ]; then
	echo "No GPT devices found."
	exit 1
fi

echo "Updates ZFS EFI and legacy boot code on these GPT devices:"
echo
echo "$gpt_devices"

# Function to prompt the user for confirmation
confirm_continue() {
	echo -n "Type 'YES' (in caps) to continue or anything else to skip: "
	read -r response
	if [ "$response" != "YES" ]; then
		echo "Skipping operation."
		return 1
	fi
	echo "Continuing operation."
	return 0
}

# Function to update EFI boot code
update_efi_boot() {
	dev_name="$1"
	efi_partition="$2"

	echo "-------------------------------------------"
	echo
	echo "The EFI partition on $dev_name is $efi_partition"
	echo

	dev_path="/dev/${dev_name}p${efi_partition}"
	boot_file="BOOTx64.efi"
	startup_file="startup.nsh"
	efi_boot_dir="efi/boot"
	efi_loader_source="/boot/loader.efi"
	efi_loader_target="/mnt/${efi_boot_dir}/${boot_file}"
	efi_startup_nsh="/mnt/${efi_boot_dir}/${startup_file}"

	echo "Mounting $dev_path on /mnt"
	mount -t msdosfs -o longnames "$dev_path" /mnt

	if [ $? -eq 0 ]; then
		# Mount successful; existing MS-DOS filesystem
		echo "Comparing $efi_loader_source to $efi_loader_target"
		diff "$efi_loader_source" "$efi_loader_target"
		if [ $? -eq 0 ]; then
			echo "No differences found. Skipping EFI update of $dev_name"
			echo
			umount /mnt
			return
		fi

		echo "Current $dev_name EFI boot code differs and needs updating."
		echo
		echo "What happens next if you continue:"
		echo
		echo "   * Backup $efi_loader_target to /tmp/${boot_file}.old"
		echo "   * Backup $efi_startup_nsh to /tmp/${startup_file}.old"
		echo "   * Unmount /mnt"
		echo "   * Make a new MSDOS filesystem on $dev_path"
		echo "   * Mount $dev_path on /mnt"
		echo "   * Make the EFI boot directories"
		echo "   * Copy $efi_loader_source to $efi_loader_target"
		echo "   * Write '$boot_file' into $efi_startup_nsh"
		echo "   * Unmount /mnt"
		echo
		confirm_continue || (umount /mnt && return)
		echo

		set -e # Exit if any of these commands fail

		echo "Backing up $efi_loader_target to /tmp/${boot_file}.old"
		cp -p "$efi_loader_target" "/tmp/${boot_file}.old"

		echo "Backing up $efi_startup_nsh to /tmp/${startup_file}.old"
		cp -p "$efi_startup_nsh" "/tmp/${startup_file}.old"

		echo "Unmounting /mnt"
		umount /mnt
	fi

	set -e # Exit if any command fails.

	echo "Making a new MSDOS filesystem on $dev_path"
	newfs_msdos -F 32 -c 1 "$dev_path" || return

	echo "Mounting $dev_path on /mnt"
	mount -t msdosfs -o longnames "$dev_path" /mnt

	echo "Making the EFI boot directories"
	mkdir -p /mnt/${efi_boot_dir}

	echo "Copying $efi_loader_source to $efi_loader_target"
	cp "$efi_loader_source" "$efi_loader_target"
	echo "${boot_file}" >"$efi_startup_nsh"

	set +e # Do not exit if any command fails.

	echo "Unmounting /mnt"
	umount /mnt

	echo "EFI boot code update complete for $dev_name"
}

# Function to update GPT boot code
update_gpt_boot() {
	dev_name="$1"
	boot_partition="$2"

	echo "-------------------------------------------"
	echo
	echo "The freebsd-boot partition on $dev_name is $boot_partition"
	echo

	echo "What happens next if you continue:"
	echo
	echo "   * gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i $boot_partition $dev_name"
	echo
	confirm_continue || return
	echo

	echo "Updating GPT boot code on $dev_name..."
	gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i "$boot_partition" "$dev_name"
	echo "GPT boot code update complete for $dev_name."
}

# Main loop -- iterate over each GPT device
for dev_name in $gpt_devices; do
	echo
	echo "-------------------------------------------"
	echo
	gpart show "$dev_name"

	# Check for ZFS partition
	zfs_partition=$(gpart show "$dev_name" | grep 'freebsd-zfs' | awk '{print $3}')
	if [ -z "$zfs_partition" ]; then
		echo "No ZFS partition found on $dev_name. Skipping."
		continue
	fi

	# Check for legacy freebsd-boot partition
	boot_partition=$(gpart show "$dev_name" | grep 'freebsd-boot' | awk '{print $3}')
	if [ -n "$boot_partition" ]; then
		update_gpt_boot "$dev_name" "$boot_partition"
	fi

	# Check for EFI partition
	efi_partition=$(gpart show "$dev_name" | grep 'efi' | awk '{print $3}')
	if [ -n "$efi_partition" ]; then
		update_efi_boot "$dev_name" "$efi_partition"
	fi

	if [ -z "$efi_partition" ] && [ -z "$boot_partition" ]; then
		echo "No EFI or freebsd-boot partition found on $dev_name."
	fi
done

echo
echo "Done."
