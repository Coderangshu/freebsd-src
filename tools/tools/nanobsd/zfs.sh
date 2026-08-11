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
# Space-separated list of boot types; options: BIOS, UEFI (case-insensitive).
# Default enables both.
#
NANO_BOOT_TYPE="BIOS UEFI"

NANO_ZFSBOOT_POOL_NAME="zroot"

# Set NANO_LABEL to non-blank to form the basis for using /dev/gpt/${NANO_ROOT}
# in preference to /dev/${NANO_DRIVE}
# Root dataset will be ${NANO_ZFSBOOT_POOL_NAME}/ROOT/default
NANO_LABEL=zfs
NANO_PARTITION_ROOT=0
NANO_PARTITION_CFG="${NANO_ZFSBOOT_POOL_NAME}/cfg"

NANO_ROOT="${NANO_LABEL}${NANO_PARTITION_ROOT}"

if [ "$NANO_IMAGES" -gt 1 ]; then
	NANO_PARTITION_ALTROOT=2
	NANO_ALTROOT="${NANO_LABEL}${NANO_PARTITION_ALTROOT}"
fi

# Override NANO_DRIVE with NANO_LABEL
if [ -z "${NANO_LABEL}" ]; then
	err "NANO_LABEL must be defined"
fi

NANO_BOOTLOADER="boot/gptzfsboot"

NANO_ALIGN="${NANO_ALIGN:-1MiB}"

# makefs parameters to use
NANO_MAKEFS="-o poolname=${NANO_ZFSBOOT_POOL_NAME} \
	-o bootfs=${NANO_ZFSBOOT_POOL_NAME}/ROOT/default \
	-o rootpath=/ \
	-o path=/dev/gpt/${NANO_ROOT} \
	-o fs=${NANO_ZFSBOOT_POOL_NAME};atime=off;compression=lz4;mountpoint=none \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/ROOT;mountpoint=none \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/ROOT/default;mountpoint=/;canmount=noauto;readonly=on \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/home;mountpoint=/home \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/tmp;mountpoint=/tmp;exec=on;setuid=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/usr;mountpoint=/usr;canmount=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/usr/ports;setuid=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/usr/src \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/usr/obj \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var;mountpoint=/var;canmount=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var/audit;setuid=off;exec=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var/crash;setuid=off;exec=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var/log;setuid=off;exec=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var/mail;atime=on \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/var/tmp;setuid=off \
	-o fs=${NANO_ZFSBOOT_POOL_NAME}/cfg;mountpoint=legacy;exec=off;setuid=off"

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
	printf_fstab "${NANO_PARTITION_CFG}" /cfg zfs rw,noauto 0 0
	if [ "$NANO_SWAP_SIZE" -gt 0 ]; then
		if [ -n "$NANO_SWAP_ENCRYPTION" ]; then
			printf_fstab "/dev/gpt/swap0.eli" none swap sw 0 0
		else
			printf_fstab "/dev/gpt/swap0" none swap sw 0 0
		fi
	fi

	tgt_touch etc/fstab

	echo 'zfs_enable="YES"' >> etc/defaults/rc.conf
	echo "zpool_reguid=\"${NANO_ZFSBOOT_POOL_NAME}\"" >> etc/defaults/rc.conf
	echo "zpool_upgrade=\"${NANO_ZFSBOOT_POOL_NAME}\"" >> etc/defaults/rc.conf
	echo 'zfs_bootonce_activate="YES"' >> etc/defaults/rc.conf
	echo "kern.geom.label.disk_ident.enable=0" >> boot/defaults/loader.conf
	echo 'zfs_load="YES"' >> boot/defaults/loader.conf
	)
}

