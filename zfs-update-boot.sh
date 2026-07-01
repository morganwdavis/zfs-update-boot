#!/bin/sh
#
# zfs-update-boot.sh - Inspect and safely update GPT boot code on FreeBSD.
# For FreeBSD 14+, amd64 and arm64 GPT systems.
#
# Never formats a partition unless --init-esp is given (the only destructive
# op is newfs_msdos on an unmountable ESP). Default actions only ever copy
# two loader files onto an existing FAT ESP (backed up first) and write
# freebsd-boot/pmbr bootcode via gpart(8). Pool/data partitions untouched.
#
# EFI updates go in place (writes through /boot/efi if already mounted, else
# self-mounts) and are byte-verified after writing. arm64 is EFI-only;
# --init-esp is amd64-only since arm64 ESPs may also hold board firmware/DTBs.
#
# Run as root. --dry-run previews everything and writes nothing. Color is
# used on a real terminal only (set NO_COLOR=1 to disable).

VERSION="2.0.0"
PROG=${0##*/}

LOADER_EFI="/boot/loader.efi"
PMBR="/boot/pmbr"
BOOTCODE=""                         # gptzfsboot or gptboot; set after uname/rootfs

MNT=""                              # private scratch mountpoint, never /mnt
EFI_STARTUP="startup.nsh"
EFI_LOADERPATH="efi/freebsd/loader.efi"
EFI_BOOTFILE=""                     # BOOTx64.efi (amd64) or bootaa64.efi (arm64)
EFI_BOOTPATH=""

DRYRUN=0
ASSUME_YES=0
INIT_ESP=0                          # 1 only with --init-esp: allow reformat
MOUNTED=0                           # 1 while WE hold a mount on $MNT
work=""

EFI_MP=""; EFI_SELF_MOUNTED=0; EFI_REMOUNTED_RO=0   # per-disk EFI mount state
EFI_REASON=""                                       # set by efi_current() on STALE

C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""

usage() {
	cat <<EOF
$PROG v$VERSION - inspect and safely update GPT boot code on FreeBSD.

Usage: $PROG [-n] [-y] [--init-esp] [-h]

Options:
  -n, --dry-run    Show what would be done; write nothing.
  -y, --yes        Do not prompt; apply the proposed plan (still non-
                   destructive unless --init-esp is also given).
      --init-esp   Allow formatting an ESP that will not mount (amd64 only).
                   DESTRUCTIVE: erases that partition. Off by default.
  -h, --help, -?   This help.
  -V, --version    Print version and exit.

Run as root. Disks already up-to-date are skipped automatically. EFI loaders
are updated in place with a backup and post-write verify; a partition is never
formatted unless you pass --init-esp. Output is colored on a real terminal;
set NO_COLOR=1 to disable.
EOF
}

die() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	exit "${2:-1}"
}

# Restores mount state and removes the scratch dir/work file. Runs once on
# any exit, including via the INT/TERM handlers below.
cleanup() {
	if [ "$EFI_REMOUNTED_RO" -eq 1 ] && [ -n "$EFI_MP" ]; then
		mount -u -o ro "$EFI_MP" 2>/dev/null
	fi
	[ "$MOUNTED" -eq 1 ] && umount "$MNT" 2>/dev/null
	[ -n "$MNT" ] && [ -d "$MNT" ] && rmdir "$MNT" 2>/dev/null
	[ -n "$work" ] && rm -f "$work"
}

