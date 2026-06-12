#!/bin/sh
#
# Copyright (c) 2026 The FreeBSD Project
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

# GPT disk image functions for nanobsd
# Sourced from nanobsd.sh when NANO_USE_GPT=1, after set_defaults_and_export
# Overrides only the functions from legacy.sh that differ for GPT
#
# Partition layout varies by NANO_BOOT_TYPE:
#
# "BIOS":
#   [PMBR boot code]              /boot/pmbr
#   [freebsd-boot]                /boot/gptboot
#   [freebsd-ufs/${NANO_NAME}1]   root A (read-only)
#   [freebsd-ufs/${NANO_NAME}2]   root B (read-only, A/B updates)
#   [freebsd-ufs/${NANO_NAME}3]   root C backup (optional, when NANO_BACKUP_PART=1)
#   [freebsd-ufs/cfg]             configuration partition
#   [freebsd-swap/swap0]          swap partition (optional)
#   [freebsd-ufs/data]            data partition (optional)
#
# "UEFI":
#   [efi/efiboot0]                FAT (primary, updated with root A/B)
#   [efi/efiboot1]                FAT (immutable backup ESP, written once)
#   [freebsd-ufs/${NANO_NAME}1]   root A (read-only)
#   [freebsd-ufs/${NANO_NAME}2]   root B (read-only, A/B updates)
#   [freebsd-ufs/${NANO_NAME}3]   root C backup (optional, when NANO_BACKUP_PART=1)
#   [freebsd-ufs/cfg]             configuration partition
#   [freebsd-swap/swap0]          swap partition (optional)
#   [freebsd-ufs/data]            data partition (optional)
#
# "BIOS UEFI" (default):
#   [PMBR boot code]              /boot/pmbr
#   [efi/efiboot0]                FAT (primary, updated with root A/B)
#   [efi/efiboot1]                FAT (immutable backup ESP, written once)
#   [freebsd-boot]                /boot/gptboot
#   [freebsd-ufs/${NANO_NAME}1]   root A (read-only)
#   [freebsd-ufs/${NANO_NAME}2]   root B (read-only, A/B updates)
#   [freebsd-ufs/${NANO_NAME}3]   root C backup (optional, when NANO_BACKUP_PART=1)
#   [freebsd-ufs/cfg]             configuration partition
#   [freebsd-swap/swap0]          swap partition (optional)
#   [freebsd-ufs/data]            data partition (optional)

NANO_DRIVE="gpt"
NANO_ROOT="/${NANO_NAME}1"
NANO_ALTROOT="/${NANO_NAME}2"
NANO_SLICE_ROOT="/${NANO_NAME}1"
NANO_SLICE_ALTROOT="/${NANO_NAME}2"
NANO_SLICE_CFG="/cfg"
NANO_SLICE_DATA="/data"

FSTAB_FMT="%s\t\t%s\t%s\t%s\t\t%s\t%s\n"

# install-boot.sh uses TARGET while nanobsd uses NANO_ARCH
case ${NANO_ARCH} in
	aarch64) TARGET=arm64 ;;
	*) TARGET=${NANO_ARCH} ;;
esac
. "${NANO_SRC}/tools/boot/install-boot.sh"

