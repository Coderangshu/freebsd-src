#!/bin/sh
#
# Copyright (c) 2026 The FreeBSD Project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
#

set -e

NANO_PLAN=default

#
# Partition layout varies by NANO_BOOT_TYPE (partitions are emitted in this
# order by calculate_partitioning).
#
# Notes common to all layouts:
#   - [PMBR boot code] is written via "mkimg -b boot/pmbr"; it is the
#     protective MBR boot code, not a GPT partition entry.
#   - gptboot0 carries /boot/gptboot; only present for BIOS boot type.
#   - efiboot0 is the sole ESP; it carries gptboot.efi, which selects
#     the root partition from the GPT bootme/bootonce attributes.
#   - [freebsd-swap/swap0] is only created when NANO_SWAP_SIZE > 0.
#   - root B (${NANO_LABEL}2) only exists when NANO_IMAGES > 1.
#
# "BIOS":
#   [PMBR boot code]                boot/pmbr (not a GPT entry)
#   [freebsd-boot/gptboot0]         /boot/gptboot
#   [freebsd-swap/swap0]            swap (optional)
#   [freebsd-ufs/${NANO_LABEL}1]    root A (read-only)
#   [freebsd-ufs/${NANO_LABEL}2]    root B (read-only, A/B updates)
#   [freebsd-ufs/cfg]               configuration partition
#   [freebsd-ufs/data]              data partition (optional)
#
# "UEFI":
#   [efi/efiboot0]                  ESP carrying gptboot.efi (FAT)
#   [freebsd-swap/swap0]            swap (optional)
#   [freebsd-ufs/${NANO_LABEL}1]    root A (read-only)
#   [freebsd-ufs/${NANO_LABEL}2]    root B (read-only, A/B updates)
#   [freebsd-ufs/cfg]               configuration partition
#   [freebsd-ufs/data]              data partition (optional)
#
# "BIOS UEFI" (default):
#   [PMBR boot code]                boot/pmbr (not a GPT entry)
#   [freebsd-boot/gptboot0]         /boot/gptboot
#   [efi/efiboot0]                  ESP carrying gptboot.efi (FAT)
#   [freebsd-swap/swap0]            swap (optional)
#   [freebsd-ufs/${NANO_LABEL}1]    root A (read-only)
#   [freebsd-ufs/${NANO_LABEL}2]    root B (read-only, A/B updates)
#   [freebsd-ufs/cfg]               configuration partition
#   [freebsd-ufs/data]              data partition (optional)
#

#
# Space-separated list of boot types; options: BIOS, UEFI (case-insensitive).
# Default enables both.
#
NANO_BOOT_TYPE="BIOS UEFI"

# Set NANO_LABEL to non-blank to form the basis for using /dev/gpt/code
# in preference to /dev/${NANO_DRIVE}
# Root partition will be /dev/gpt/${NANO_ROOT, NANO_ALTROOT}
# /cfg partition will be /dev/gpt/cfg
# /data partition will be /dev/gpt/data
NANO_LABEL=code
NANO_PARTITION_ROOT=1
NANO_PARTITION_CFG=cfg
NANO_PARTITION_DATA=data

NANO_ROOT="${NANO_LABEL}${NANO_PARTITION_ROOT}"

if [ "$NANO_IMAGES" -gt 1 ]; then
	NANO_PARTITION_ALTROOT=2
	NANO_ALTROOT="${NANO_LABEL}${NANO_PARTITION_ALTROOT}"
fi

# Override NANO_DRIVE with NANO_LABEL
if [ -z "${NANO_LABEL}" ]; then
	err "NANO_LABEL must be defined"
fi

NANO_BOOTLOADER="boot/gptboot"

NANO_ALIGN="${NANO_ALIGN:-1MiB}"

# makefs parameters to use
NANO_MAKEFS="-o softupdates=1,version=2"