# Prompt gate. Auto-approves under --dry-run or --yes.
confirm() {
	{ [ "$DRYRUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; } && return 0
	printf '\n%sType '\''YES'\'' to proceed, anything else to skip: %s' "$C_BOLD" "$C_RESET"
	read -r _ans
	[ "$_ans" = "YES" ] && return 0
	printf '%sSkipped.%s\n' "$C_YELLOW" "$C_RESET"
	return 1
}

# Fixed-width colored label; padding applies to the label text only, so
# columns stay aligned whether or not color is active.
status_word() {  # $1 = label, $2 = color
	printf '%s%-9s%s' "$2" "$1" "$C_RESET"
}

hr() {
	printf '%s%s%s\n' "$C_DIM" '--------------------------------------------------------------------' "$C_RESET"
}

section() {  # $1 = title
	printf '\n%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
	hr
}

# Aligned label/value row, label column fixed-width so values line up.
info_line() {  # $1 = label, $2 = value
	printf '  %s%-18s%s%s\n' "$C_DIM" "$1:" "$C_RESET" "$2"
}

do_mount() {  # $1 = device path, $2 = mount option string
	mount -t msdosfs -o "$2" "$1" "$MNT" 2>/dev/null || return 1
	MOUNTED=1
}

# Clears MOUNTED only on success, so a failed (busy) umount isn't silently
# forgotten; the exit trap will retry it.
do_umount() {
	if umount "$MNT" 2>/dev/null; then
		MOUNTED=0
		return 0
	fi
	return 1
}

# Mountpoint of an already-mounted ESP (checks both the raw provider and its
# gpt label), or nothing if it isn't mounted.
esp_mountpoint() {  # $1 = dev, $2 = part index
	_pd="/dev/${1}p${2}"
	_lbl=$(gpart show -l "$1" 2>/dev/null | awk -v p="$2" '$3==p{print $4; exit}')
	_ld=""
	[ -n "$_lbl" ] && [ -e "/dev/gpt/$_lbl" ] && _ld="/dev/gpt/$_lbl"
	mount | awk -v a="$_pd" -v b="$_ld" '$1==a || (b!="" && $1==b){print $3; exit}'
}

mount_is_ro() {  # $1 = mountpoint
	mount | awk -v mp="$1" '$3==mp{print; exit}' | grep -q 'read-only'
}

# 0 if the legacy bootcode matches $BOOTCODE, 1 if stale, 2 if undetermined.
# cmp -n reads via stdio in sector-aligned buffers; dd bs=<non-sector-size>
# on a raw GEOM provider can reject or short-read.
legacy_current() {  # $1 = dev, $2 = part index
	_size=$(stat -f %z "$BOOTCODE" 2>/dev/null) || return 2
	[ "$_size" -gt 0 ] 2>/dev/null || return 2
	cmp -s -n "$_size" "$BOOTCODE" "/dev/${1}p${2}" 2>/dev/null
	_rc=$?
	[ "$_rc" -gt 1 ] && return 2
	return "$_rc"
}

# 0 if both EFI loaders under a base dir match the source loader.
efi_dir_matches() {  # $1 = base dir
	for _rel in "$EFI_BOOTPATH" "$EFI_LOADERPATH"; do
		cmp -s "$LOADER_EFI" "${1}/${_rel}" 2>/dev/null || return 1
	done
	return 0
}

# 0 if the ESP loaders match, 1 if any differ/missing, 2 if unmountable. On a
# 1, EFI_REASON names exactly which file(s) are stale/missing (a boolean
# alone would mislead the scan text about which loader is the problem).
efi_current() {  # $1 = dev, $2 = part index
	_mp=$(esp_mountpoint "$1" "$2")
	_self=0
	if [ -z "$_mp" ]; then
		do_mount "/dev/${1}p${2}" "ro,longnames" || return 2
		_mp="$MNT"
		_self=1
	fi
	EFI_REASON=""
	_rc=0
	for _rel in "$EFI_BOOTPATH" "$EFI_LOADERPATH"; do
		_name=${_rel##*/}
		if [ ! -f "${_mp}/${_rel}" ]; then
			_frag="$_name is missing"
		elif ! cmp -s "$LOADER_EFI" "${_mp}/${_rel}" 2>/dev/null; then
			_frag="$_name differs from $LOADER_EFI"
		else
			_frag=""
		fi
		if [ -n "$_frag" ]; then
			EFI_REASON="${EFI_REASON:+$EFI_REASON; }$_frag"
			_rc=1
		fi
	done
	[ "$_self" -eq 1 ] && do_umount
	return "$_rc"
}

# Obtains a writable ESP mount, reusing an existing mount when present.
# Sets EFI_MP/EFI_SELF_MOUNTED/EFI_REMOUNTED_RO; returns 1 if none available.
efi_writable_mount() {  # $1 = dev, $2 = part index
	EFI_MP=""; EFI_SELF_MOUNTED=0; EFI_REMOUNTED_RO=0
	_mp=$(esp_mountpoint "$1" "$2")
	if [ -n "$_mp" ]; then
		EFI_MP="$_mp"
		if mount_is_ro "$_mp"; then
			# Set the restore flag before remounting, so an interrupt
			# mid-remount still gets flipped back to ro by cleanup().
			EFI_REMOUNTED_RO=1
			if [ "$DRYRUN" -eq 0 ]; then
				mount -u -o rw "$_mp" 2>/dev/null || return 1
			fi
		fi
		return 0
	fi
	_mode="rw,longnames"
	[ "$DRYRUN" -eq 1 ] && _mode="ro,longnames"
	do_mount "/dev/${1}p${2}" "$_mode" || return 1
	EFI_MP="$MNT"
	EFI_SELF_MOUNTED=1
}

efi_release() {
	if [ "$EFI_SELF_MOUNTED" -eq 1 ]; then
		do_umount
	elif [ "$EFI_REMOUNTED_RO" -eq 1 ] && [ "$DRYRUN" -eq 0 ]; then
		mount -u -o ro "$EFI_MP" 2>/dev/null
	fi
	EFI_MP=""; EFI_SELF_MOUNTED=0; EFI_REMOUNTED_RO=0
}

# Copies the loaders onto an already-mounted ESP ($EFI_MP), backing up first.
efi_apply_inplace() {  # $1 = dev, $2 = part index
	_stamp="/tmp/${1}p${2}"
	for _rel in "$EFI_BOOTPATH" "$EFI_LOADERPATH"; do
		_tgt="${EFI_MP}/${_rel}"
		_dir=${_tgt%/*}
		[ -d "$_dir" ] || mkdir -p "$_dir" || die "mkdir $_dir failed"
		_base=${_rel##*/}
		if [ -f "$_tgt" ]; then
			cp -p "$_tgt" "${_stamp}-${_base}.old" || die "backup $_tgt failed"
			printf '  %sbacked up %s -> %s-%s.old%s\n' "$C_DIM" "$_tgt" "$_stamp" "$_base" "$C_RESET"
		fi
		cp "$LOADER_EFI" "$_tgt" || die "cp to $_tgt failed"
		printf '  %swrote %s%s\n' "$C_DIM" "$_tgt" "$C_RESET"
	done
	_nsh="${EFI_MP}/efi/boot/${EFI_STARTUP}"
	[ -f "$_nsh" ] && cp -p "$_nsh" "${_stamp}-${EFI_STARTUP}.old"
	printf '%s\n' "$EFI_BOOTFILE" > "$_nsh" || die "write $_nsh failed"
}

# Destructive: formats an unmountable ESP and installs the loaders. Only
# reached with --init-esp; leaves the ESP mounted on $MNT for verify.
efi_apply_format() {  # $1 = dev, $2 = part index
	_path="/dev/${1}p${2}"
	newfs_msdos -F 32 "$_path" || die "newfs_msdos $_path failed"
	do_mount "$_path" "rw,longnames" || die "mount $_path failed after newfs"
	for _rel in "$EFI_BOOTPATH" "$EFI_LOADERPATH"; do
		_tgt="${MNT}/${_rel}"
		mkdir -p "${_tgt%/*}" || die "mkdir failed"
		cp "$LOADER_EFI" "$_tgt" || die "cp to $_tgt failed"
	done
	printf '%s\n' "$EFI_BOOTFILE" > "${MNT}/efi/boot/${EFI_STARTUP}" \
		|| die "write startup.nsh failed"
}

# Calm guidance for an unmountable ESP when --init-esp was not given.
efi_init_guidance() {  # $1 = dev, $2 = part index
	printf '%sEFI partition %sp%s is not a mountable FAT filesystem.%s\n' \
		"$C_YELLOW" "$1" "$2" "$C_RESET"
	printf 'Skipping it (safe default: this script will not format a disk).\n'
	if [ "$arch" != "amd64" ]; then
		printf 'On %s the ESP may also hold board firmware or DTBs; automated\n' "$arch"
		printf 'formatting is disabled here. Initialize by hand only if you are sure:\n'
	else
		printf 'If you are certain this ESP is FreeBSD-only and should be\n'
		printf 'initialized, re-run with --init-esp, or do it by hand:\n'
	fi
	printf '  newfs_msdos -F 32 /dev/%sp%s\n' "$1" "$2"
	printf '  mount -t msdosfs /dev/%sp%s /mnt\n' "$1" "$2"
	printf '  mkdir -p /mnt/efi/boot /mnt/efi/freebsd\n'
	printf '  cp %s /mnt/%s\n' "$LOADER_EFI" "$EFI_BOOTPATH"
	printf '  cp %s /mnt/%s\n' "$LOADER_EFI" "$EFI_LOADERPATH"
	printf '  umount /mnt\n'
}

update_legacy() {  # $1 = dev, $2 = part index
	printf '\n%s== %s: legacy boot code (partition %s) ==%s\n' \
		"$C_BOLD$C_CYAN" "$1" "$2" "$C_RESET"
	if [ ! -r "$PMBR" ] || [ ! -r "$BOOTCODE" ]; then
		printf '%sSkipping: missing %s or %s.%s\n' "$C_YELLOW" "$PMBR" "$BOOTCODE" "$C_RESET" >&2
		return 0
	fi
	printf 'Plan:\n  gpart bootcode -b %s -p %s -i %s %s\n' "$PMBR" "$BOOTCODE" "$2" "$1"
	confirm || return 0
	if [ "$DRYRUN" -eq 1 ]; then
		printf '  %s[dry-run] command shown above; nothing written.%s\n' "$C_YELLOW" "$C_RESET"
		return 0
	fi
	if ! gpart bootcode -b "$PMBR" -p "$BOOTCODE" -i "$2" "$1"; then
		printf '%sFAILED to write legacy boot code on %s.%s\n' "$C_RED$C_BOLD" "$1" "$C_RESET" >&2
		return 0
	fi
	if legacy_current "$1" "$2"; then
		printf '%sLegacy boot code updated and verified on %s.%s\n' "$C_GREEN" "$1" "$C_RESET"
	else
		printf '%sWARNING: post-write verify FAILED on %s.%s\n' "$C_RED$C_BOLD" "$1" "$C_RESET" >&2
	fi
}

update_efi() {  # $1 = dev, $2 = part index, $3 = emode (inplace|init)
	printf '\n%s== %s: EFI system partition (partition %s) ==%s\n' \
		"$C_BOLD$C_CYAN" "$1" "$2" "$C_RESET"

	if [ "$3" = "init" ]; then
		if [ "$INIT_ESP" -eq 0 ] || [ "$arch" != "amd64" ]; then
			efi_init_guidance "$1" "$2"
			return 0
		fi
		printf '%sDESTRUCTIVE: formatting /dev/%sp%s erases everything on it.%s\n' \
			"$C_RED$C_BOLD" "$1" "$2" "$C_RESET"
		printf 'Only continue if this ESP holds no other OS boot files.\n'
		printf 'Plan:\n  newfs_msdos -F 32 /dev/%sp%s\n  install loaders\n' "$1" "$2"
		confirm || return 0
		if [ "$DRYRUN" -eq 1 ]; then
			printf '  %s[dry-run] would format and install; nothing written.%s\n' "$C_YELLOW" "$C_RESET"
			return 0
		fi
		efi_apply_format "$1" "$2"
		efi_dir_matches "$MNT"
		_ok=$?
		do_umount
		if [ "$_ok" -eq 0 ]; then
			printf '%sESP initialized and loaders verified on %s.%s\n' "$C_GREEN" "$1" "$C_RESET"
		else
			printf '%sWARNING: verify FAILED after init on %s.%s\n' "$C_RED$C_BOLD" "$1" "$C_RESET" >&2
		fi
		return 0
	fi

	if ! efi_writable_mount "$1" "$2"; then
		printf '%sCould not get a writable ESP mount; skipping %s.%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2
		return 0
	fi
	_where="already mounted (write-through)"
	if [ "$EFI_SELF_MOUNTED" -eq 1 ]; then
		_where="mounted by script"
		printf 'Target: %s  (/dev/%sp%s)  [%s]\n' "$EFI_MP" "$1" "$2" "$_where"
	else
		printf 'Target: %s  [%s]\n' "$EFI_MP" "$_where"
	fi
	printf 'Plan: back up and overwrite in place:\n'
	for _rel in "$EFI_BOOTPATH" "$EFI_LOADERPATH"; do
		printf '  %s/%s\n' "$EFI_MP" "$_rel"
	done
	if ! confirm; then
		efi_release
		return 0
	fi
	if [ "$DRYRUN" -eq 1 ]; then
		printf '  %s[dry-run] would back up and copy loaders; nothing written.%s\n' "$C_YELLOW" "$C_RESET"
		efi_release
		return 0
	fi
	efi_apply_inplace "$1" "$2"
	efi_dir_matches "$EFI_MP"
	_ok=$?
	efi_release
	if [ "$_ok" -eq 0 ]; then
		printf '%sEFI loaders updated and verified on %s.%s\n' "$C_GREEN" "$1" "$C_RESET"
	else
		printf '%sWARNING: post-write verify FAILED on %s; backups are in /tmp.%s\n' \
			"$C_RED$C_BOLD" "$1" "$C_RESET" >&2
	fi
}

while [ $# -gt 0 ]; do
	case $1 in
		-n|--dry-run) DRYRUN=1 ;;
		-y|--yes) ASSUME_YES=1 ;;
		--init-esp) INIT_ESP=1 ;;
		-h|--help|-\?) usage; exit 0 ;;
		-V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die "unknown option: $1" 2 ;;
		*) usage >&2; die "unexpected argument: $1" 2 ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || die "must be run as root" 1
