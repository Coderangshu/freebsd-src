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
#   [freebsd-ufs/cfg]             configuration partition
#   [freebsd-ufs/data]            data partition (optional)
#
# "UEFI":
#   [efi/efiboot0]                FAT
#   [freebsd-ufs/${NANO_NAME}1]   root A (read-only)
#   [freebsd-ufs/${NANO_NAME}2]   root B (read-only, A/B updates)
#   [freebsd-ufs/cfg]             configuration partition
#   [freebsd-ufs/data]            data partition (optional)
#
# "BIOS UEFI" (default):
#   [PMBR boot code]              /boot/pmbr
#   [efi/efiboot0]                FAT
#   [freebsd-boot]                /boot/gptboot
#   [freebsd-ufs/${NANO_NAME}1]   root A (read-only)
#   [freebsd-ufs/${NANO_NAME}2]   root B (read-only, A/B updates)
#   [freebsd-ufs/cfg]             configuration partition
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

# Check whether a boot type is present in NANO_BOOT_TYPE
# Input: $1 = boot type to check
# Output: return 0 if found, 1 if not
#
nano_boot_type_is() {
	local needle haystack
	needle=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	haystack=$(printf '%s' "${NANO_BOOT_TYPE}" | tr '[:upper:]' '[:lower:]')
	case " ${haystack} " in
	*" ${needle} "*) return 0 ;;
	*) return 1 ;;
	esac
}

# GPT override: write nanobsd.conf with NANO_DRIVE=gpt/NAME and fstab using GPT partition labels
setup_nanobsd_write_confs() {
	printf 'NANO_DRIVE=gpt/%s\n' "${NANO_NAME}" > etc/nanobsd.conf
	tgt_touch etc/nanobsd.conf

	{
        printf "${FSTAB_FMT}" "# Device" "Mountpoint" "FStype" "Options" "Dump" "Pass#"
        printf "${FSTAB_FMT}" "/dev/gpt/${NANO_NAME}1" "/" "ufs" "ro" "1" "1"
        if nano_boot_type_is UEFI; then
            printf "${FSTAB_FMT}" "/dev/gpt/efiboot0" "/boot/efi" "msdosfs" "rw,noauto" "2" "2"
        fi
        printf "${FSTAB_FMT}" "/dev/gpt/cfg" "/cfg" "ufs" "rw,noauto" "2" "2"
	} | column -t -s $'\t' > etc/fstab
	tgt_touch etc/fstab
}


#
# Create a FAT EFI System Partition image file
# Input: $1 = output file path, $2 = size in bytes, $3 = path to loader.efi
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

	espdir="${NANO_LOG}/_.efi"
	mkdir -p "${espdir}/EFI/BOOT"
    # get_uefi_bootname from "src/tools/boot/install-boot.sh"
	efibootname=$(get_uefi_bootname) 
	cp -p "${loader}" "${espdir}/EFI/BOOT/${efibootname}.efi"
	if [ -d "${espdir}" ]; then
        makefs -t msdos \
            -o fat_type="${fat_type}" \
            -o sectors_per_cluster=1 \
            -o volume_label=EFISYS \
            -o OEM_string="" \
            -s "${fat_size}" \
            "${file}" "${espdir}"
	fi
}