# GPT override: write nanobsd.conf with NANO_DRIVE=gpt/NAME and fstab using GPT partition labels
setup_nanobsd_write_confs() {
	(
	cd "${NANO_WORLDDIR}"
	printf 'NANO_DRIVE=gpt/%s\n' "${NANO_NAME}" > etc/nanobsd.conf

	_root_idx=1
	nano_boot_type_is UEFI && _root_idx=$(( _root_idx + 2 ))
	if nano_boot_type_is BIOS && [ -f "boot/gptboot" ]; then
		_root_idx=$(( _root_idx + 1 ))
	fi
	printf 'NANO_PART_ROOT_IDX=%d\n' "${_root_idx}" >> etc/nanobsd.conf
	printf 'NANO_PART_ALTROOT_IDX=%d\n' "$(( _root_idx + 1 ))" >> etc/nanobsd.conf
	if [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		printf 'NANO_PART_BACKUP_IDX=%d\n' "$(( _root_idx + 2 ))" >> etc/nanobsd.conf
	fi
	tgt_touch etc/nanobsd.conf

	{
        printf "${FSTAB_FMT}" "# Device" "Mountpoint" "FStype" "Options" "Dump" "Pass#"
        printf "${FSTAB_FMT}" "/dev/gpt/${NANO_NAME}1" "/" "ufs" "ro" "1" "1"
        if nano_boot_type_is UEFI; then
            printf "${FSTAB_FMT}" "/dev/gpt/efiboot0" "/boot/efi" "msdosfs" "rw,noauto" "2" "2"
        fi
        printf "${FSTAB_FMT}" "/dev/gpt/cfg" "/cfg" "ufs" "rw,noauto" "2" "2"
        if [ "${NANO_SWAPSIZE}" -ne 0 ]; then
            printf "${FSTAB_FMT}" "/dev/gpt/swap0" "none" "swap" "sw" "0" "0"
        fi
	} | column -t -s $'\t' > etc/fstab
	tgt_touch etc/fstab

	# Both gptboot (BIOS) and gptboot.efi (UEFI) load loader from the selected
	# root partition.  vfs.root.mountfrom must be present in each partition's
	# loader.conf so the loader knows which UFS device to mount as root.
	printf 'vfs.root.mountfrom="ufs:/dev/%s%s"\n' \
	    "${NANO_DRIVE}" "${NANO_SLICE_ROOT}" >> boot/loader.conf
	tgt_touch boot/loader.conf

	# Protect immutable partitions: mode 0440 prevents accidental writes from
	# non-root processes.  efiboot1 is a write-once backup ESP; nanobsd3 is
	# the permanent golden root — neither should be touched by update scripts.
	if nano_boot_type_is UEFI; then
		printf 'perm\tgpt/efiboot1\t0440\n' >> etc/devfs.conf
	fi
	if [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		printf 'perm\tgpt/%s3\t0440\n' "${NANO_NAME}" >> etc/devfs.conf
	fi
	if nano_boot_type_is UEFI || [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		tgt_touch etc/devfs.conf
	fi
	)
}

#
# Create a FAT EFI System Partition image file containing gptboot.efi (or
# loader.efi as fallback).
# Input: $1 = output file path, $2 = size in bytes, $3 = path to EFI binary
#
make_esp_file() {
	local file fat_size loader fat_type efibootname espdir
	local FAT16MIN FAT32MIN
	file=$1
	fat_size=$2
	loader=$3

	FAT16MIN=2150400
	FAT32MIN=34091008

	if [ "$fat_size" -ge "$FAT32MIN" ]; then
		fat_type=32
	elif [ "$fat_size" -ge "$FAT16MIN" ]; then
		fat_type=16
	else
		fat_type=12
	fi

	espdir=$(mktemp -d /tmp/nanobsd-esp.XXXXXX)
	mkdir -p "${espdir}/EFI/BOOT"
	mkdir -p "${espdir}/EFI/FreeBSD"
	# get_uefi_bootname from "src/tools/boot/install-boot.sh"
	efibootname=$(get_uefi_bootname)
	cp -p "${loader}" "${espdir}/EFI/BOOT/${efibootname}.efi"
	makefs -t msdos \
	    -o fat_type="${fat_type}" \
	    -o sectors_per_cluster=1 \
	    -o volume_label=EFISYS \
	    -o OEM_string="" \
	    -s "${fat_size}" \
	    "${file}" "${espdir}"
	rm -rf "${espdir}"
}

#
# Calculate partition sizes using LBA alignment
# All sizes are in sectors (normalized by set_defaults_and_export)
# Params: $1=MEDIASIZE(sectors) $2=IMAGES $3=SSIZE(bytes) $4=CODESIZE(sectors)
#         $5=CONFSIZE(sectors) $6=DATASIZE(sectors) $7=bios(0/1)
#         $8=ESP_SECTS(sectors) $9=SWAPSIZE(sectors) $10=IMAGENAME
#         $11=BACKUP_PART(0/1)
#
calculate_partitioning() {
	local boot_type=0 esp_sects=0 name="${NANO_NAME}"

	nano_boot_type_is BIOS && boot_type=1
	nano_boot_type_is UEFI && esp_sects=$(( NANO_EFI_BOOTPART_SIZE / NANO_SECTOR_SIZE ))

	echo $NANO_MEDIASIZE $NANO_IMAGES \
		$NANO_SECTOR_SIZE $NANO_CODESIZE \
		$NANO_CONFSIZE $NANO_DATASIZE \
		$boot_type $esp_sects $NANO_SWAPSIZE $name ${NANO_BACKUP_PART:-0} |

		awk '
	function roundup(sects) {
		return int((sects + align_sects - 1) / align_sects) * align_sects
	}

	function print_line(sects, type, label) {
		print start_sect, sects, i, type "/" label
		start_sect += sects
		avail_sects -= sects
		i++
	}

	{
		ssize = $3

		# Align to 1 MiB boundary in sectors (min 1 MiB when ssize >= 1 MiB)
		align_sects = int((1024 * 1024) / ssize)
		if (align_sects < 1) align_sects = 1024 * 1024

		# GPT backup metadata at the end of the disk in sectors
		# (128 entries x 128 bytes + 1 backup header sector)
		gpt_end_sects = int(16384 / ssize) + 1

		esp_sects  = ($8  > 0) ? roundup($8)  : 0
		cfg_sects  = roundup($5)
		swap_sects = ($9  > 0) ? roundup($9)  : 0
		data_sects = ($6  > 0) ? roundup($6)  : $6

		i = 1
		start_sect = align_sects
		avail_sects = $1 - start_sect - gpt_end_sects

		# BIOS boot partition marker (no size: placed by mkimg at 1 MiB)
		if ($7 == 1) {
			print "-", "-", i, "freebsd-boot/boot0"
			i++
		}

		# Primary ESP
		if (esp_sects > 0) {
			print_line(esp_sects, "efi", "efiboot0")
		}

		# Secondary ESP — immutable backup, always present when UEFI
		if (esp_sects > 0) {
			print_line(esp_sects, "efi", "efiboot1")
		}

		# Code partition size in sectors
		code_sects = $4
		if (code_sects == 0) {
			# Divide remaining space evenly across images (rounded down)
			total_code_sects = avail_sects - cfg_sects - swap_sects - \
				((data_sects > 0) ? data_sects : 0)
			total_code_sects = int(total_code_sects / align_sects) * align_sects
			code_sects = int((total_code_sects / ($2 + $11)) / align_sects) * align_sects
		} else {
			# Rounded up to alignment
			code_sects = roundup(code_sects)
		}

		print_line(code_sects, "freebsd-ufs", $10 "1")

		if ($2 > 1) {
			print_line(code_sects, "freebsd-ufs", $10 "2")
		}

		# Backup partition C (permanent golden image)
		if ($11 == 1) {
			print_line(code_sects, "freebsd-ufs", $10 "3")
		}

		print_line(cfg_sects, "freebsd-ufs", "cfg")

		if (swap_sects > 0) {
			print_line(swap_sects, "freebsd-swap", "swap0")
		}

		if (data_sects > 0) {
			print_line(data_sects, "freebsd-ufs", "data")
		} else if (data_sects < 0 && avail_sects > 0) {
			print_line(avail_sects, "freebsd-ufs", "data")
		}

		if (avail_sects < 0) {
			print "Disk space overcommitted by", \
				(avail_sects * -1), "sectors" > "/dev/stderr"
			exit 2
		}
	}' > ${NANO_LOG}/_.partitioning
}

#
# Return the line number in _.partitioning of the first code partition
# Lines 1..N are: optional BIOS marker, optional ESP(s), then code partitions
#
_partitioning_code1_line() {
	local line=1
	nano_boot_type_is BIOS && line=$(( line + 1 ))
	if nano_boot_type_is UEFI; then
		line=$(( line + 1 ))   # efiboot0
		line=$(( line + 1 ))   # efiboot1 (always present as immutable backup)
	fi
	echo $line
}

#
# Create the raw UFS root partition image using makefs, building directly
# from NANO_WORLDDIR without a metalog spec.  Used for normal (root) builds.
#
create_code_slice() {
	pprint 2 "build code slice"
	pprint 3 "log: ${NANO_OBJ}/_.cs"

	(
	local code1_line code_sects code_bytes makefs_sects

	code1_line=$(_partitioning_code1_line)

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	makefs_sects=$(( code_bytes / 512 ))

	echo "Writing code image..."
	makefs -t ffs -S "${NANO_UFS_SECTOR_SIZE}" \
	    -Z ${NANO_MAKEFS} -o minfree=0,optimization=space \
	    -N "${NANO_WORLDDIR}/etc" -s "${makefs_sects}b" \
	    -T "${NANO_TIMESTAMP}" \
	    "${NANO_OBJ}/_.disk.part" "${NANO_WORLDDIR}"
	mv "${NANO_OBJ}/_.disk.part" "${NANO_DISKIMGDIR}/_.disk.image"

	) > ${NANO_OBJ}/_.cs 2>&1
}

#
# Create the raw UFS root partition image using makefs with a metalog spec.
# Used for nopriv (-U) source builds where file ownership lives in the metalog.
#
_create_code_slice() {
	pprint 2 "build code slice"
	pprint 3 "log: ${NANO_OBJ}/_.cs"

	(
	local code1_line code_sects code_bytes makefs_sects

	code1_line=$(_partitioning_code1_line)

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	makefs_sects=$(( code_bytes / 512 ))

	echo "Writing code image..."
	nano_makefs "-DxZ ${NANO_MAKEFS} -o minfree=0,optimization=space" \
	    "${NANO_METALOG}" "${makefs_sects}" "${NANO_OBJ}/_.disk.part" \
	    "${NANO_WORLDDIR}"
	mv "${NANO_OBJ}/_.disk.part" "${NANO_DISKIMGDIR}/_.disk.image"

	) > ${NANO_OBJ}/_.cs 2>&1
}

#
# Patch loader.conf + fstab to redirect from_slice → to_slice, invoke the
# provided makefs command (outfile and worlddir are appended as the last two
# args), then restore both files.  Used for altroot and backup image creation.
# Usage: _build_root_image from_slice to_slice outfile makefs_cmd [args...]
#
_build_root_image() {
	local _from="$1" _to="$2" _out="$3"
	shift 3
	tgt_switch_root_fstab "${_from}" "${_to}"
	"$@" "${_out}" "${NANO_WORLDDIR}"
	tgt_switch_root_fstab "${_to}" "${_from}"
}

#
# Stamp initial bootme attributes on a freshly assembled GPT disk image:
#   A (ROOT_IDX)   — bootme: default boot target on first power-on
#   C (BACKUP_IDX) — bootme: permanent golden fallback, never cleared
#
# gptboot.efi scans partitions in index order and boots the first one with
# bootme (or bootonce).  A < B < C in index order, so A wins normally; C
# wins only when both A and B have no bootme and no bootonce (i.e. both
# failed to confirm).
#
# Input: $1 = path to disk image file
#
_stamp_initial_bootme() {
	local _img="$1" _root_idx _bkp_idx _md
	_root_idx=$(awk -F= '/^NANO_PART_ROOT_IDX/{print $2}' \
	    "${NANO_WORLDDIR}/etc/nanobsd.conf")
	[ -n "${_root_idx}" ] || return 0
	_md=$(mdconfig -a -t vnode -f "${_img}")
	gpart set -a bootme -i "${_root_idx}" "${_md}" ||
	    echo "Warning: could not set bootme on A (idx ${_root_idx})"
	if [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		_bkp_idx=$(awk -F= '/^NANO_PART_BACKUP_IDX/{print $2}' \
		    "${NANO_WORLDDIR}/etc/nanobsd.conf")
		if [ -n "${_bkp_idx}" ]; then
			gpart set -a bootme -i "${_bkp_idx}" "${_md}" ||
			    echo "Warning: could not set bootme on C (idx ${_bkp_idx})"
		fi
	fi
	mdconfig -d -u "${_md}"
}

#
# Assemble the final GPT disk image with optional EFI/BIOS boot partitions,
# root A/B, cfg, and data partitions using mkimg.  Builds root images directly
# from NANO_WORLDDIR without a metalog spec.  Used for normal (root) builds.
#
create_diskimage() {
	pprint 2 "build diskimage"
	pprint 3 "log: ${NANO_OBJ}/_.di"

	(
	local altroot backupimage cfgimage dataimage swapimage espfile espopts \
	    espfile2 espopts2 pmbr gptboot img code1_line code_sects \
	    code_bytes makefs_sects first_start_bytes cfg_line cfg_sects \
	    swap_line swap_sects swap_bytes data_line data_sects \
	    _efi_loader

	code1_line=$(_partitioning_code1_line)

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	makefs_sects=$(( code_bytes / 512 ))

	# Always start from 1MiB boundary
	first_start_bytes=$(( ((1024 * 1024 + NANO_SECTOR_SIZE - 1) / NANO_SECTOR_SIZE) * NANO_SECTOR_SIZE ))

	img=${NANO_DISKIMGDIR}/${NANO_IMGNAME}

	espfile=""
	espopts=""
	espfile2=""
	espopts2=""
	pmbr=""
	gptboot=""
	swapimage=""
	backupimage=""

	# EFI System Partition(s) — for UEFI
	# Prefer gptboot.efi (GPT-attribute-based root selection) over loader.efi.
	# efiboot1 is always created as an immutable backup ESP (written once,
	# never updated after initial image creation).
	if nano_boot_type_is UEFI; then
		if [ -f "${NANO_WORLDDIR}/boot/gptboot.efi" ]; then
			_efi_loader="${NANO_WORLDDIR}/boot/gptboot.efi"
		else
			_efi_loader="${NANO_WORLDDIR}/boot/loader.efi"
		fi
		espfile=$(mktemp /tmp/nanobsd-efi.XXXXXX)
		make_esp_file "${espfile}" "${NANO_EFI_BOOTPART_SIZE}" "${_efi_loader}"
		espopts="-p efi/efiboot0:=${espfile}:${first_start_bytes}"
		espfile2=$(mktemp /tmp/nanobsd-efi2.XXXXXX)
		make_esp_file "${espfile2}" "${NANO_EFI_BOOTPART_SIZE}" "${_efi_loader}"
		espopts2="-p efi/efiboot1:=${espfile2}"
	fi

	# PMBR + freebsd-boot — for BIOS
	if nano_boot_type_is BIOS; then
		if [ -f "${NANO_WORLDDIR}/boot/pmbr" ]; then
			pmbr="-b ${NANO_WORLDDIR}/boot/pmbr"
		fi
		if [ -f "${NANO_WORLDDIR}/boot/gptboot" ]; then
			if ! nano_boot_type_is UEFI; then
				gptboot="-p freebsd-boot:=${NANO_WORLDDIR}/boot/gptboot:${first_start_bytes}"
			else
				gptboot="-p freebsd-boot:=${NANO_WORLDDIR}/boot/gptboot"
			fi
		fi
	fi

	local _priv_makefs
	_priv_makefs() {
		makefs -t ffs -S "${NANO_UFS_SECTOR_SIZE}" \
		    -Z ${NANO_MAKEFS} -o minfree=0,optimization=space \
		    -N "${NANO_WORLDDIR}/etc" -s "${makefs_sects}b" \
		    -T "${NANO_TIMESTAMP}" "$@"
	}

	if [ "${NANO_IMAGES}" -gt 1 ] && [ "${NANO_INIT_IMG2}" -gt 0 ]; then
		echo "Duplicating to second image..."
		_build_root_image "${NANO_SLICE_ROOT}" "${NANO_SLICE_ALTROOT}" \
		    "${NANO_OBJ}/_.altroot.part" _priv_makefs
		altroot="-p freebsd-ufs/${NANO_NAME}2:=${NANO_OBJ}/_.altroot.part"
	else
		altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi
	if [ "${NANO_INIT_IMG2}" -eq 0 ]; then
		altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi

	# Backup partition C — permanent golden image, patched loader.conf -> nano3
	if [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		echo "Creating backup image (partition C)..."
		_build_root_image "${NANO_SLICE_ROOT}" "/${NANO_NAME}3" \
		    "${NANO_OBJ}/_.backup.part" _priv_makefs
		backupimage="-p freebsd-ufs/${NANO_NAME}3:=${NANO_OBJ}/_.backup.part"
	fi

	# cfg/swap/data sizes in _.partitioning are in NANO_SECTOR_SIZE units,
	# _populate_*_part expects 512-byte blocks for nano_makefs
	cfg_line=$(( code1_line + NANO_IMAGES + ${NANO_BACKUP_PART:-0} ))
	cfg_sects=$(awk "NR==${cfg_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	_populate_cfg_part "${NANO_OBJ}/_.cfg.part" "${NANO_CFGDIR}" \
	    "${NANO_SLICE_CFG}" "${cfg_sects}" "${NANO_METALOG_CFG}"
	cfgimage="-p freebsd-ufs/cfg:=${NANO_OBJ}/_.cfg.part"

	if [ "${NANO_SWAPSIZE}" -ne 0 ]; then
		swap_line=$(( cfg_line + 1 ))
		swap_sects=$(awk "NR==${swap_line} {print \$2}" "${NANO_LOG}/_.partitioning")
		swap_bytes=$(( swap_sects * NANO_SECTOR_SIZE ))
		swapimage="-p freebsd-swap/swap0::${swap_bytes}"
		data_line=$(( cfg_line + 2 ))
	else
		data_line=$(( cfg_line + 1 ))
	fi

	if [ -n "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_SLICE_CFG}" = "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_DATASIZE}" -ne 0 ]; then
		pprint 2 "NANO_SLICE_DATA is the same as NANO_SLICE_CFG, fix."
		exit 2
	fi
	if [ "${NANO_DATASIZE}" -ne 0 ] && [ -n "${NANO_SLICE_DATA}" ]; then
		data_sects=$(awk "NR==${data_line} {print \$2}" "${NANO_LOG}/_.partitioning")
		_populate_data_part "${NANO_OBJ}/_.data.part" "${NANO_DATADIR}" \
		    "${NANO_SLICE_DATA}" "${data_sects}" "${NANO_METALOG_DATA}"
		dataimage="-p freebsd-ufs/data:=${NANO_OBJ}/_.data.part"
	fi

	echo "Writing out gpt ${NANO_IMGNAME}..."
	mkimg -s gpt -P "${NANO_SECTOR_SIZE}" -C "$((NANO_MEDIASIZE * NANO_SECTOR_SIZE))" \
	    ${pmbr} \
	    ${espopts} \
	    ${espopts2} \
	    ${gptboot} \
	    -p "freebsd-ufs/${NANO_NAME}1:=${NANO_DISKIMGDIR}/_.disk.image" \
	    ${altroot} \
	    ${backupimage} \
	    ${cfgimage} \
	    ${swapimage} \
	    ${dataimage} \
	    -o "${img}"

	_stamp_initial_bootme "${img}"

	[ -n "${espfile}" ] && rm -f "${espfile}"
	[ -n "${espfile2}" ] && rm -f "${espfile2}"
	rm -f "${NANO_OBJ}/_.altroot.part" \
	    "${NANO_OBJ}/_.backup.part" \
	    "${NANO_OBJ}/_.cfg.part" \
	    "${NANO_OBJ}/_.data.part"

	) > ${NANO_LOG}/_.di 2>&1
}

#
# Assemble the final GPT disk image using mkimg with metalog-based root images.
# Used for nopriv (-U) source builds where file ownership lives in the metalog.
#
_create_diskimage() {
	pprint 2 "build diskimage"
	pprint 3 "log: ${NANO_OBJ}/_.di"

	(
	local altroot backupimage cfgimage dataimage swapimage espfile espopts \
	    espfile2 espopts2 pmbr gptboot img code1_line code_sects \
	    code_bytes makefs_sects first_start_bytes cfg_line cfg_sects \
	    swap_line swap_sects swap_bytes data_line data_sects \
	    _efi_loader

	code1_line=$(_partitioning_code1_line)

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	makefs_sects=$(( code_bytes / 512 ))

	# Always start from 1MiB boundary
	first_start_bytes=$(( ((1024 * 1024 + NANO_SECTOR_SIZE - 1) / NANO_SECTOR_SIZE) * NANO_SECTOR_SIZE ))

	img=${NANO_DISKIMGDIR}/${NANO_IMGNAME}

	espfile=""
	espopts=""
	espfile2=""
	espopts2=""
	pmbr=""
	gptboot=""
	swapimage=""
	backupimage=""

	# EFI System Partition(s) — for UEFI
	# Prefer gptboot.efi (GPT-attribute-based root selection) over loader.efi.
	# efiboot1 is always created as an immutable backup ESP (written once,
	# never updated after initial image creation).
	if nano_boot_type_is UEFI; then
		if [ -f "${NANO_WORLDDIR}/boot/gptboot.efi" ]; then
			_efi_loader="${NANO_WORLDDIR}/boot/gptboot.efi"
		else
			_efi_loader="${NANO_WORLDDIR}/boot/loader.efi"
		fi
		espfile=$(mktemp /tmp/nanobsd-efi.XXXXXX)
		make_esp_file "${espfile}" "${NANO_EFI_BOOTPART_SIZE}" "${_efi_loader}"
		espopts="-p efi/efiboot0:=${espfile}:${first_start_bytes}"
		espfile2=$(mktemp /tmp/nanobsd-efi2.XXXXXX)
		make_esp_file "${espfile2}" "${NANO_EFI_BOOTPART_SIZE}" "${_efi_loader}"
		espopts2="-p efi/efiboot1:=${espfile2}"
	fi

	# PMBR + freebsd-boot — for BIOS
	if nano_boot_type_is BIOS; then
		if [ -f "${NANO_WORLDDIR}/boot/pmbr" ]; then
			pmbr="-b ${NANO_WORLDDIR}/boot/pmbr"
		fi
		if [ -f "${NANO_WORLDDIR}/boot/gptboot" ]; then
			if ! nano_boot_type_is UEFI; then
				gptboot="-p freebsd-boot:=${NANO_WORLDDIR}/boot/gptboot:${first_start_bytes}"
			else
				gptboot="-p freebsd-boot:=${NANO_WORLDDIR}/boot/gptboot"
			fi
		fi
	fi

	local _nopriv_makefs
	_nopriv_makefs() {
		nano_makefs "-DxZ ${NANO_MAKEFS} -o minfree=0,optimization=space" \
		    "${NANO_METALOG}" "${makefs_sects}" "$@"
	}

	if [ "${NANO_IMAGES}" -gt 1 ] && [ "${NANO_INIT_IMG2}" -gt 0 ]; then
		echo "Duplicating to second image..."
		_build_root_image "${NANO_SLICE_ROOT}" "${NANO_SLICE_ALTROOT}" \
		    "${NANO_OBJ}/_.altroot.part" _nopriv_makefs
		altroot="-p freebsd-ufs/${NANO_NAME}2:=${NANO_OBJ}/_.altroot.part"
	else
		altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi
	if [ "${NANO_INIT_IMG2}" -eq 0 ]; then
		altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi

	# Backup partition C — permanent golden image, patched loader.conf → nano3
	if [ "${NANO_BACKUP_PART:-0}" -eq 1 ]; then
		echo "Creating backup image (partition C)..."
		_build_root_image "${NANO_SLICE_ROOT}" "/${NANO_NAME}3" \
		    "${NANO_OBJ}/_.backup.part" _nopriv_makefs
		backupimage="-p freebsd-ufs/${NANO_NAME}3:=${NANO_OBJ}/_.backup.part"
	fi

	# cfg/swap/data sizes in _.partitioning are in NANO_SECTOR_SIZE units,
	# _populate_*_part expects 512-byte blocks for nano_makefs
	cfg_line=$(( code1_line + NANO_IMAGES + ${NANO_BACKUP_PART:-0} ))
	cfg_sects=$(awk "NR==${cfg_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	_populate_cfg_part "${NANO_OBJ}/_.cfg.part" "${NANO_CFGDIR}" \
	    "${NANO_SLICE_CFG}" "${cfg_sects}" "${NANO_METALOG_CFG}"
	cfgimage="-p freebsd-ufs/cfg:=${NANO_OBJ}/_.cfg.part"

	if [ "${NANO_SWAPSIZE}" -ne 0 ]; then
		swap_line=$(( cfg_line + 1 ))
		swap_sects=$(awk "NR==${swap_line} {print \$2}" "${NANO_LOG}/_.partitioning")
		swap_bytes=$(( swap_sects * NANO_SECTOR_SIZE ))
		swapimage="-p freebsd-swap/swap0::${swap_bytes}"
		data_line=$(( cfg_line + 2 ))
	else
		data_line=$(( cfg_line + 1 ))
	fi

	if [ -n "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_SLICE_CFG}" = "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_DATASIZE}" -ne 0 ]; then
		pprint 2 "NANO_SLICE_DATA is the same as NANO_SLICE_CFG, fix."
		exit 2
	fi
	if [ "${NANO_DATASIZE}" -ne 0 ] && [ -n "${NANO_SLICE_DATA}" ]; then
		data_sects=$(awk "NR==${data_line} {print \$2}" "${NANO_LOG}/_.partitioning")
		_populate_data_part "${NANO_OBJ}/_.data.part" "${NANO_DATADIR}" \
		    "${NANO_SLICE_DATA}" "${data_sects}" "${NANO_METALOG_DATA}"
		dataimage="-p freebsd-ufs/data:=${NANO_OBJ}/_.data.part"
	fi

	echo "Writing out gpt ${NANO_IMGNAME}..."
	mkimg -s gpt -P "${NANO_SECTOR_SIZE}" -C "$((NANO_MEDIASIZE * NANO_SECTOR_SIZE))" \
	    ${pmbr} \
	    ${espopts} \
	    ${espopts2} \
	    ${gptboot} \
	    -p "freebsd-ufs/${NANO_NAME}1:=${NANO_DISKIMGDIR}/_.disk.image" \
	    ${altroot} \
	    ${backupimage} \
	    ${cfgimage} \
	    ${swapimage} \
	    ${dataimage} \
	    -o "${img}"

	_stamp_initial_bootme "${img}"

	[ -n "${espfile}" ] && rm -f "${espfile}"
	[ -n "${espfile2}" ] && rm -f "${espfile2}"
	rm -f "${NANO_OBJ}/_.altroot.part" \
	    "${NANO_OBJ}/_.backup.part" \
	    "${NANO_OBJ}/_.cfg.part" \
	    "${NANO_OBJ}/_.data.part"

	) > ${NANO_LOG}/_.di 2>&1
}

# GPT override: cust_install_files installs GPT-aware update scripts instead
# of the MBR variants.
cust_install_files() (
	cd "${NANO_TOOLS}/Files"
	find . -print | grep -Ev '/(CVS|\.svn|\.hg|\.git)/|/updatep[12]\.(gpt|mbr)$' |
	    cpio ${CPIO_SYMLINK} -Ldumpv ${NANO_WORLDDIR}

	if [ -n "${NANO_CUST_FILES_MTREE}" -a -f ${NANO_CUST_FILES_MTREE} ]; then
		CR "mtree -eiU -p /" <${NANO_CUST_FILES_MTREE}
	fi

	tgt_touch $(find * -type f | grep -Ev '^root/updatep[12]\.(gpt|mbr)$')

	install -m 755 "${NANO_TOOLS}/Files/root/updatep1.gpt" \
	    "${NANO_WORLDDIR}/root/updatep1"
	install -m 755 "${NANO_TOOLS}/Files/root/updatep2.gpt" \
	    "${NANO_WORLDDIR}/root/updatep2"
	tgt_touch root/updatep1 root/updatep2
)