command -v gpart >/dev/null 2>&1 || die "gpart not found" 1

# Color only on an interactive terminal with a capable TERM and no NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] \
	&& command -v tput >/dev/null 2>&1 \
	&& [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
	C_RESET=$(tput sgr0)
	C_BOLD=$(tput bold)
	C_DIM=$(tput dim 2>/dev/null || printf '')
	C_RED=$(tput setaf 1)
	C_GREEN=$(tput setaf 2)
	C_YELLOW=$(tput setaf 3)
	C_CYAN=$(tput setaf 6)
fi

# amd64: BOOTx64.efi, plus optional legacy pmbr/gptzfsboot|gptboot.
# arm64: EFI-only, boots bootaa64.efi, no legacy bootcode.
arch=$(uname -m)
case $arch in
	amd64) EFI_BOOTFILE="BOOTx64.efi" ;;
	arm64) EFI_BOOTFILE="bootaa64.efi" ;;
	*) die "unsupported architecture '$arch'; supports amd64 and arm64" 1 ;;
esac
EFI_BOOTPATH="efi/boot/${EFI_BOOTFILE}"

# Private scratch mountpoint, never /mnt, so a killed prior run can't block
# this one. INT/TERM call exit explicitly so the EXIT trap fires exactly
# once and actually stops the script, rather than resuming after cleanup.
MNT=$(mktemp -d -t "${PROG%.sh}.mnt") || die "mktemp -d failed" 1
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s%s v%s%s\n' "$C_BOLD" "$PROG" "$VERSION" "$C_RESET"
if [ "$INIT_ESP" -eq 1 ]; then
	printf '\n%s%s!! --init-esp is ACTIVE for this run !!%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
	printf '%sIf an EFI partition will not mount, it will be FORMATTED (erasing its\n' "$C_YELLOW"
	printf 'current contents) before the loaders are installed. This only applies\n'
	printf 'to a partition that is currently unmountable; mountable ESPs are always\n'
	printf 'updated in place, never reformatted.%s\n' "$C_RESET"