#
# Calculate partition sizes using LBA alignment
# All sizes and offsets are in ssize sectors
# Params: $1=MEDIASIZE(sectors) $2=IMAGES $3=SSIZE(bytes) $4=HAS_PMBR
#         $5=CODESIZE(sectors)  $6=CONFSIZE(sectors) $7=DATASIZE(sectors)
#         $8=EFI_SIZE(bytes)   $9=BOOT_TYPE
#
calculate_partitioning() {
	local _pmbr=0 _has_uefi=0 _has_bios=0
	[ -f "${NANO_WORLDDIR}/boot/pmbr" ] && _pmbr=1
	nano_boot_type_is uefi && _has_uefi=1
	nano_boot_type_is bios && _has_bios=1

	echo $NANO_MEDIASIZE $NANO_IMAGES \
		${NANO_SECTOR_SIZE} $_pmbr \
		$NANO_CODESIZE $NANO_CONFSIZE $NANO_DATASIZE \
		${NANO_EFI_BOOTPART_SIZE} $_has_uefi $_has_bios |
	awk '
	{
		ssize = $3

		# GPT partition entry array: 128 entries x 128 bytes = 16384 bytes
		pe_sects = 16384 / ssize

		# GPT end: backup partition entries + backup GPT header
		gpt_end_sects = pe_sects + 1

		# ESP size in sectors, placed at the 1 MiB alignment boundary
		if ($9) {
			esp_sects = int($8 / ssize)
		} else {
			esp_sects = 0
		}

		# Align to the 1 MiB boundary
		align_start_sects = int((1024 * 1024 + ssize - 1) / ssize)

        # Reserve 1 MiB of physical space for the BIOS boot partition (gptboot)
        if ($10) {
            bios_sects = int(1024 * 1024 / ssize)
        } else {
            bios_sects = 0
        }

        # Code partition(s) start after ESP (or at align_start_sects when no ESP)
		code_start_sects = align_start_sects + esp_sects + bios_sects

		# Usable sectors for code/cfg/data partitions
		usable_sects = $1 - code_start_sects - gpt_end_sects

		# Config and data partition sizes (inputs already in sectors)
		config_slice_sects = $6
		if ($7 > 0) {
			data_slice_sects = $7
		} else {
			data_slice_sects = 0
		}

		# Image partition size in sectors, rounded down to 1 MiB boundary
		if ($5 == 0) {
			raw_slice_sects = int((usable_sects - data_slice_sects - config_slice_sects) / $2)
		} else {
            raw_slice_sects = $5
		}
        image_slice_sects = int(raw_slice_sects / align_start_sects) * align_start_sects

		# Partition index counter
		i = 1

		# ESP partition (if applicable)
		if (esp_sects > 0) {
			print align_start_sects, esp_sects, i
			i++
		}

        # freebsd-boot (BIOS) occupies one GPT slot (not tracked here)
		if ($10) {
			i++
		}

		# First image partition
		print code_start_sects, image_slice_sects, i
		used_sects = code_start_sects + image_slice_sects
		i++

		# Second image partition (if any)
		if ($2 > 1) {
			print used_sects, image_slice_sects, i
			used_sects += image_slice_sects
			i++
		}

		# Config partition
		print used_sects, config_slice_sects, i
		used_sects += config_slice_sects
		i++

        # Data partition (if any)
		total_usable_sects = code_start_sects + usable_sects
		if ($7 > 0) {
			print used_sects, data_slice_sects, i
		} else if ($7 < 0 && total_usable_sects > used_sects) {
			print used_sects, total_usable_sects - used_sects, i
		} else if (total_usable_sects < used_sects) {
			print "Disk space overcommitted by", \
			    used_sects - total_usable_sects, "blocks" > "/dev/stderr"
			exit 2
		}
	}
	' > ${NANO_LOG}/_.partitioning
}

# Create the raw UFS root partition image using makefs
_create_code_slice() {
	pprint 2 "build code slice"
	pprint 3 "log: ${NANO_OBJ}/_.cs"

	(
	local code1_line code_sects code_bytes aligned_bytes makefs_sectors

	if nano_boot_type_is UEFI; then
		code1_line=2
	else
		code1_line=1
	fi

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
    code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	aligned_bytes=$(_xxx_adjust_code_size "${code_bytes}")
	makefs_sectors=$(( aligned_bytes / 512 ))

	echo "Writing code image..."
	nano_makefs "-DxZ ${NANO_MAKEFS} -o minfree=0,optimization=space" \
	    "${NANO_METALOG}" "${makefs_sectors}" "${NANO_OBJ}/_.disk.part" \
	    "${NANO_WORLDDIR}"
	mv "${NANO_OBJ}/_.disk.part" "${NANO_DISKIMGDIR}/_.disk.image"

	) > ${NANO_OBJ}/_.cs 2>&1
}