# Create the /etc/fstab file
tgt_write_fstab() {
	(
	cd "$NANO_WORLDDIR"

	# Save config file for scripts
	echo "NANO_DRIVE=${NANO_DRIVE}" > etc/nanobsd.conf
	echo "NANO_LABEL=${NANO_LABEL}" >> etc/nanobsd.conf
	echo "NANO_ROOT=${NANO_ROOT}" >> etc/nanobsd.conf
	echo "NANO_ALTROOT=${NANO_ALTROOT}" >> etc/nanobsd.conf
	tgt_touch etc/nanobsd.conf

	printf_fstab "# Device" Mountpoint FStype Options Dump "Pass#"
	if [ "$NANO_CIDATA_SIZE" -gt 0 ]; then
		printf_fstab "/dev/msdosfs/CIDATA" /boot/msdos msdosfs rw,noauto 2 2
	fi
	if is_boot_type UEFI; then
		printf_fstab "/dev/gpt/efiboot0" /boot/efi msdosfs rw,noauto 2 2
	fi
	printf_fstab "/dev/gpt/${NANO_ROOT}" / ufs ro 1 1
	printf_fstab /dev/gpt/${NANO_PARTITION_CFG} /cfg ufs rw,noauto 2 2
	if [ "$NANO_SWAP_SIZE" -gt 0 ]; then
		if [ -n "$NANO_SWAP_ENCRYPTION" ]; then
			printf_fstab "/dev/gpt/swap0.eli" none swap sw 0 0
		else
			printf_fstab "/dev/gpt/swap0" none swap sw 0 0
		fi
	fi
	if [ "$NANO_DATASIZE" -ne 0 ]; then
		printf_fstab /dev/gpt/${NANO_PARTITION_DATA} /${NANO_PARTITION_DATA} ufs rw,noauto 2 2
	fi

	tgt_touch etc/fstab
	)
}

# Pick up config files from the special partition
tgt_etc_remount() {
	(
	cd "$NANO_WORLDDIR"

	echo "mount -o ro /dev/gpt/${NANO_PARTITION_CFG}" > conf/default/etc/remount
	tgt_touch conf/default/etc/remount
	)
}

#
# Check whether a boot type is present in NANO_BOOT_TYPE
# Input: $1 = boot type to check
# Output: return 0 if found, 1 if not
#
is_boot_type() {
	local boot_type boot_types

	boot_type=$(echo "$1" | tr "[:upper:]" "[:lower:]")
	boot_types=$(echo "${NANO_BOOT_TYPE}" | tr "[:upper:]" "[:lower:]")

	# These architectures lack a BIOS
	case "$NANO_ARCH" in
	aarch64|riscv64|riscv)
		case "${boot_type}" in
		efi|uefi) ;;
		*) return 1 ;;
		esac
		;;
	esac

	case " ${boot_types} " in
	*" ${boot_type} "*) return 0 ;;
	*) return 1 ;;
	esac
}

# Create a FreeBSD Boot Partition image file of 512 KiB
create_boot_partition() {
	local bootcode

	bootcode="${NANO_WORLDDIR}/${NANO_BOOTLOADER}"

	if [ ! -f "$bootcode" ]; then
		echo "Image will not be bootable"
	else
		cp -p "$bootcode" "${NANO_OBJ}/_.gptboot0.image"
		truncate -s 512k "${NANO_OBJ}/_.gptboot0.image"
	fi
}

# Create an EFI System Partition image file
create_esp_partition() {
	local bootcode efibootname espdir esp_sects fat_type

	# Since sectors_per_cluster=1, assume 1 cluster = 1 sector
	MINCLS16=4085	# minimum FAT16 clusters (0xff5U)
	MINCLS32=65525	# minimum FAT32 clusters (0xfff5U)
	esp_sects=$(awk '$5 == "efiboot0" {print $4}' "${NANO_LOG}/_.partitioning")
	if [ "$esp_sects" -ge "$MINCLS32" ]; then
		fat_type=32
	elif [ "$esp_sects" -ge "$MINCLS16" ]; then
		fat_type=16
	else
		fat_type=12
	fi

	espdir="${NANO_OBJ}/_.efi"
	rm -rf "$espdir"
	mkdir -p "${espdir}/EFI/BOOT"

	efibootname=$(get_uefi_bootname)
	bootcode="${NANO_WORLDDIR}/$(get_bootcode uefi ufs)"

	if [ ! -f "$bootcode" ]; then
		echo "Image will not be bootable"
	fi

	cp -p "$bootcode" "${espdir}/EFI/BOOT/${efibootname}.EFI"

	# XXXJL https://wiki.archlinux.org/title/EFI_system_partition#Firmware_does_not_see_the_EFI_directory
	#       Other FreeBSD tools use EFISYS
	makefs -t msdos \
	    -o fat_type="$fat_type" \
	    -o sectors_per_cluster=1 \
	    -o volume_label="EFI" \
	    -o OEM_string="" \
	    -s "${esp_sects}b" \
	    -T "$NANO_TIMESTAMP" \
	    "${NANO_OBJ}/_.efiboot0.image" "$espdir"

	rm -rf "$espdir"
}