else
	printf 'Safe by default: in-place loader updates with backups; no partition is\n'
	printf 'formatted unless you pass --init-esp.\n'
fi
[ "$DRYRUN" -eq 1 ] && printf '\n%s(dry-run: nothing will be written)%s\n' "$C_YELLOW" "$C_RESET"

# Legacy bootcode applies to amd64 only; picked from the root fs type.
rootfs=$(mount | awk '$3=="/"{print $4; exit}' | tr -d '()' | awk -F, '{print $1}')
if [ "$arch" = "amd64" ]; then
	case $rootfs in
		zfs) BOOTCODE="/boot/gptzfsboot" ;;
		ufs) BOOTCODE="/boot/gptboot" ;;
		*) BOOTCODE="/boot/gptzfsboot" ;;
	esac
fi

bootmethod=$(sysctl -n machdep.bootmethod 2>/dev/null)
printf '\n'
info_line "Architecture" "$arch"
info_line "Boot method" "${bootmethod:-unknown}"
if [ -n "$BOOTCODE" ]; then
	info_line "Root fs" "${rootfs:-unknown}"
	info_line "Legacy bootcode" "$BOOTCODE"
	info_line "EFI loader" "$EFI_BOOTFILE (if present)"
else
	info_line "Legacy boot" "not applicable (EFI-only)"
	info_line "EFI loader" "$EFI_BOOTFILE"