#
# Assemble the final GPT disk image with optional EFI/BIOS boot partitions,
# root A/B, cfg, and data partitions using mkimg
#
_create_diskimage() {
	pprint 2 "build diskimage"
	pprint 3 "log: ${NANO_OBJ}/_.di"

	(
	local altroot cfgimage dataimage espfile espopts pmbr gptboot img code1_line code_sects \
        code_bytes aligned_bytes makefs_sects first_start_bytes cfg_line cfg_sects \
        data_line data_sects

	if nano_boot_type_is UEFI; then
		code1_line=2
	else
		code1_line=1
	fi

	code_sects=$(awk "NR==${code1_line} {print \$2}" "${NANO_LOG}/_.partitioning")
    code_bytes=$(( code_sects * NANO_SECTOR_SIZE ))
	aligned_bytes=$(_xxx_adjust_code_size "${code_bytes}")
	makefs_sectors=$(( aligned_bytes / 512 ))

    # Always start from 1MiB boundary
    first_start_bytes=$(( ((1024 * 1024 + NANO_SECTOR_SIZE - 1) / NANO_SECTOR_SIZE) * NANO_SECTOR_SIZE ))

	img=${NANO_DISKIMGDIR}/${NANO_IMGNAME}

	espfile=""
	espopts=""
	pmbr=""
	gptboot=""

	# EFI System Partition — for UEFI
	if nano_boot_type_is UEFI; then
		espfile=$(mktemp /tmp/nanobsd-efi.XXXXXX)
		make_esp_file "${espfile}" "${NANO_EFI_BOOTPART_SIZE}" \
		    "${NANO_WORLDDIR}/boot/loader.efi"
		espopts="-p efi/efiboot0:=${espfile}:${first_start_bytes}"
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

	if [ "${NANO_IMAGES}" -gt 1 ] && [ "${NANO_INIT_IMG2}" -gt 0 ]; then
		echo "Duplicating to second image..."
		tgt_switch_root_fstab "${NANO_SLICE_ROOT}" "${NANO_SLICE_ALTROOT}"
		nano_makefs "-DxZ ${NANO_MAKEFS} -o minfree=0,optimization=space" \
		    "${NANO_METALOG}" "${makefs_sectors}" "${NANO_OBJ}/_.altroot.part" \
		    "${NANO_WORLDDIR}"
		tgt_switch_root_fstab "${NANO_SLICE_ALTROOT}" "${NANO_SLICE_ROOT}"
		altroot="-p freebsd-ufs/${NANO_NAME}2:=${NANO_OBJ}/_.altroot.part"
	else
        altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi
	if [ "${NANO_INIT_IMG2}" -eq 0 ]; then
		altroot="-p freebsd-ufs/${NANO_NAME}2::$code_bytes"
	fi

	# cfg/data sizes in _.partitioning are in NANO_SECTOR_SIZE units,
	# _populate_*_part expects 512-byte blocks for nano_makefs
	cfg_line=$(( code1_line + NANO_IMAGES ))
	cfg_sects=$(awk "NR==${cfg_line} {print \$2}" "${NANO_LOG}/_.partitioning")
	_populate_cfg_part "${NANO_OBJ}/_.cfg.part" "${NANO_CFGDIR}" \
	    "${NANO_SLICE_CFG}" "${cfg_sects}" "${NANO_METALOG_CFG}"
	cfgimage="-p freebsd-ufs/cfg:=${NANO_OBJ}/_.cfg.part"

	if [ -n "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_SLICE_CFG}" = "${NANO_SLICE_DATA}" ] &&
	    [ "${NANO_DATASIZE}" -ne 0 ]; then
		pprint 2 "NANO_SLICE_DATA is the same as NANO_SLICE_CFG, fix."
		exit 2
	fi
	if [ "${NANO_DATASIZE}" -ne 0 ] && [ -n "${NANO_SLICE_DATA}" ]; then
		data_line=$(( code1_line + NANO_IMAGES + 1 ))
		data_sects=$(awk "NR==${data_line} {print \$2}" "${NANO_LOG}/_.partitioning")
		_populate_data_part "${NANO_OBJ}/_.data.part" "${NANO_DATADIR}" \
		    "${NANO_SLICE_DATA}" "${data_sects}" "${NANO_METALOG_DATA}"
		dataimage="-p freebsd-ufs/data:=${NANO_OBJ}/_.data.part"
	fi

	echo "Writing out gpt ${NANO_IMGNAME}..."
	mkimg -s gpt -P "${NANO_SECTOR_SIZE}" -C "$((NANO_MEDIASIZE * NANO_SECTOR_SIZE))" \
	    ${pmbr} \
	    ${espopts} \
	    ${gptboot} \
	    -p "freebsd-ufs/${NANO_NAME}1:=${NANO_DISKIMGDIR}/_.disk.image" \
	    ${altroot} \
	    ${cfgimage} \
	    ${dataimage} \
	    -o "${img}"

	[ -n "${espfile}" ] && rm -f "${espfile}"
	rm -f "${NANO_OBJ}/_.altroot.part" \
	    "${NANO_OBJ}/_.cfg.part" \
	    "${NANO_OBJ}/_.data.part"

	) > ${NANO_LOG}/_.di 2>&1
}
