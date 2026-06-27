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

NANO_PLAN=gpt

#
# Space-separated list of boot types; options: BIOS, UEFI (case-insensitive).
# Default enables both.
#
NANO_BOOT_TYPE="BIOS UEFI"

# EFI System Partition size in 512 bytes sectors
NANO_EFI_BOOTPART_SIZE=532480

# Set NANO_LABEL to non-blank to form the basis for using /dev/gpt/code
# in preference to /dev/${NANO_DRIVE}
# Root partition will be /dev/gpt/${NANO_ROOT, NANO_ALTROOT}
# /cfg partition will be /dev/gpt/cfg
# /data partition will be /dev/gpt/data
NANO_LABEL=code
NANO_PARTITION_ROOT=1
NANO_PARTITION_ALTROOT=2
NANO_PARTITION_CFG=cfg
NANO_PARTITION_DATA=data

NANO_ROOT="${NANO_LABEL}${NANO_PARTITION_ROOT}"
NANO_ALTROOT="${NANO_LABEL}${NANO_PARTITION_ALTROOT}"

# Override NANO_DRIVE with NANO_LABEL
if [ -z "${NANO_LABEL}" ]; then
	err "NANO_LABEL must be defined"
fi

NANO_BOOTLOADER="boot/gptboot"

NANO_CUST_FILESDIR="${NANO_TOOLS}/gpt/Files"
NANO_CUST_FILES_MTREE="${NANO_TOOLS}/gpt/Files.mtree"

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

#
# Create a FreeBSD Boot Partition image file of 512 KiB
# Input: $1 = label
#
make_boot_partition() {
	local bootcode name

	name="$1"
	bootcode="${NANO_WORLDDIR}/${NANO_BOOTLOADER}"

	if [ ! -f "$bootcode" ]; then
		echo "Image will not be bootable"
	else
		cp -p "$bootcode" "${NANO_OBJ}/_.${name}.image"
		truncate -s 512k "${NANO_OBJ}/_.${name}.image"
	fi
}