# Pick up config files from the special partition
tgt_etc_remount() {
	(
	cd "$NANO_WORLDDIR"

	echo "mount -o ro -t zfs ${NANO_PARTITION_CFG}" > conf/default/etc/remount
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
make_boot_partition() {
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
make_esp_partition() {
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
	bootcode="${NANO_WORLDDIR}/$(get_bootcode uefi zfs)"

	if [ ! -f "$bootcode" ]; then
		echo "Image will not be bootable"
	fi

	cp -p "$bootcode" "${espdir}/EFI/BOOT/${efibootname}.EFI"

	# XXXJL it needs a volume_label, otherwise, it fails!
	makefs -t msdos \
	    -o fat_type="$fat_type" \
	    -o sectors_per_cluster=1 \
	    -o volume_label="EFISYS" \
	    -o OEM_string="" \
	    -s "${esp_sects}b" \
	    -T "$NANO_TIMESTAMP" \
	    "${NANO_OBJ}/_.efiboot0.image" "$espdir"

	rm -rf "$espdir"
}

# Create an MS Basic Data Partition for nuageinit (cidata)
make_cidata_partition() {
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

	echo "$NANO_MEDIASIZE" "REMOVE" "$NANO_SECTOR_SIZE" \
	    "$NANO_CODESIZE" "REMOVE" "REMOVE" "$boot_type" \
	    "$boot_sects" "$esp_sects" "$NANO_SWAP_SIZE" "$NANO_ROOT" \
	    "REMOVE" "REMOVE" "REMOVE" \
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
			wtype = "freebsd-zfs"
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

		if (swap_sects > 0) {
			print_line("freebsd-swap", swap_sects, "swap0")
		}

		# Code partition size in sectors
		code_sects = int($4 / ssize)
		if (code_sects == 0) {
			# rounded down
			code_sects = int(avail_sects / align) * align
		} else {
			# rounded up
			code_sects = roundup(code_sects)
		}

		# First code partition
		print_line("freebsd-zfs", code_sects, $11)

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

	# XXXJL can we normalize the naming? create_esp_partition, create_cidata_partition, etc.
	# XXXJL this does not belong here
	if [ "$NANO_CIDATA_SIZE" -gt 0 ]; then
		mkdir -p "${NANO_WORLDDIR}/boot/msdos"
	fi

	# XXXJL how do we populate_cfg_dataset()?
	# XXXJL NANO_METALOG_CFG
	mkdir -p "${NANO_WORLDDIR}/cfg"
	cp -a "${NANO_CFGDIR}/"* "${NANO_WORLDDIR}/cfg"

	cp /usr/src/libexec/nuageinit/nuageinit "${NANO_WORLDDIR}/usr/libexec/nuageinit"
	cp /usr/src/libexec/rc/rc.d/nuageinit "${NANO_WORLDDIR}/etc/rc.d/nuageinit"

	IMG=${NANO_DISKIMGDIR}/${NANO_IMG1NAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	code_size=$(( code_sects * NANO_SECTOR_SIZE ))

	# XXXJL Ideally we ship with a golden boot environment (default) and generate a diff against that
	#       for delta upgrades
	echo "Writing code image..."
	nano_makefs "zfs" "$NANO_MAKEFS" \
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
	local IMG code_sects code_size
	local bootcode cidata efiboot0 gptboot0 swap0
	local code "${NANO_ROOT}"

	IMG=${NANO_DISKIMGDIR}/${NANO_IMGNAME}
	code_sects=$(awk -v label="$NANO_ROOT" '$5 == label {print $4}' "${NANO_LOG}/_.partitioning")
	code_size=$(( code_sects * NANO_SECTOR_SIZE ))

	# Build mkimg partition entries
	if [ -f "${NANO_WORLDDIR}/boot/pmbr" ]; then
		bootcode="-b ${NANO_WORLDDIR}/boot/pmbr"
	fi

	for image in gptboot0 cidata efiboot0 swap0 ${NANO_ROOT}; do
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
	eval "code=\"\$${NANO_ROOT}\""

	# Rename code image name to match NANO_IMG1NAME
	code=$(echo "$code" | sed "s|${NANO_OBJ}/_.${NANO_ROOT}.image|${NANO_DISKIMGDIR}/${NANO_IMG1NAME}|")

	# Create boot partition (if any)
	is_boot_type BIOS && make_boot_partition

	# Create CIDATA partition (if any)
	[ "$NANO_CIDATA_SIZE" -gt 0 ] && make_cidata_partition

	# Create ESP partition (if any)
	is_boot_type UEFI && make_esp_partition

	# Swap partition must be greater than 100 MiB
	if [ "$NANO_SWAP_SIZE" -gt 0 ] &&
	    [ "$NANO_SWAP_SIZE" -lt "$(strtobytes 100MiB)" ]; then
		err "Swap size (${NANO_SWAP_SIZE}) too small (must be > 100 MiB)."
	fi

	echo "Writing out ${NANO_IMGNAME}..."
	mkimg -s gpt -S ${NANO_SECTOR_SIZE} \
	    --capacity ${NANO_MEDIASIZE} \
	    ${bootcode} \
	    ${gptboot0} \
	    ${cidata} \
	    ${efiboot0} \
	    ${swap0} \
	    ${code} \
	    -o ${IMG}

	# Cleanup
	rm -f "${NANO_OBJ}/_.gptboot0.image" \
	    "${NANO_OBJ}/_.cidata.image" \
	    "${NANO_OBJ}/_.efiboot0.image" \
	) > "${NANO_LOG}/_.di" 2>&1
}
