# zfs-update-boot
**Updates FreeBSD ZFS EFI and legacy boot code on GPT devices**

_Designed by Morgan Davis for use with FreeBSD 14 or later._

**Usage: Run as root. For each GPT device with a freebsd-zfs partition, it shows you what steps will be performed, and asks you to type 'YES' before any updating takes place. Anything else skips that device.**

Both the legacy freebsd-boot and efi partitions can be updated.

EFI updates are only offered if the existing installed boot code differs from the latest loader.efi file.