# Create an MS Basic Data Partition for nuageinit (cidata)
create_cidata_partition() {
	local cidatadir cidata_sects fat_type

	# Since sectors_per_cluster=1, assume 1 cluster = 1 sector
	MINCLS16=4085	# minimum FAT16 clusters (0xff5U)
	MINCLS32=65525	# minimum FAT32 clusters (0xfff5U)
	cidata_sects=$(awk -v label="cidata" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	if [ "$cidata_sects" -ge "$MINCLS32" ]; then
		fat_type=32
	elif [ "$cidata_sects" -ge "$MINCLS16" ]; then
		fat_type=16
	else
		fat_type=12
	fi

	cidatadir="${NANO_OBJ}/_.cidata"
	rm -rf "$cidatadir"
	mkdir -p "$cidatadir"

	is_defined populate_cidata_partition && populate_cidata_partition

	makefs -t msdos \
	    -o fat_type="$fat_type" \
	    -o sectors_per_cluster=1 \
	    -o volume_label="CIDATA" \
	    -o OEM_string="" \
	    -s "${cidata_sects}b" \
	    -T "$NANO_TIMESTAMP" \
	    "${NANO_OBJ}/_.cidata.image" "$cidatadir"

	rm -rf "$cidatadir"
}

#
# Calculate partition sizes aligned at NANO_ALIGN boundaries.
# All sizes are in bytes.
# The output is compatible with gpart restore
#
calculate_partitioning() {
	local align boot_sects boot_size boot_type esp_sects
	align=$(strtobytes "$NANO_ALIGN")
	boot_sects=0
	boot_size=0
	boot_type=0
	esp_sects=0

	if is_boot_type BIOS; then
		boot_type=1
		# Boot partition is exactly 512 KiB
		boot_size=$(strtobytes 512KiB)
		boot_sects=$(( boot_size / NANO_SECTOR_SIZE ))
	fi
	is_boot_type UEFI && esp_sects=$(( NANO_EFI_BOOTPART_SIZE / NANO_SECTOR_SIZE ))
	[ -n "$NANO_CIDATA_SIZE" ] && cidata_sects=$(( NANO_CIDATA_SIZE / NANO_SECTOR_SIZE ))

	echo "$NANO_MEDIASIZE" "$NANO_IMAGES" "$NANO_SECTOR_SIZE" \
	    "$NANO_CODESIZE" "$NANO_CONFSIZE" "$NANO_DATASIZE" "$boot_type" \
	    "$boot_sects" "$esp_sects" "$NANO_SWAP_SIZE" "$NANO_ROOT" \
	    "${NANO_ALTROOT:--}" "$NANO_PARTITION_CFG" "$NANO_PARTITION_DATA" \
	    "$align" "$cidata_sects" | awk '
	function roundup(sects) {
		return int((sects + align - 1) / align) * align
	}
	function print_line(type, sects, label,   windex, wtype, wblocks) {
		windex = 3
		if (cidata_sects > 0) {
			wtype = "ms-basic-data"
		} else if (swap_sects > 0) {
			wtype = "freebsd-swap"
		} else {
			wtype = "freebsd-ufs"
		}
		wtype = length(wtype)
		wblocks = length(media_sects)

		printf "%-*s %*s %*s %*s %s\n",
		    windex, i,
		    wtype, type,
		    wblocks, sstart,
		    wblocks, sects,
		    label
		sstart += sects
		avail_sects -= sects
		i++
	}

	{
		# Sector size
		ssize = $3

		# Media size in sectors
		media_sects = int($1 / ssize)

		# Align to a NANO_ALIGN boundary in sectors
		align = int($15 / ssize)

		# GPT backup metadata at the end of the disk in sectors
		# (128 entries x 128 bytes + 1 header sector)
		gpt_end_sects = int((128 * 128) / ssize) + 1

		# Boot size in sectors (already rounded up)
		boot_sects = ($8 > 0) ? $8 : 0

		# CIDATA size in sectors (rounded up)
		cidata_sects = ($16 > 0) ? roundup($16) : 0

		# ESP size in sectors (rounded up)
		esp_sects = ($9 > 0) ? roundup($9) : 0

		# Swap size in sectors (rounded up)
		swap_sects = ($10  > 0) ? roundup($10) : 0

		# Configuration partition size in sectors (rounded up)
		cfg_sects = roundup($5 / ssize)

		# Data partition size in sectors (rounded up)
		data_sects = ($6 > 0) ? roundup($6) : $6

		# Starting sector (512/4K-bytes aligned)
		sstart = 40

		# Available sectors
		avail_sects = media_sects - sstart - gpt_end_sects

		# Print header (scheme and number of entries)
		print "GPT 128"

		# Partition index counter
		i = 1

		# Boot partition (if any)
		if ($7 == 1) {
			print_line("freebsd-boot", boot_sects, "gptboot0")
		}

		# Starting sector (NANO_ALIGN boundary in sectors)
		avail_sects -= (align - sstart)
		sstart = align

		# CIDATA partition (if any)
		if (cidata_sects > 0) {
			print_line("ms-basic-data", cidata_sects, "cidata")
		}

		# ESP partition (if any)
		if (esp_sects > 0) {
			print_line("efi", esp_sects, "efiboot0")
		}

		# Swap partition (if any)
		if (swap_sects > 0) {
			print_line("freebsd-swap", swap_sects, "swap0")
		}

		# Code partition size in sectors
		code_sects = int($4 / ssize)
		if (code_sects == 0) {
			# (rounded down)
			total_code_sects = avail_sects - cfg_sects - \
			    ((data_sects > 0) ? data_sects : 0)
			total_code_sects = int(total_code_sects / align) * align
			code_sects = int((total_code_sects / $2) / align) * align
		} else {
			# (rounded up)
			code_sects = roundup(code_sects)
		}

		if (code_sects <= 0) {
			print "Media too small for code partitions" > "/dev/stderr"
			exit 2
		}

		# First code partition
		print_line("freebsd-ufs", code_sects, $11)

		# Second code partition (if any)
		if ($2 > 1) {
			print_line("freebsd-ufs", code_sects, $12)
		}

		# Configuration partition
		print_line("freebsd-ufs", cfg_sects, $13)

		# Data partition (if any)
		if (data_sects > 0) {
			print_line("freebsd-ufs", data_sects, $14)
		} else if (data_sects < 0 && avail_sects > 0) {
			print_line("freebsd-ufs", avail_sects, $14)
		}

		# Overcommit check
		if (avail_sects < 0) {
			print "Disk space overcommitted by", \
			    (avail_sects * -1), "sectors" > "/dev/stderr"
			exit 2
		}
	}' > "${NANO_LOG}/_.partitioning"
}

# Create the code partition image
create_code_partition() {
	pprint 2 "build code partition"
	pprint 3 "log: ${NANO_OBJ}/_.cp"

	(
	local IMG code_sects code_size

	if [ "$NANO_CIDATA_SIZE" -gt 0 ]; then
		mkdir -p "${NANO_WORLDDIR}/boot/msdos"
	fi

	IMG=${NANO_DISKIMGDIR}/${NANO_IMG1NAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	code_size=$(( code_sects * NANO_SECTOR_SIZE ))

	echo "Writing code image..."
	nano_makefs "ffs" "${NANO_MAKEFS} -o minfree=0,optimization=space" \
	    "$NANO_METALOG" "$code_size" "$IMG" "$NANO_WORLDDIR"
	) > "${NANO_OBJ}/_.cp" 2>&1
}

_create_diskimage() {
	create_diskimage
}

# Assemble the final GPT disk image from pre-built partition images using mkimg
create_diskimage() {
	pprint 2 "build diskimage"
	pprint 3 "log: ${NANO_OBJ}/_.di"

	(
	local IMG code_sects code_size cfg_sects cfg_size data_sects data_size
	local bootcode cfg cidata data efiboot0 gptboot0 swap0
	local part_root part_altroot
	local "${NANO_ROOT}" ${NANO_ALTROOT} # XXX NANO_ALTROOT

	IMG=${NANO_DISKIMGDIR}/${NANO_IMGNAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	code_size=$(( code_sects * NANO_SECTOR_SIZE ))
	cfg_sects=$(awk '$5 == "cfg" {print $4}' "${NANO_LOG}/_.partitioning")
	cfg_size=$(( cfg_sects * NANO_SECTOR_SIZE ))
	data_sects=$(awk '$5 == "data" {print $4}' "${NANO_LOG}/_.partitioning")
	data_size=$(( data_sects * NANO_SECTOR_SIZE ))

	# Build mkimg partition entries
	if [ -f "${NANO_WORLDDIR}/boot/pmbr" ]; then
		bootcode="-b ${NANO_WORLDDIR}/boot/pmbr"
	fi

	for image in gptboot0 cidata efiboot0 swap0 \
	    ${NANO_ROOT} ${NANO_ALTROOT} cfg data; do
		match=$(awk -v dir="$NANO_OBJ" -v img="$image" -v ssize="$NANO_SECTOR_SIZE" \
			'$5 == img {
				if ($5 == "swap0") {
					print "-p", $2 "/" $5 "::" ($4 * ssize) ":" ($3 * ssize)
				} else {
					print "-p", $2 "/" $5 ":=" dir "/_." $5 ".image:" ($3 * ssize)
				}
			}' "${NANO_LOG}/_.partitioning")

		if [ -n "$match" ]; then
			eval "${image}=\"\${match}\""
		else
			eval "${image}=\"\""
		fi
	done

	# Use fixed variable names when dealing with code partitions
	eval "part_root=\"\$${NANO_ROOT}\""
	if [ -n "${NANO_ALTROOT}" ]; then
		eval "part_altroot=\"\$${NANO_ALTROOT}\""
	fi

	# Rename root image name to match NANO_IMG1NAME
	part_root=$(echo "$part_root" | sed "s|${NANO_OBJ}/_.${NANO_ROOT}.image|${NANO_DISKIMGDIR}/${NANO_IMG1NAME}|")

	# Create boot partition (if any)
	is_boot_type BIOS && create_boot_partition

	# Create CIDATA partition (if any)
	[ "$NANO_CIDATA_SIZE" -gt 0 ] && create_cidata_partition

	# Create ESP partition (if any)
	is_boot_type UEFI && create_esp_partition

	# Swap partition must be greater than 100 MiB
	if [ "$NANO_SWAP_SIZE" -gt 0 ] &&
	    [ "$NANO_SWAP_SIZE" -lt "$(strtobytes 100MiB)" ]; then
		err "Swap size (${NANO_SWAP_SIZE}) too small (must be > 100 MiB)."
	fi

	# Create secondary code partition (if any)
	if [ "$NANO_IMAGES" -gt 1 ]; then
		if [ "$NANO_INIT_IMG2" -gt 0 ]; then
			echo "Duplicating to second image..."
			tgt_switch_root_fstab "${NANO_ROOT}" "${NANO_ALTROOT}"
			nano_makefs "ffs" "${NANO_MAKEFS} -o minfree=0,optimization=space" \
			    "${NANO_METALOG}" "$code_size" \
			    "${NANO_OBJ}/_.${NANO_ALTROOT}.image" "${NANO_WORLDDIR}"
			tgt_switch_root_fstab "${NANO_ALTROOT}" "${NANO_ROOT}"
		else
			part_altroot=$(echo "$part_altroot" |
			    sed "s#=${NANO_OBJ}/_.${NANO_ALTROOT}.image#:${code_size}#")
		fi
	fi

	# Create cfg partition
	populate_cfg_part "${NANO_OBJ}/_.cfg.image" \
	    "$NANO_CFGDIR" "$NANO_PARTITION_CFG" "$cfg_size" \
	    "$NANO_METALOG_CFG"

	# Create data partition (if any)
	if [ "${NANO_DATASIZE}" -ne 0 ]; then
		populate_data_part "${NANO_OBJ}/_.data.image" \
		    "$NANO_DATADIR" "$NANO_PARTITION_DATA" "$data_size" \
		    "$NANO_METALOG_DATA"
	fi

	echo "Writing out ${NANO_IMGNAME}..."
	mkimg -s gpt -S ${NANO_SECTOR_SIZE} \
	    --capacity ${NANO_MEDIASIZE} \
	    ${bootcode} \
	    ${gptboot0} \
	    ${cidata} \
	    ${efiboot0} \
	    ${swap0} \
	    ${part_root} \
	    ${part_altroot} \
	    ${cfg} \
	    ${data} \
	    -o ${IMG}

	# Cleanup
	rm -f "${NANO_OBJ}/_.gptboot0.image" \
	    "${NANO_OBJ}/_.cidata.image" \
	    "${NANO_OBJ}/_.efiboot0.image" \
	    "${NANO_OBJ}/_.${NANO_ALTROOT}.image" \
	    "${NANO_OBJ}/_.cfg.image" \
	    "${NANO_OBJ}/_.data.image" \
	) > "${NANO_LOG}/_.di" 2>&1
}

#
# Rewrite the root device in the image's fstab files from one GPT label
# to another, used when building the alternate root image.
# Input: $1 = current label (e.g. code1), $2 = new label (e.g. code2)
#
tgt_switch_root_fstab() {
	local current new f

	current="$1"
	new="$2"

	for f in "${NANO_WORLDDIR}/etc/fstab" "${NANO_WORLDDIR}/conf/base/etc/fstab"; do
		[ -f "${f}" ] || continue
		sed -i "" "s=/dev/gpt/${current}=/dev/gpt/${new}=g" "${f}"
	done
}

# Patch gptboot rc script to understand ping-ponging between partitions
tgt_patch_gptboot() {
	(
	cd "$NANO_WORLDDIR"

	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 666 etc/rc.d/gptboot
	if ! patch -s -V none etc/rc.d/gptboot <<\EOF
--- etc/rc.d/gptboot
+++ etc/rc.d/gptboot
@@ -58,6 +58,12 @@
 					# We want to log success after all failures.
 					echo -n "Boot from ${part} succeeded."
 					gpart unset -a bootonce -i ${pos} ${disk} >/dev/null
+					old_bootme=$(gpart show "${disk}" |
+					    egrep 'freebsd-ufs.*(\[|,)bootme(,|\])' | awk '{print $3}')
+					if [ -n "${old_bootme}" ]; then
+						gpart unset -a bootme -i "${old_bootme}" "${disk}" >/dev/null
+					fi
+					gpart set -a bootme -i ${pos} ${disk} >/dev/null
 				fi
 			fi
 			;;
EOF
	then
		err "Patching /etc/rc.d/gptboot failed!"
	fi
	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 555 etc/rc.d/gptboot
	if [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_update_file_sha256 etc/rc.d/gptboot
		tgt_pkg_update_config_files_content etc/rc.d/gptboot
	fi
	)
}

#
# Create a UFS filesystem image from a directory
# Input: $1 = type (cfg/data), $2 = output image path, $3 = source dir,
# $4 = label, $5 = size in bytes, $6 = metalog
#
populate_part() {
	local dir fs lbl metalog size type
	type=$1
	fs=$2
	dir=$3
	lbl=$4
	size=$5
	metalog=$6

	echo "Creating ${fs}"

	# Use the directory provided, otherwise create an empty one temporarily.
	if [ -n "${dir}" ] && [ -d "${dir}" ]; then
		echo "Populating ${lbl} from ${dir}"
	else
		if [ "${type}" = "cfg" ]; then
			dir=$(mktemp -d -p "${NANO_OBJ}" -t "${type}")
			trap "rm -rf ${dir}" 1 2 15 EXIT
		fi
	fi

	if [ -d "${dir}" ]; then
		# If there is no metalog, create one using the default
		# NANO_DEF_UNAME and NANO_DEF_GNAME for all entries in the spec.
		if [ -z "${metalog}" ]; then
			metalog="${NANO_METALOG}.${type}"
			echo "/set type=dir uname=${NANO_DEF_UNAME}" \
			    "gname=${NANO_DEF_GNAME} mode=0755" > "${metalog}"
			echo ". type=dir uname=${NANO_DEF_UNAME}" \
			    "gname=${NANO_DEF_GNAME} mode=0755" >> "${metalog}"
			(
				cd "${dir}"
				mtree -bc -k flags,gid,gname,link,mode,uid,uname |
				    mtree -C | tail -n +2 |
				    sed "s/uid=[[:digit:]]*/uname=${NANO_DEF_UNAME}/g" |
				    sed "s/gid=[[:digit:]]*/gname=${NANO_DEF_GNAME}/g" >> "${metalog}"
			)
		fi

		nano_makefs "ffs" "$NANO_MAKEFS" "$metalog" "$size" "$fs" "$dir"
	fi
}

#
# Thin wrapper around populate_part for creating
# the configuration partition image file
# Input: $1 = image path, $2 = source dir, $3 = label, $4 = size, $5 = metalog
#
populate_cfg_part() {
	populate_part "cfg" "$1" "$2" "$3" "$4" "$5"
}

#
# Thin wrapper around populate_part for creating the data partition image file
# Input: $1 = image path, $2 = source dir, $3 = label, $4 = size, $5 = metalog
#
populate_data_part() {
	populate_part "data" "$1" "$2" "$3" "$4" "$5"
}