fi

gpt_devices=$(gpart show 2>/dev/null | awk '/=>/ && /GPT/ {print $4}')
[ -n "$gpt_devices" ] || die "no GPT devices found" 1

# Record format (pipe-delimited so empty fields, e.g. no freebsd-boot, survive
# read-back): dev|bpart|epart|nboot|emode
#   nboot: 0|1 (legacy needs update)   emode: none|inplace|init (EFI action)

work=$(mktemp -t "${PROG%.sh}") || die "mktemp failed" 1
needing=0

section "Scanning GPT boot status (read-only)"
for dev in $gpt_devices; do
	show=$(gpart show "$dev")
	printf '%s\n' "$show" | grep -q ' freebsd-zfs ' || continue

	bpart=$(printf '%s\n' "$show" | awk '/ freebsd-boot /{print $3; exit}')
	epart=$(printf '%s\n' "$show" | awk '/ efi /{print $3; exit}')

	nboot=0
	emode="none"

	printf '\n  %s%s%s\n' "$C_BOLD" "$dev" "$C_RESET"

	if [ -n "$bpart" ] && [ -n "$BOOTCODE" ]; then
		if [ ! -r "$BOOTCODE" ]; then
			printf '    freebsd-boot (partition %s): %s- %s not found on this system\n' \
				"$bpart" "$(status_word unknown "$C_YELLOW")" "$BOOTCODE"
		else
			legacy_current "$dev" "$bpart"
			case $? in
				0) printf '    freebsd-boot (partition %s): %s- matches %s\n' \
					"$bpart" "$(status_word current "$C_GREEN")" "$BOOTCODE" ;;
				1) printf '    freebsd-boot (partition %s): %s- on-disk code differs from %s\n' \
					"$bpart" "$(status_word STALE "$C_RED")" "$BOOTCODE"
					nboot=1 ;;
				*) printf '    freebsd-boot (partition %s): %s- could not read the partition to compare\n' \
					"$bpart" "$(status_word unknown "$C_YELLOW")" ;;
			esac
		fi
	elif [ -n "$bpart" ]; then
		printf '    freebsd-boot (partition %s): %s- %s is EFI-only, legacy bootcode is not used\n' \
			"$bpart" "$(status_word n/a "$C_DIM")" "$arch"
	fi

	if [ -n "$epart" ]; then
		if [ ! -r "$LOADER_EFI" ]; then
			printf '    efi          (partition %s): %s- %s not found on this system\n' \
				"$epart" "$(status_word unknown "$C_YELLOW")" "$LOADER_EFI"
		else
			efi_current "$dev" "$epart"
			case $? in
				0) printf '    efi          (partition %s): %s- matches %s\n' \
					"$epart" "$(status_word current "$C_GREEN")" "$LOADER_EFI" ;;
				1) printf '    efi          (partition %s): %s- %s\n' \
					"$epart" "$(status_word STALE "$C_RED")" "$EFI_REASON"
					emode="inplace" ;;
				2) printf '    efi          (partition %s): %s- the ESP will not mount\n' \
					"$epart" "$(status_word unknown "$C_YELLOW")"
					emode="init" ;;
			esac
		fi
	fi

	if [ -z "$bpart" ] && [ -z "$epart" ]; then
		printf '    %s(no freebsd-boot or efi partition found on this disk)%s\n' "$C_DIM" "$C_RESET"
	fi

	if [ "$nboot" -eq 1 ] || [ "$emode" != "none" ]; then
		needing=$((needing + 1))
		printf '%s|%s|%s|%s|%s\n' "$dev" "$bpart" "$epart" "$nboot" "$emode" >> "$work"
	fi