#
# Create an EFI System Partition image file
# Input: $1 = label, $2 = is the recovery ESP?
#
make_esp_partition() {
	local bootcode efibootname espdir fat_size fat_type is_recovery name

	name="$1"
	is_recovery="${2:-}"

	FAT16MIN=2150400
	FAT32MIN=34091008

	esp_sects=$(awk -v label="$name" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	fat_size=$(strsuftoll "${esp_sects:-0}b")
	if [ "$fat_size" -ge "$FAT32MIN" ]; then
		fat_type=32
	elif [ "$fat_size" -ge "$FAT16MIN" ]; then
		fat_type=16
	else
		fat_type=12
	fi

	espdir="${NANO_OBJ}/_.efi"
	rm -rf "${espdir}"

	if [ "$is_recovery" = "recovery" ]; then
		mkdir -p "${espdir}/EFI/BOOT"
	else
		mkdir -p "${espdir}/EFI/FreeBSD"
	fi

	efibootname=$(get_uefi_bootname)
	bootcode="${NANO_WORLDDIR}/$(get_bootcode uefi gpt)"

	if [ ! -f "$bootcode" ]; then
		echo "Image will not be bootable"
	fi

	if [ "$is_recovery" = "recovery" ]; then
		cp -p "${NANO_WORLDDIR}/boot/gptboot.efi" \
		    "${espdir}/EFI/BOOT/${efibootname}.EFI"
	else
		cp -p "$bootcode" "${espdir}/EFI/FreeBSD/loader.efi"
	fi

	makefs -t msdos \
	    -o fat_type="$fat_type" \
	    -o sectors_per_cluster=1 \
	    -o volume_label="$name" \
	    -o OEM_string="" \
	    -s "$fat_size" \
	    -T "$NANO_TIMESTAMP" \
	    "${NANO_OBJ}/_.${name}.image" "${espdir}"

	rm -rf "${espdir}"
}

#
# Calculate partition sizes aligned at 1 MiB boundaries.
# All sizes are in sectors.
# The output is compatible with gpart restore
#
calculate_partitioning() {
	local boot_sects boot_size boot_type esp_sects
	boot_sects=0
	boot_type=0
	esp_sects=0

	if is_boot_type BIOS; then
		boot_type=1
		# Boot partition is exactly 512 KiB
		boot_size=$(strsuftoll 512k)
		boot_sects=$(( boot_size / NANO_SECTOR_SIZE ))
	fi
	is_boot_type UEFI && esp_sects="$NANO_EFI_BOOTPART_SIZE"

	echo "$NANO_MEDIASIZE" "$NANO_IMAGES" "$NANO_SECTOR_SIZE" \
	    "$NANO_CODESIZE" "$NANO_CONFSIZE" "$NANO_DATASIZE" "$boot_type" \
	    "$boot_sects" "$esp_sects" "$NANO_SWAP_SIZE" "$NANO_ROOT" \
	    "$NANO_ALTROOT" "$NANO_PARTITION_CFG" "$NANO_PARTITION_DATA" |
	    awk '
	function roundup(sects) {
		return int((sects + align - 1) / align) * align
	}
	function print_line(type, sects, label,   windex, wtype, wblocks) {
		windex = 3
		wtype = ($7 == 1 || swap_sects > 0) ? length("freebsd-swap") : length("freebsd-ufs")
		wblocks = length($1)

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

		# Align to a 1 MiB boundary in sectors
		align = int((1024 * 1024) / ssize)

		# GPT backup metadata at the end of the disk in sectors
		# (128 entries x 128 bytes + 1 header sector)
		gpt_end_sects = int(16384 / ssize) + 1

		# Boot size in sectors (already rounded up)
		boot_sects = ($8 > 0) ? $8 : 0

		# ESP size in sectors (rounded up)
		esp_sects = ($9 > 0) ? roundup($9) : 0

		# Swap size in sectors (rounded up)
		swap_sects = ($10  > 0) ? roundup($10) : 0

		# Configuration partition size in sectors (rounded up)
		cfg_sects = roundup($5)

		# Data partition size in sectors (rounded up)
		data_sects = ($6 > 0) ? roundup($6) : $6

		# Starting sector (512/4K-bytes aligned)
		sstart = 40

		# Available sectors
		avail_sects = $1 - sstart - gpt_end_sects

		# Print header (scheme and number of entries)
		print "GPT 128"

		# Partition index counter
		i = 1

		# Boot partition (if any)
		if ($7 == 1) {
			print_line("freebsd-boot", boot_sects, "gptboot0")
		}

		# Starting sector (1 MiB aligned)
		avail_sects -= (align - sstart)
		sstart = align

		# ESP partition (if any)
		if (esp_sects > 0) {
			print_line("efi", esp_sects, "efiboot0")
		}

		if (swap_sects > 0) {
			print_line("freebsd-swap", swap_sects, "swap0")
		}

		# Code partition size in sectors
		code_sects = $4
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
	local IMG code_sects

	IMG=${NANO_DISKIMGDIR}/${NANO_IMG1NAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")

	echo "Writing code image..."
	nano_makefs "${NANO_MAKEFS} -o minfree=0,optimization=space" \
	    "$NANO_METALOG" "$code_sects" "$IMG" "$NANO_WORLDDIR"
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
	local IMG code_sects code_size
	local bootcode cfg data efiboot0 gptboot0 swap0
	local code1 "${NANO_ROOT}" code2 "${NANO_ALTROOT}"

	IMG=${NANO_DISKIMGDIR}/${NANO_IMGNAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	code_size=$(( code_sects * NANO_SECTOR_SIZE ))

	# Build mkimg partition entries
	if [ -f "${NANO_WORLDDIR}/boot/pmbr" ]; then
		bootcode="-b ${NANO_WORLDDIR}/boot/pmbr"
	fi

	for image in gptboot0 efiboot0 swap0 \
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
	eval "code1=\"\$${NANO_ROOT}\""
	eval "code2=\"\$${NANO_ALTROOT}\""

	# Rename code1 image name to match NANO_IMG1NAME
	code1=$(echo "$code1" | sed "s|${NANO_OBJ}/_.${NANO_ROOT}.image|${NANO_DISKIMGDIR}/${NANO_IMG1NAME}|")

	# Create boot partition (if any)
	if is_boot_type BIOS; then
		make_boot_partition "gptboot0"
	fi

	# Create ESP partition (if any)
	if is_boot_type UEFI; then
		make_esp_partition "efiboot0" "recovery"
	fi

	# Swap partition must be greater than 100 MiB
	if [ "$NANO_SWAP_SIZE" -gt 0 ] && [ "$NANO_SWAP_SIZE" -lt 104857600 ]; then
		err "Swap size (${NANO_SWAP_SIZE}) too small (must be > 100 MiB)."
	fi

	# Create secondary code partition (if any)
	if [ "$NANO_IMAGES" -gt 1 ]; then
		if [ "$NANO_INIT_IMG2" -gt 0 ]; then
			echo "Duplicating to second image..."
			tgt_switch_root_fstab 1 2
			nano_makefs "${NANO_MAKEFS} -o minfree=0,optimization=space" \
			    "${NANO_METALOG}" "$code_sects" \
			    "${NANO_OBJ}/_.${NANO_ALTROOT}.image" "${NANO_WORLDDIR}"
			tgt_switch_root_fstab 2 1
		else
			code2=$(echo "$code2" |
			    sed "s#=${NANO_OBJ}/_.${NANO_ALTROOT}.image#:${code_size}#")
		fi
	fi

	# Create cfg partition
	populate_cfg_part "${NANO_OBJ}/_.cfg.image" \
	    "$NANO_CFGDIR" "$NANO_PARTITION_CFG" "$NANO_CONFSIZE" \
	    "$NANO_METALOG_CFG"

	# Create data partition (if any)
	if [ "${NANO_DATASIZE}" -ne 0 ]; then
		populate_data_part "${NANO_OBJ}/_.data.image" \
		    "$NANO_DATADIR" "$NANO_PARTITION_DATA" "$DATA_SIZE" \
		    "$NANO_METALOG_DATA"
	fi

	echo "Writing out ${NANO_IMGNAME}..."
	mkimg -s gpt -S ${NANO_SECTOR_SIZE} \
	    --capacity $(( NANO_MEDIASIZE * NANO_SECTOR_SIZE )) \
	    ${bootcode} \
	    ${gptboot0} \
	    ${efiboot0} \
	    ${swap0} \
	    ${code1} \
	    ${code2} \
	    ${cfg} \
	    ${data} \
	    -o ${IMG}

	# Cleanup
	rm -f "${NANO_OBJ}/_.gptboot0.image" \
	    "${NANO_OBJ}/_.efiboot0.image" \
	    "${NANO_OBJ}/_.${NANO_ALTROOT}.image" \
	    "${NANO_OBJ}/_.cfg.image" \
	    "${NANO_OBJ}/_.data.image" \
	) > "${NANO_LOG}/_.di" 2>&1
}

# XXXJL FIXME
tgt_switch_root_fstab() {
	local current new
	current="$1"
	new="$2"

	for f in ${NANO_WORLDDIR}/etc/fstab ${NANO_WORLDDIR}/conf/base/etc/fstab; do
		sed -i "" "s=/dev/gpt/efiboot${current}=/dev/gpt/efiboot${new}=g" "${f}"
		sed -i "" "s=/dev/gpt/${NANO_LABEL}${current}=/dev/gpt/${NANO_LABEL}${new}=g" "${f}"
	done
}