done

if [ "$needing" -eq 0 ]; then
	printf '\n%sAll boot code is current. Nothing to do.%s\n' "$C_GREEN" "$C_RESET"
	exit 0
fi

section "Proposed changes ($needing disk(s) need updates)"
while IFS='|' read -r dev bpart epart nboot emode <&3; do
	printf '\n  %s%s%s\n' "$C_BOLD" "$dev" "$C_RESET"
	[ "$nboot" = "1" ] && printf '    - update legacy bootcode (gpart bootcode -i %s)\n' "$bpart"
	case $emode in
		inplace) printf '    - update EFI loaders in place (backup + verify)\n' ;;
		init)
			if [ "$INIT_ESP" -eq 1 ] && [ "$arch" = "amd64" ]; then
				printf '    %s- FORMAT the EFI partition and install loaders (--init-esp)%s\n' \
					"$C_RED$C_BOLD" "$C_RESET"
			else
				printf '    %s- skip EFI partition: not mountable (re-run with --init-esp to format it)%s\n' \
					"$C_YELLOW" "$C_RESET"
			fi
			;;
	esac
done 3< "$work"
printf '\n  %sPool and data partitions are not touched.%s\n' "$C_DIM" "$C_RESET"

# fd 3, not stdin: update_legacy/update_efi call confirm(), which reads 'YES'
# from the terminal on fd 0. Reading the work file on fd 0 here instead would
# let those nested reads steal lines from it, resolving every prompt to an
# empty answer the instant the file ran out.
section "Applying updates"
while IFS='|' read -r dev bpart epart nboot emode <&3; do
	[ "$nboot" = "1" ] && update_legacy "$dev" "$bpart"
	case $emode in
		inplace) update_efi "$dev" "$epart" "inplace" ;;
		init) update_efi "$dev" "$epart" "init" ;;
	esac
done 3< "$work"

printf '\n'
hr
printf '%sDone.%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
