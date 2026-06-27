#!/bin/sh
#
# Copyright (c) 2005 Poul-Henning Kamp.
# All rights reserved.
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

#######################################################################
#
# Setup default values for all controlling variables.
# These values can be overridden from the config file(s)
#
#######################################################################

# Name of this NanoBSD build.  (Used to construct workdir names)
NANO_NAME=full

# Source tree directory
NANO_SRC=/usr/src

# Where nanobsd additional files live under the source tree
NANO_TOOLS=tools/tools/nanobsd

# Where cust_pkgng() finds packages to install
NANO_PACKAGE_DIR=${NANO_SRC}/${NANO_TOOLS}/Pkg
NANO_PACKAGE_LIST="*"

# where package metadata gets placed
NANO_PKG_META_BASE=/var/db

# Path to the files directory used by cust_install_files()
NANO_CUST_FILESDIR="${NANO_TOOLS}/Files"
# Path to mtree file to apply to anything copied by cust_install_files().
# If you specify this, the mtree file *must* have an entry for every file and
# directory located in Files
#NANO_CUST_FILES_MTREE=""

# Use the time of the last commit as a timestamp when doing a NO_PRIV build
NANO_TIMESTAMP=$(git log -1 --format=%ct || true)

# Object tree directory
# default is subdir of /usr/obj
#NANO_OBJ=""

# The directory to put the final images
# default is ${NANO_OBJ}
#NANO_DISKIMGDIR=""

# Make & parallel Make
NANO_MAKE="make"
NANO_NCPU=$(sysctl -n hw.ncpu)

# The default name for any image we create
NANO_IMGNAME="_.disk.${NANO_NAME}"
NANO_IMG1NAME="_.disk.image"

# Options to put in make.conf during buildworld only
CONF_BUILD=' '

# Options to put in make.conf during installworld only
CONF_INSTALL=' '

# Options to put in make.conf during both build- & installworld
CONF_WORLD='
WITHOUT_DEBUG_FILES=true
WITHOUT_LIB32=true
WITHOUT_KERNEL_SYMBOLS=true
WITHOUT_TESTS=true
'

# Kernel config file to use
NANO_KERNEL=GENERIC

# Kernel modules to install. If empty, no modules are installed.
# Use "default" to install all built modules
NANO_MODULES=

# Early customize commands
NANO_EARLY_CUSTOMIZE=""

# Customize commands
NANO_CUSTOMIZE=""

# Late customize commands
NANO_LATE_CUSTOMIZE=""

# makefs parameters to use
NANO_MAKEFS="-o softupdates=1,version=2"

# The drive name of the media at runtime
NANO_DRIVE=ada0

#
# Sector size in bytes.
# Accepts suffixes and products (4k, 1M, 4x1024)
#
NANO_SECTOR_SIZE=512

# Target media size in 512 bytes sectors
NANO_MEDIASIZE=4000000

# Number of code images on media (1 or 2)
NANO_IMAGES=2

#
# 0 -> Leave second image all zeroes so it compresses better.
# 1 -> Initialize second image with a copy of the first
#
NANO_INIT_IMG2=1

#
# Size of code file system in 512 bytes sectors.
# If zero, size will be as large as possible
#
NANO_CODESIZE=0

# Size of configuration file system in 512 bytes sectors.
# Cannot be zero
NANO_CONFSIZE=2048

# Size of data file system in 512 bytes sectors.
# If zero: no partition configured.
# If negative: max size possible
NANO_DATASIZE=0

# Size of the /etc ramdisk in 512 bytes sectors
NANO_RAM_ETCSIZE=10240

# Size of the /tmp+/var ramdisk in 512 bytes sectors
NANO_RAM_TMPVARSIZE=81920

# Size of swap partition in 512 bytes sectors
NANO_SWAP_SIZE=0

# Swap partition encryption
NANO_SWAP_ENCRYPTION=

# boot2 flags/options
# default force serial console
NANO_BOOT2CFG="-h -S115200"

# Backing type of md(4) device
# Can be "file" or "swap"
NANO_MD_BACKING="file"

# for swap type md(4) backing, write out the mbr only
NANO_IMAGE_MBRONLY=true

# Progress Print level
PPLEVEL=3

# Default ownership for nopriv build
NANO_DEF_UNAME=root
NANO_DEF_GNAME=wheel

#######################################################################
# Architecture to build.  Corresponds to TARGET_ARCH in a buildworld.
# Unfortunately, there's no way to set TARGET at this time, and it
# conflates the two, so architectures where TARGET != TARGET_ARCH and
# TARGET can't be guessed from TARGET_ARCH do not work.  This defaults
# to the arch of the current machine
NANO_ARCH=$(uname -p)

# CPUTYPE defaults to "" which is the default when CPUTYPE isn't defined
NANO_CPUTYPE=""

# Directory to populate /cfg from
NANO_CFGDIR=""
NANO_METALOG_CFG=""

# Directory to populate /data from
NANO_DATADIR=""
NANO_METALOG_DATA=""

# We don't need SRCCONF or SRC_ENV_CONF. NanoBSD puts everything we
# need for the build in files included with __MAKE_CONF. Override in your
# config file if you really must. We set them unconditionally here, though
# in case they are stray in the build environment
SRCCONF=/dev/null
SRC_ENV_CONF=/dev/null

# Comment this out if /usr/obj is a symlink
# CPIO_SYMLINK=--insecure

#######################################################################
# Distribution Set variables and functions
#

# The default mirror for downloading distribution sets
# See: https://docs.freebsd.org/en/books/handbook/mirrors/
NANO_MIRROR="https://download.freebsd.org"
NANO_BRANCH=$(sed -n '/^BRANCH=/{s,.*=,,;s,",,g;s,-.*,,;p;}' ${NANO_SRC}/sys/conf/newvers.sh)
NANO_REVISION=$(sed -n '/^REVISION=/{s,.*=,,;s,",,g;p;}' ${NANO_SRC}/sys/conf/newvers.sh)
# The set of distributions to install
# See bsdinstall(8) DISTRIBUTIONS for a reference
NANO_DISTRIBUTIONS="base.txz kernel.txz"

#
# Check whether a distribution name is present in NANO_DISTRIBUTIONS
# Input: $1 = distribution name to check
# Output: returns 0 if found, 1 if not
#
nano_distributions_contains() {
	case " ${NANO_DISTRIBUTIONS} " in
	*"$1"*) return 0 ;;
	*) return 1 ;;
	esac
}

# Map NANO_BRANCH to the directory used by FreeBSD download URLs
nano_distset_reldir() {
	case ${NANO_BRANCH} in
	ALPHA*|CURRENT|STABLE|PRERELEASE) echo "snapshots" ;;
	*) echo "releases" ;;
	esac
}

# Map NANO_ARCH to the platform/arch format used by FreeBSD download URLs
nano_distset_arch() {
	case "$NANO_ARCH" in
	aarch64)     echo "arm64/aarch64" ;;
	amd64)       echo "amd64/amd64" ;;
	powerpc64)   echo "powerpc/powerpc64" ;;
	powerpc64le) echo "powerpc/powerpc64le" ;;
	riscv64)     echo "riscv/riscv64" ;;
	*)           err "Unsupported NANO_ARCH '${NANO_ARCH}'" ;;
	esac
}

# Build the local cache directory path where distribution tarballs are stored
nano_distset_dir() {
	echo "${NANO_OBJ}/_.cache/$(nano_distset_reldir)/$(nano_distset_arch)/${NANO_REVISION}-${NANO_BRANCH}"
}

#
# Build the remote download URL for distribution tarballs,
# handling both ftp and https mirror formats
#
nano_distset_url() {
	local site

	case "$NANO_MIRROR" in
	*ftp*)
		site="${NANO_MIRROR}/pub/FreeBSD"
		;;
	*)
		site="$NANO_MIRROR"
		;;
	esac

	echo "${site}/$(nano_distset_reldir)/$(nano_distset_arch)/${NANO_REVISION}-${NANO_BRANCH}"
}

#
# Download tarballs from the FreeBSD mirror and
# verify their SHA256 checksums against MANIFEST
#
nano_fetch_distsets() {
	pprint 2 "fetch distribution sets"
	pprint 3 "log: ${NANO_LOG}/_.ds"

	if [ ! -d "$NANO_LOG" ]; then
		mkdir -p "$NANO_LOG"
	fi

	(
	if [ -z "$NANO_DISTRIBUTIONS" ]; then
		err "NANO_DISTRIBUTIONS variable is not set"
	fi
	nano_distributions_contains " base.txz " || err "base.txz is mandatory"
	nano_distributions_contains " kernel.txz " || err "kernel.txz is mandatory"

	if $do_clean; then
		rm -rf "${NANO_OBJ}/_.cache"
	else
		pprint 2 "Using existing distributions (as instructed)"
	fi

	if [ ! -d "$(nano_distset_dir)" ]; then
		mkdir -p "$(nano_distset_dir)"
	fi

	if [ ! -f "$(nano_distset_dir)/MANIFEST" ]; then
		echo "Downloading MANIFEST"
		if ! fetch -o "$(nano_distset_dir)" "$(nano_distset_url)/MANIFEST"; then
			err "Failed to download $(nano_distset_url)/MANIFEST"
		fi
	fi

	for distset in $NANO_DISTRIBUTIONS; do
		if [ ! -f "$(nano_distset_dir)/${distset}" ]; then
			echo "Downloading ${distset}"
			if ! fetch -o "$(nano_distset_dir)/${distset}" "$(nano_distset_url)/${distset}"; then
				err "Failed to download $(nano_distset_url)/${distset}"
			fi
		fi
	done

	if [ -f "$(nano_distset_dir)/MANIFEST" ]; then
		for distset in $NANO_DISTRIBUTIONS; do
			if [ -f "$(nano_distset_dir)/${distset}" ]; then
				echo "Checksumming ${distset}"
				expected=$(awk "/${distset}/ { print \$2 }" "$(nano_distset_dir)/MANIFEST")
				current=$(sha256 -q "$(nano_distset_dir)/${distset}")
				if [ -z "$expected" ]; then
					err "Invalid distribution set '${distset}'"
				fi
				if [ "$current" != "$expected" ]; then
					err "${distset} checksum mismatch"
				fi
			else
				err "Invalid distribution set '${distset}'"
			fi
		done
	fi
	) > "${NANO_LOG}/_.ds" 2>&1
}

#
# Apply freebsd-update patches to precompiled distribution binaries
# Distribution Sets are not patched, use the same logic from poudriere(8)
#
patch_precompiled() {
	pprint 2 "patch distribution set binaries"
	pprint 3 "log: ${NANO_LOG}/_.pds"

	(
	# Fix freebsd-update to not check for TTY and to allow
	# EOL branches to still get updates
	fu_bin="$(mktemp -t freebsd-update)"
	trap 'rm -rf "${fu_bin}"' 1 2 15 EXIT
	sed \
	    -e 's/! -t 0/1 -eq 0/' \
	    -e 's/-t 0/1 -eq 1/' \
	    -e 's,\(fetch_warn_eol ||\) return 1,\1 :,' \
	    -e 's,sysctl -n kern.bootfile,echo /boot/kernel/kernel,' \
	    -e 's,service sshd restart,#service sshd restart,' \
	    /usr/sbin/freebsd-update > "${fu_bin}"
	if ! $do_root; then
		# Patch freebsd-update(8) to avoid checking if the user is root
		# and setting ownership/permissions on install(1)
		# while keeping the INDEX-NEW file, which will be appended to
		# the metalog once it is converted to mtree(8) format
		sed -i "" \
		    -e 's/\[ $(id -u) != 0 \]/false/g' \
		    -e 's/-o ${OWNER} -g ${group}/-U/g' \
		    -e 's/-m ${PERM}//g' \
		    -e "s,fetch_inspect_system INDEX-OLD INDEX-PRESENT INDEX-NEW || return 1,cp INDEX-NEW ${NANO_METALOG}.pds; fetch_inspect_system INDEX-OLD INDEX-PRESENT INDEX-NEW || return 1,g" \
		    "${fu_bin}"
	fi
	FREEBSD_UPDATE="env PAGER=/bin/cat"
	FREEBSD_UPDATE="${FREEBSD_UPDATE} /bin/sh ${fu_bin}"
	fu_basedir="${NANO_WORLDDIR}"
	FREEBSD_UPDATE="${FREEBSD_UPDATE} -b ${fu_basedir}"
	fu_workdir="${NANO_OBJ}/_.cache/freebsd-update"
	mkdir -p "$fu_workdir"
	FREEBSD_UPDATE="${FREEBSD_UPDATE} -d ${fu_workdir}"
	FREEBSD_UPDATE="${FREEBSD_UPDATE} --currently-running ${NANO_REVISION}-${NANO_BRANCH}"
	FREEBSD_UPDATE="${FREEBSD_UPDATE} -f ${NANO_WORLDDIR}/etc/freebsd-update.conf"

	if ${FREEBSD_UPDATE} fetch; then
		yes | ${FREEBSD_UPDATE} install
	fi

	if ! $do_root && [ -f "${NANO_METALOG}.pds" ]; then
		# Convert our copy of INDEX-NEW from freebsd-update
		# to an mtree(8) format and append it to the metalog
		${NANO_TOOLS}/freebsd-update-index-to-mtree.awk \
		    "${NANO_METALOG}.pds" >> "$NANO_METALOG"
		rm -f "${NANO_METALOG}.pds"
	fi

	set -o xtrace

	# Remove old kernel
	tgt_rm boot/kernel.old

	_xxx_remove_extra_dist_files
	) > "${NANO_LOG}/_.pds" 2>&1
}

# Generate the METALOG from the distribution tarballs
nano_distset_metalog() {
	rm -f "$NANO_METALOG"

	for distset in $NANO_DISTRIBUTIONS; do
		tar -cf - --format=mtree \
		    --options='!uid,!gid,!nlink,!size,!time' \
		    @"$(nano_distset_dir)/${distset}" \
		    2>/dev/null >> "$NANO_METALOG"
	done
	_xxx_libarchive_mtree_bug
}

#######################################################################
# freebsd-base(7) (pkgbase) variables and functions
#

# Use pkgbase.  If empty, pkgbase will be used
NANO_NOPKGBASE=

NANO_ABI=$(pkg config ABI)
NANO_OSVERSION=$(pkg config OSVERSION)
NANO_PKGBASE_DIR="base_latest"
NANO_PORTS_DIR="latest"
NANO_PKGBASE_LIST="FreeBSD-set-base FreeBSD-kernel-generic"

#
# Check whether a package name is present in NANO_PKGBASE_LIST
# Input: $1 = package name to check
# Output: return 0 if found, 1 if not
#
nano_pkgbase_list_contains() {
	case " $NANO_PKGBASE_LIST " in
	*"$1"*) return 0 ;;
	*) return 1 ;;
	esac
}

#
# Return NANO_PKGBASE_LIST by build target
# Input: $1 = build target (optional "world" or "kernel")
#
nano_pkgbase_list() {
	local list package target

	target="$1"
	list=""

	[ "$target" = "world" ] || [ -z "$target" ] && list="pkg"

	for package in $NANO_PKGBASE_LIST; do
		case "$package" in
		FreeBSD-kernel-*)
			{ [ "$target" = "kernel" ] || [ -z "$target" ]; } &&
			list="${list}${list:+ }$package"
			;;
		*)
			{ [ "$target" = "world" ] || [ -z "$target" ]; } &&
			list="${list}${list:+ }$package"
			;;
		esac
	done

	echo "$list"
}

# Return the non-kernel subset of NANO_PKGBASE_LIST plus "pkg"
nano_pkgbase_world_list() {
	nano_pkgbase_list "world"
}

# Return the kernel subset of NANO_PKGBASE_LIST
nano_pkgbase_kernel_list() {
	nano_pkgbase_list "kernel"
}

# Remove the existing NANO_METALOG file to generate new metalog
nano_pkgbase_reset_metalog() {
	rm -f "$NANO_METALOG"
}

#
# Update the sha256 checksum of a file in the target pkg database
# to match the current file on disk
# Input: $1 = file path relative to NANO_WORLDDIR
#
tgt_pkg_update_file_sha256() {
	local file sha256

	file="${NANO_WORLDDIR}/${1}"

	if [ -f "$file" ]; then
		sha256=$(sha256 -q "${file}")
		tgt_pkg shell "UPDATE files SET sha256 = '1\$${sha256}' WHERE path = '/${1}';"
	else
		err "File ${file} not found"
	fi
}

#
# Update the content value in the config_files table of the target pkg database.
# All paths are relative to NANO_WORLDDIR
#
tgt_pkg_update_config_files_content() {
	local escaped_file file

	file="${NANO_WORLDDIR}/${1}"
	# We need to escape single quotes and avoid $(...)
	# from removing newlines at EOF
	escaped_file=$(sed "s/'/''/g" "$file"; printf 'EOF')
	escaped_file=${escaped_file%EOF}

	if [ -f "$file" ]; then
		tgt_pkg shell "UPDATE config_files SET content = '$escaped_file' WHERE path = '/${1}';"
	else
		err "File ${file} not found"
	fi
}

#
# Swap the dir ID with the symlink ID in the pkg_directories table.
# Remove the dir ID from the directories table
#
tgt_pkg_rm_dir2symlink() {
	local dir dir_id realpath_target symlink symlink_id update_stmt

	dir="$1"
	symlink="$2"

	# Resolve the symlink's target destination to query the database
	realpath_target=$(realpath -q "${NANO_WORLDDIR}/${dir}/../${symlink}")
	realpath_target="${realpath_target#$NANO_WORLDDIR}"

	if [ -n "$realpath_target" ]; then
		symlink_id=$(tgt_pkg shell "SELECT id FROM directories
		    WHERE path = '${realpath_target}';")
	fi
	dir_id=$(tgt_pkg shell "SELECT id FROM directories
	    WHERE path = '/${dir}';")
	if [ -z "$dir_id" ]; then
		return 0
	fi

	# Change any package relation from the dir ID to the symlink ID (if any)
	if [ -n "$symlink_id" ]; then
		update_stmt="UPDATE OR IGNORE pkg_directories
		    SET directory_id = ${symlink_id}
		    WHERE directory_id = ${dir_id};"
	else
		update_stmt="-- Skip UPDATE: symlink_id is empty"
	fi

	tgt_pkg shell <<-EOF
		BEGIN TRANSACTION;

		${update_stmt}

		-- Remove residual dir ID remnants left behind by "OR IGNORE"
		DELETE FROM pkg_directories WHERE directory_id = ${dir_id};

		-- Remove dir ID from the directories table
		DELETE FROM directories WHERE id = ${dir_id};

		COMMIT;
	EOF
}

# Timestamp all files with NANO_TIMESTAMP in the pkg database
tgt_pkg_time_timestamp() {
	if [ -z "$NANO_TIMESTAMP" ]; then
		return 0
	fi

	tgt_pkg shell "UPDATE files SET mtime = ${NANO_TIMESTAMP};"
	tgt_pkg shell "UPDATE packages SET time = ${NANO_TIMESTAMP};"
}

# Run pkg(8) with the configured ABI, repo, and cache settings
pkg_cmd() {
	pkg --repo-conf-dir "$(nano_pkg_repos_dir)" \
	    -o ABI="$NANO_ABI" \
	    -o ASSUME_ALWAYS_YES=yes \
	    -o IGNORE_OSVERSION=yes \
	    -o OSVERSION="$NANO_OSVERSION" \
	    -o PKG_CACHEDIR="$(nano_pkg_cachedir)" \
	    -o PKG_DBDIR="${NANO_WORLDDIR}/var/db/pkg" \
	    "$@"
}

# Run pkg(8) with NANO_WORLDDIR as rootdir
tgt_pkg() {
	local install_as_user metalog

	if ! $do_root; then
		install_as_user="-o INSTALL_AS_USER=yes"
	fi
	if [ -n "$NANO_METALOG" ]; then
		metalog="-o METALOG=${NANO_METALOG}"
	fi

	pkg_cmd --rootdir "$NANO_WORLDDIR" ${install_as_user} ${metalog} "$@"
}

# Run pkg(8) in chroot mode against NANO_WORLDDIR
tgt_pkg_chroot() {
	pkg_cmd --chroot "$NANO_WORLDDIR" "$@"
}

# Return the directory used to cache downloaded packages
nano_pkg_cachedir() {
	echo "${NANO_OBJ}/_.cache/${NANO_ABI}"
}

# Copy FreeBSD pkg signing key fingerprints from the source tree
nano_pkg_freebsd_repo_keys() {
	(
	cd "${NANO_SRC}/share/keys"
	find . ! -name "Makefile*" |
	    cpio ${CPIO_SYMLINK} -dumpv "${NANO_WORLDDIR}/usr/share/keys"
	)
}

# Return the directory of package repository configuration files
nano_pkg_repos_dir() {
	echo "${NANO_OBJ}/_.pkg"
}

# Generate a FreeBSD.conf package repository configuration file
# XXXJL try setting CONSERVATIVE_UPGRADE=no on the builder,
# if it fails, we must set it explicitly in pkg_cmd
nano_pkg_repo_conf() {
	rm -rf "$(nano_pkg_repos_dir)"
	mkdir -p "$(nano_pkg_repos_dir)"
	cat > "$(nano_pkg_repos_dir)/FreeBSD.conf" <<EOF
FreeBSD-ports: {
  url: "pkg+https://pkg.freebsd.org/\${ABI}/${NANO_PORTS_DIR}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
FreeBSD-base: {
  url: "pkg+https://pkg.freebsd.org/\${ABI}/${NANO_PKGBASE_DIR}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
# XXXJL FINGERPRINTS!
	cat > "$(nano_pkg_repos_dir)/FreeBSD-local.conf" <<EOF
FreeBSD-local: {
  url: "file://$(nano_pkg_cachedir)",
  enabled: no
}
EOF
}

# XXXJL check with ashish/jrm if it is OK to clobber the cachedir like this
# XXXJL add support for local FINGERPRINTS
nano_pkg_repo() {
	pkg_cmd repo "$(nano_pkg_cachedir)"
}

nano_pkg_disable_repos() {
	(
	cd "$NANO_WORLDDIR"

	# XXXJL is it better to just rewrite the entire file?
	sed -i "" -E \
	    -e "s/([[:space:]]*enabled[[:space:]]*:[[:space:]]*)(yes|true|on)/\1no/" \
	    -e "s/To disable a repository/To enable a repository/" \
	    -e "s/FreeBSD-ports: \{ enabled: no \}/FreeBSD-ports: { enabled: yes }/" \
	    -e "s/FreeBSD-ports-kmods: \{ enabled: no \}/FreeBSD-ports-kmods: { enabled: yes }/" \
	    -e "s/Note that the FreeBSD-base repository is disabled by default\./Note that all repositories are disabled by default./" \
	    etc/pkg/FreeBSD.conf

	if $do_precompiled; then
		tgt_pkg_update_file_sha256 etc/pkg/FreeBSD.conf
		tgt_pkg_update_config_files_content etc/pkg/FreeBSD.conf
	fi
	)
}

#
# Validate NANO_PKGBASE_LIST requirements, optionally clean the package cache,
# write the pkg repo config, and fetch pkgbase packages
#
nano_fetch_pkgbase_packages() {
	pprint 2 "configure pkg"
	pprint 3 "log: ${NANO_LOG}/_.pkgbase"

	if [ ! -d "$NANO_LOG" ]; then
		mkdir -p "$NANO_LOG"
	fi

	(
	if [ -z "$NANO_PKGBASE_LIST" ]; then
		err "NANO_PKGBASE_LIST variable is not set"
	fi

	nano_pkgbase_list_contains " FreeBSD-set-base " ||
	    nano_pkgbase_list_contains " FreeBSD-set-minimal " ||
	    err "FreeBSD-set-base or FreeBSD-set-minimal is mandatory"

	nano_pkgbase_list_contains " FreeBSD-kernel-" ||
	    err "A FreeBSD-kernel package is mandatory"

	if $do_clean; then
		rm -rf "${NANO_OBJ}/_.cache"
		rm -rf "${NANO_WORLDDIR}/var/db/pkg"
		mkdir -p "$(nano_pkg_cachedir)"
		nano_pkg_freebsd_repo_keys
		nano_pkg_repo_conf
		tgt_pkg update
		tgt_pkg install -F $(nano_pkgbase_list)
		nano_pkg_repo
	else
		pprint 2 "Using existing packages (as instructed)"
	fi
	) > "${NANO_LOG}/_.pkgbase" 2>&1
}

#######################################################################
#
# The functions which do the real work.
# Can be overridden from the config file(s)
#
#######################################################################

#
# Export values into the shell.
# We set __MAKE_CONF as a global since it is easier to get quoting
# right for paths with spaces in them
#
make_export() {
	# Similar to export_var, except puts the data out to stdout
	local var=$1
	eval val=\$$var
	echo "Setting variable: $var=\"$val\""
	export $1
}

#
# Set and export __MAKE_CONF to the build-phase make.conf path
# for use during buildworld/buildkernel
#
nano_make_build_env() {
	__MAKE_CONF="${NANO_MAKE_CONF_BUILD}"
	make_export __MAKE_CONF
}

#
# Set and export __MAKE_CONF to the install-phase make.conf path
# for use during installworld/installkernel
#
nano_make_install_env() {
	__MAKE_CONF="${NANO_MAKE_CONF_INSTALL}"
	make_export __MAKE_CONF
}

# Extra environment variables for kernel builds
nano_make_kernel_env() {
	if [ -f "${NANO_KERNEL}" ]; then
		KERNCONFDIR="$(realpath $(dirname ${NANO_KERNEL}))"
		KERNCONF="$(basename ${NANO_KERNEL})"
		make_export KERNCONFDIR
		make_export KERNCONF
	else
		export KERNCONF="${NANO_KERNEL}"
		make_export KERNCONF
	fi
}

#
# Output TARGET_ARCH and TARGET_CPUTYPE make variable assignments
# for inclusion in make.conf files
#
nano_global_make_env() {
	# global settings for the make.conf file, if set
	[ -z "${NANO_ARCH}" ] || echo TARGET_ARCH="${NANO_ARCH}"
	[ -z "${NANO_CPUTYPE}" ] || echo TARGET_CPUTYPE="${NANO_CPUTYPE}"
}

#
# Create empty files in the target tree, and record the fact.
# All paths are relative to NANO_WORLDDIR
#
tgt_touch() (
	cd "${NANO_WORLDDIR}"
	for i; do
		touch $i
		if [ -n "$NANO_METALOG" ]; then
			printf "./%s type=file uname=%s gname=%s mode=0644\n" \
			    "$i" "$NANO_DEF_UNAME" "$NANO_DEF_GNAME" >> "$NANO_METALOG"
		fi
	done
)

#
# Convert a directory into a symlink.  Takes three arguments, the current
# directory, what it should become a symlink to, and optionally, the mode.
# The directory is removed and a symlink is created.  If we're doing
# a nopriv build, then append this fact to the metalog
#
tgt_dir2symlink() {
	(
	local dir=$1
	local symlink=$2
	local mode=${3:-0777}

	cd "${NANO_WORLDDIR}"

	rm -xrf "$dir"
	if [ -n "$NANO_METALOG" ]; then
		sed -i "" "\=^\./${dir} =d" "$NANO_METALOG"
	fi
	if [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_rm_dir2symlink "$dir" "$symlink" || true
	fi

	ln -sf "$symlink" "$dir"
	chmod "$mode" "$dir"
	if [ -n "$NANO_METALOG" ]; then
		printf "./%s type=link uname=%s gname=%s mode=%s link=%s\n" \
		    "$dir" "$NANO_DEF_UNAME" "$NANO_DEF_GNAME" "$mode" \
		    "$symlink" >> "$NANO_METALOG"
	fi
	)
}

#
# Generate metalog entries for each intermediate directory in a path.
# Assume default ownership and directory permissions
#
mtree_walk() {
	local dir metalog oifs path

	dir="$1"
	metalog="${2:-$NANO_METALOG}"
	path=""

	oifs="$IFS"
	IFS="/"
	for d in $dir; do
		path="${path}/${d}"
		printf ".%s type=dir uname=%s gname=%s mode=0755\n" \
		    "$path" "$NANO_DEF_UNAME" "$NANO_DEF_GNAME" >> "$metalog"
	done
	IFS="$oifs"
}

#
# Create directories in the target tree, and record the fact.
# All paths are relative to NANO_WORLDDIR
#
tgt_dir() {
	for i; do
		mkdir -p "${NANO_WORLDDIR}/${i}"

		if [ -n "$NANO_METALOG" ]; then
			mtree_walk "$i"
		fi
	done
}

#
# Remove files or directories in the target tree, and record the fact.
# All paths are relative to NANO_WORLDDIR
#
tgt_rm() {
	for i; do
		chflags -Rf 0 "${NANO_WORLDDIR}/${i}" || true
		rm -rf "${NANO_WORLDDIR:?}/${i}"

		if [ -n "$NANO_METALOG" ]; then
			sed -i "" -e "\|^\./${i}/|d" -e "\|^\./${i} |d" "$NANO_METALOG"
		fi
	done
}

#
# Switch the current root partition in the target file system tab.
# Input: $1 = current root partition, $2 = new root partition
#
tgt_switch_root_fstab() {
	local current new
	current="$1"
	new="$2"

	for f in ${NANO_WORLDDIR}/etc/fstab ${NANO_WORLDDIR}/conf/base/etc/fstab; do
		sed -i "" "s=${NANO_DRIVE}${current}=${NANO_DRIVE}${new}=g" "${f}"
	done
}

# Run in the world chroot, errors fatal
CR() {
	chroot "${NANO_WORLDDIR}" /bin/sh -exc "$*"
}

# Run in the world chroot, errors not fatal
CR0() {
	chroot "${NANO_WORLDDIR}" /bin/sh -c "$*" || true
}

# Clean and create object directory (MAKEOBJDIRPREFIX)
clean_build() {
	pprint 2 "Clean and create object directory (${MAKEOBJDIRPREFIX})"

	if ! rm -xrf ${MAKEOBJDIRPREFIX}/ > /dev/null 2>&1; then
		chflags -R noschg ${MAKEOBJDIRPREFIX}/
		rm -xr ${MAKEOBJDIRPREFIX}/
	fi
}

# Construct build make.conf (NANO_MAKE_CONF_BUILD)
make_conf_build() {
	pprint 2 "Construct build make.conf ($NANO_MAKE_CONF_BUILD)"

	mkdir -p ${MAKEOBJDIRPREFIX}
	printenv > ${MAKEOBJDIRPREFIX}/_.env

	# Make sure we get all the global settings that NanoBSD wants
	# in addition to the user's global settings
	(
	nano_global_make_env
	echo "${CONF_WORLD}"
	echo "${CONF_BUILD}"
	if [ -n "${NANO_NOPRIV_BUILD}" ]; then
		echo NO_ROOT=true
		echo METALOG="${NANO_METALOG}"
	fi
	) > ${NANO_MAKE_CONF_BUILD}
}

# Run "make buildworld" using the build make.conf
build_world() {
	pprint 2 "run buildworld"
	pprint 3 "log: ${MAKEOBJDIRPREFIX}/_.bw"

	(
	nano_make_build_env
	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_PMAKE} buildworld
	) > ${MAKEOBJDIRPREFIX}/_.bw 2>&1
}

#
# Run "make buildkernel" using the build make.conf,
# building all kernel modules
#
build_kernel() {
	pprint 2 "build kernel ($NANO_KERNEL)"
	pprint 3 "log: ${MAKEOBJDIRPREFIX}/_.bk"

	(
	nano_make_build_env
	nano_make_kernel_env

	# Note: We intentionally build all modules, not only the ones in
	# NANO_MODULES so the built world can be reused by multiple images.
	# Although MODULES_OVERRIDE can be defined in the kernel config
	# file to override this behavior.  Just set NANO_MODULES=default
	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_PMAKE} buildkernel
	) > ${MAKEOBJDIRPREFIX}/_.bk 2>&1
}

# Remove and recreate NANO_OBJ or just NANO_WORLDDIR
clean_world() {
	if [ "${NANO_OBJ}" != "${MAKEOBJDIRPREFIX}" ]; then
		pprint 2 "Clean and create object directory (${NANO_OBJ})"
		if ! rm -xrf ${NANO_OBJ}/ > /dev/null 2>&1; then
			chflags -R noschg ${NANO_OBJ}
			rm -xr ${NANO_OBJ}/
		fi
		mkdir -p "${NANO_OBJ}" "${NANO_WORLDDIR}"
		printenv > ${NANO_LOG}/_.env
	else
		pprint 2 "Clean and create world directory (${NANO_WORLDDIR})"
		if ! rm -xrf "${NANO_WORLDDIR}/" > /dev/null 2>&1; then
			chflags -R noschg "${NANO_WORLDDIR}"
			rm -xrf "${NANO_WORLDDIR}/"
		fi
		mkdir -p "${NANO_WORLDDIR}"
	fi
}

# Construct install make.conf (NANO_MAKE_CONF_INSTALL)
make_conf_install() {
	pprint 2 "Construct install make.conf ($NANO_MAKE_CONF_INSTALL)"

	# Make sure we get all the global settings that NanoBSD wants
	# in addition to the user's global settings
	(
	nano_global_make_env
	echo "${CONF_WORLD}"
	echo "${CONF_INSTALL}"
	if [ -n "${NANO_NOPRIV_BUILD}" ]; then
		echo NO_ROOT=true
		echo METALOG=${NANO_METALOG}
	fi
	) >  ${NANO_MAKE_CONF_INSTALL}
}

# Run "make installworld" using the build make.conf
install_world() {
	pprint 2 "installworld"
	pprint 3 "log: ${NANO_LOG}/_.iw"

	(
	nano_make_install_env
	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_MAKE} installworld DESTDIR="${NANO_WORLDDIR}" DB_FROM_SRC=yes
	# chflags -R noschg "${NANO_WORLDDIR}" # XXXJL
	) > ${NANO_LOG}/_.iw 2>&1
}

#
# Install the world from pkgbase packages or distribution tarballs
# instead of building from source
#
install_precompiled_world() {
	pprint 2 "install precompiled world"
	pprint 3 "log: ${NANO_LOG}/_.iw"

	(
	set -o xtrace
	if [ -z "$NANO_NOPKGBASE" ]; then
		nano_pkg_freebsd_repo_keys
		tgt_pkg update -r FreeBSD-local
		if [ -n "$(nano_pkgbase_world_list)" ]; then
			tgt_pkg install -r FreeBSD-local -U $(nano_pkgbase_world_list)
		fi
		_xxx_tgt_pkg_triggers
	else
		for distset in $NANO_DISTRIBUTIONS; do
			if [ "$distset" = "kernel.txz" ] || \
			    [ "$distset" = "kernel-dbg.txz" ]; then
				continue
			fi
			if [ -f "$(nano_distset_dir)/${distset}" ]; then
				tar -xvf "$(nano_distset_dir)/${distset}" -C "${NANO_WORLDDIR}"
			else
				err "File $(nano_distset_dir)/${distset} not found"
			fi
		done
	fi
	) > "${NANO_LOG}/_.iw" 2>&1
}

#
# Run "make distribution" to populate /etc in NANO_WORLDDIR
# and create an empty make.conf
#
install_etc() {
	pprint 2 "install /etc"
	pprint 3 "log: ${NANO_LOG}/_.etc"

	(
	nano_make_install_env
	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_MAKE} distribution DESTDIR="${NANO_WORLDDIR}" DB_FROM_SRC=yes
	# make.conf doesn't get created by default, but some ports need it
	# so they can spam it
	cp /dev/null "${NANO_WORLDDIR}"/etc/make.conf
	) > ${NANO_LOG}/_.etc 2>&1
}

#
# Run "make installkernel" using the build make.conf
# and optionally installing NANO_MODULES
#
install_kernel() {
	pprint 2 "install kernel ($NANO_KERNEL)"
	pprint 3 "log: ${NANO_LOG}/_.ik"

	(

	nano_make_install_env
	nano_make_kernel_env

	if [ "${NANO_MODULES}" != "default" ]; then
		MODULES_OVERRIDE="${NANO_MODULES}"
		make_export MODULES_OVERRIDE
	fi

	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_MAKE} installkernel DESTDIR="${NANO_WORLDDIR}" DB_FROM_SRC=yes

	) > ${NANO_LOG}/_.ik 2>&1
}

# Install a precompiled kernel from pkgbase packages or distribution tarballs
install_precompiled_kernel() {
	pprint 2 "install precompiled kernel (GENERIC)"
	pprint 3 "log: ${NANO_LOG}/_.ik"

	(
	set -o xtrace
	if [ -z "$NANO_NOPKGBASE" ]; then
		if [ -n "$(nano_pkgbase_kernel_list)" ]; then
			tgt_pkg install -r FreeBSD-local -U $(nano_pkgbase_kernel_list)
		fi
	else
		if [ -f "$(nano_distset_dir)/kernel.txz" ]; then
			tar -xvf "$(nano_distset_dir)/kernel.txz" -C "${NANO_WORLDDIR}"
		else
			err "File $(nano_distset_dir)/kernel.txz not found"
		fi
		if nano_distributions_contains " kernel-dbg.txz " &&
		    [ -f "$(nano_distset_dir)/kernel-dbg.txz" ]; then
			tar -xvf "$(nano_distset_dir)/kernel-dbg.txz" -C "${NANO_WORLDDIR}"
		fi
	fi
	) > "${NANO_LOG}/_.ik" 2>&1
}

#
# Build and install optimized native cross-compilation tools into NANO_WORLDDIR
# for cross-arch builds
#
native_xtools() {
	pprint 2 "Installing the optimized native build tools for cross env"
	pprint 3 "log: ${NANO_LOG}/_.native_xtools"

	(

	nano_make_install_env
	set -o xtrace
	cd "${NANO_SRC}"
	${NANO_MAKE} native-xtools
	${NANO_MAKE} native-xtools-install DESTDIR="${NANO_WORLDDIR}"

	) > ${NANO_LOG}/_.native_xtools 2>&1
}

#
# Run the requested set of early customization scripts,
# run before buildworld
#
run_early_customize() {
	pprint 2 "run early customize scripts"
	for c in $NANO_EARLY_CUSTOMIZE; do
		pprint 2 "early customize \"$c\""
		pprint 3 "log: ${NANO_LOG}/_.early_cust.$c"
		pprint 4 "$(type $c)"
		{ t=$(set -o | awk '$1 == "xtrace" && $2 == "off" { print "set +o xtrace"}');
		  set -o xtrace ;
		  $c ;
		  eval $t
		} >${NANO_LOG}/_.early_cust.$c 2>&1
	done
}

#
# Run the requested set of customization scripts, run after we've
# done an installworld, installed the etc files, installed the kernel
# and tweaked them in the standard way
#
run_customize() {

	pprint 2 "run customize scripts"
	for c in $NANO_CUSTOMIZE; do
		pprint 2 "customize \"$c\""
		pprint 3 "log: ${NANO_LOG}/_.cust.$c"
		pprint 4 "$(type $c)"
		( set -o xtrace ; $c ) > ${NANO_LOG}/_.cust.$c 2>&1
	done
}

#
# Run any last-minute customization commands after we've had a chance to
# setup nanobsd, prune empty dirs from /usr, etc
#
run_late_customize() {
	pprint 2 "run late customize scripts"
	for c in $NANO_LATE_CUSTOMIZE; do
		pprint 2 "late customize \"$c\""
		pprint 3 "log: ${NANO_LOG}/_.late_cust.$c"
		pprint 4 "$(type $c)"
		( set -o xtrace ; $c ) > ${NANO_LOG}/_.late_cust.$c 2>&1
	done
}

#
# Hook called after we run all the late customize commands, but
# before we invoke the disk imager.  The nopriv build uses it to
# read in the meta log, apply the changes other parts of nanobsd
# have been recording their actions.  It's not anticipated that
# a user's cfg file would override this
#
fixup_before_diskimage() {
	# Run the deduplication script that takes the metalog journal and
	# combines multiple entries for the same file (see source for details).
	# We take the extra step of removing the size and time keywords. This
	# script, and many of the user scripts, copies, appends and otherwise
	# modifies files in the build, changing their sizes.  These actions are
	# impossible to trap, so go ahead remove the size= keyword. For this
	# narrow use, it doesn't buy us any protection and just gets in the way.
	# The dedup tool's output must be sorted due to limitations in awk
	if [ -n "${NANO_METALOG}" ]; then
		pprint 2 "Fixing metalog"

		if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
			_xxx_pkg_metalog
			_xxx_run_pkg_scripts
		fi

		cp ${NANO_METALOG} ${NANO_METALOG}.pre
		echo "/set uname=${NANO_DEF_UNAME} gname=${NANO_DEF_GNAME}" > ${NANO_METALOG}
		cat ${NANO_METALOG}.pre | ${NANO_TOOLS}/mtree-dedup.awk | \
		    sort -u | mtree -C -K uname,gname,tags -R size,time >> ${NANO_METALOG}
	fi

	if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
		_xxx_fix_pkg_permissions
		tgt_pkg_time_timestamp
		_xxx_pkg_db_dump_or_vacuum
	fi
}

#
# Relocate /usr/local/etc to /etc/local,
# hard-links /etc and /var into /conf/base,
# set ramdisk sizes, and symlinks /tmp to /var/tmp
#
setup_nanobsd() {
	pprint 2 "configure nanobsd setup"
	pprint 3 "log: ${NANO_LOG}/_.dl"

	(
	cd "${NANO_WORLDDIR}"

	# Move /usr/local/etc to /etc/local so that the /cfg stuff
	# can stomp on it.  Otherwise packages like ipsec-tools which
	# have hardcoded paths under ${prefix}/etc are not tweakable
	if [ -d usr/local/etc ]; then
		(
		cd usr/local/etc
		find . -print | cpio ${CPIO_SYMLINK} -dumpl ../../../etc/local
		cd ..
		rm -xrf etc
		)
		if [ -n "$NANO_METALOG" ]; then
			sed -i "" "\=^\./usr/local/etc =d" "$NANO_METALOG"
			sed -i "" -e "s=^\./usr/local/etc/=./etc/local/=g" "$NANO_METALOG"
		fi
		if [ -z "$NANO_NOPKGBASE" ]; then
			tgt_pkg shell "UPDATE directories
			    SET path = '/etc/local'
			    WHERE path = '/usr/local/etc';"
			tgt_pkg shell "UPDATE files
			    SET path = '/etc/local' || SUBSTR(path, 15)
			    WHERE path LIKE '/usr/local/etc%';"
		fi
	fi

	# Always setup the usr/local/etc -> etc/local symlink.
	# usr/local/etc gets created by packages, but if no packages
	# are installed by this point, but are later in the process,
	# the symlink not being here causes problems.  It never hurts
	# to have the symlink in error though
	tgt_dir2symlink usr/local/etc ../../etc/local 0755

	# Disable all package repositories
	if [ -z "$NANO_NOPKGBASE" ]; then
		nano_pkg_disable_repos
	fi

	# Put /tmp on the /var ramdisk
	tgt_dir2symlink tmp var/tmp 1777

	if [ -n "$NANO_METALOG" ]; then
		_xxx_pkg_add_var_db_files_to_metalog
	fi

	for d in var etc; do
		# Link /$d under /conf
		# we use hard links so we have them both places.
		# the files in /$d will be hidden by the mount
		tgt_dir conf/base/$d conf/default/$d
		find $d -print | cpio ${CPIO_SYMLINK} -dumpl conf/base/
		if [ -n "$NANO_METALOG" ]; then
			grep "^.\/${d}\/" "${NANO_METALOG}" |
			    sed -e "s=^./${d}=./conf/base/${d}=g" |
			    sort -u >> "${NANO_METALOG}.conf"
		fi
	done

	# Esure the /conf/default/var/db/pkg directory is present
	if [ -z "$NANO_NOPKGBASE" ]; then
		tgt_dir conf/default/var/db/pkg
	fi

	if [ -n "$NANO_METALOG" ]; then
		cat "${NANO_METALOG}.conf" >> "${NANO_METALOG}"
		rm -f "${NANO_METALOG}.conf"
	fi

	echo "$NANO_RAM_ETCSIZE" > conf/base/etc/md_size
	echo "$NANO_RAM_TMPVARSIZE" > conf/base/var/md_size
	tgt_touch conf/base/etc/md_size
	tgt_touch conf/base/var/md_size

	# Add the /conf/default/etc/remount file
	tgt_etc_remount

	# Make sure that firstboot scripts run so growfs works
	tgt_touch firstboot
	) > ${NANO_LOG}/_.dl 2>&1
}

#
# Create the diskless marker file,
# disable entropy/UUID at boot in loader.conf/rc.conf,
# create nanobsd.conf and fstab
#
setup_nanobsd_etc() {
	pprint 2 "configure nanobsd /etc"

	(
	cd "${NANO_WORLDDIR}"

	# create diskless marker file
	tgt_touch etc/diskless

	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 666 boot/defaults/loader.conf
	{
		echo
		echo '###  NanoBSD configuration  ##################################'
		echo 'hostuuid_load="NO"'
		echo 'entropy_cache_load="NO"		# Disable loading cached entropy at boot time.'
		echo 'kern.random.initial_seeding.disable_bypass_warnings="1"	# Do not log a warning'
		echo "				# if the 'bypass_before_seeding' knob is enabled"
		echo "				# and a request is submitted prior to initial"
		echo "				# seeding."
	} >> boot/defaults/loader.conf
	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 444 boot/defaults/loader.conf
	if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_update_file_sha256 boot/defaults/loader.conf
	fi

	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 666 etc/defaults/rc.conf
	if ! ed -s etc/defaults/rc.conf <<\EOF
/^### Define source_rc_confs, the mechanism used by \/etc\/rc\.\* ##$/i
###  NanoBSD options  ########################################
##############################################################

kldxref_enable="NO"	# Disable building linker.hints files with kldxref(8).
root_rw_mount="NO"	# Inhibit remounting root read-write.
entropy_boot_file="NO"	# Disable very early (used at early boot time)
			# entropy caching through reboots.
entropy_file="NO"	# Disable late (used when going multi-user)
			# entropy through reboots.
entropy_dir="NO"	# Disable caching entropy via cron.
dumpdev="NO"		# Disable dumpdev.
growfs_enable="YES"	# Attempt to grow the root filesystem on boot.
growfs_swap_size="${NANO_SWAP_SIZE}"	# Size in bytes to specify swap size.

##############################################################
.
w
q
EOF
	then
		err "Regular expression pattern not found"
	fi
	[ -n "${NANO_NOPRIV_BUILD}" ] && chmod 444 etc/defaults/rc.conf
	if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_update_file_sha256 etc/defaults/rc.conf
		tgt_pkg_update_config_files_content etc/defaults/rc.conf
	fi

	tgt_write_fstab
	tgt_dir cfg

	# Create directory for eventual /usr/local/etc contents
	tgt_dir etc/local
	)
}

# Write to the /etc/fstab file
printf_fstab() {
	printf "%s\t\t%s\t%s\t%s\t\t%s\t%s\n" \
	    "$1" "$2" "$3" "$4" "$5" "$6" >> ${NANO_WORLDDIR}/etc/fstab
}

get_uefi_bootname() {
	case "$NANO_ARCH" in
	amd64)   echo BOOTX64 ;;
	aarch64) echo BOOTAA64 ;;
	i386)    echo BOOTIA32 ;;
	armv7)   echo BOOTARM ;;
	riscv64) echo BOOTRISCV64 ;;
	*)       err "Unsupported NANO_ARCH '${NANO_ARCH}'" ;;
	esac
}

get_bootcode() {
	local boot_type part_type
	boot_type="$1"
	part_type="$2"

	case "$boot_type" in
	[Bb][Ii][Oo][Ss])
		case "$part_type" in
		[Mm][Bb][Rr]) echo "boot/boot" ;;
		[Gg][Pp][Tt]) echo "boot/gptboot" ;;
		*) err "Unsupported BIOS partition type '${part_type}'" ;;
		esac
		;;
	[Uu][Ee][Ff][Ii])
		# XXXJL we want /boot/loader.efi for Primary/Secondary ESP partitions.
		# These are supposed to be switched with efibootmgr -n.
		# For the Recovery ESP with UFS, we want /boot/gptboot.efi,
		# this allows us to switch using gpart set -a bootonce.
		# For the Recovery ESP with ZFS, we want /boot/loader.efi,
		# coupled with a bare-minimum zpool-features(7)?
		case "$part_type" in
		[Gg][Pp][Tt]) echo "boot/loader.efi" ;;
		[Zz][Ff][Ss]) echo "boot/loader.efi" ;;
		*) err "Unsupported UEFI partition type '${part_type}'" ;;
		esac
		;;
	*) err "Unsupported boot type '${boot_type}'" ;;
	esac
}

# Remove all empty directories under NANO_WORLDDIR/usr
prune_usr() {
	# Remove all empty directories in /usr
	find "${NANO_WORLDDIR}/usr" -type d -depth -empty |
	    while read -r d; do
		rmdir "$d" > /dev/null 2>&1 || true
		if [ -n "$NANO_METALOG" ]; then
			sed -i "" -e "\|^\.${d#"$NANO_WORLDDIR"} |d" "$NANO_METALOG"
		fi
	done
}

#
# Create a new UFS filesystem on a block device with an optional label,
# and mount it async
# Input: $1 = device, $2 = mount point, $3 = label suffix
#
newfs_part() {
	local dev mnt lbl
	dev=$1
	mnt=$2
	lbl=$3
	echo newfs ${NANO_NEWFS} ${NANO_LABEL:+-L${NANO_LABEL}${lbl}} ${dev}
	newfs ${NANO_NEWFS} ${NANO_LABEL:+-L${NANO_LABEL}${lbl}} ${dev}
	mount -o async ${dev} ${mnt}
}

#
# Run makefs to create a UFS filesystem image from a source directory
# using a metalog spec and timestamp
# Input: $1 = options, $2 = metalog path, $3 = size in sectors,
# $4 = output image path, $5 = source dir
#
nano_makefs() {
	local dir image metalog options size
	options=$1
	metalog=$2
	size=$3
	image=$4
	dir=$5

	if [ -n "$metalog" ] && [ -f "$metalog" ]; then
		makefs -t ffs -DxZ ${options} -F "$metalog" -N "${NANO_WORLDDIR}/etc" \
		    -R "${size}b" -T "$NANO_TIMESTAMP" "$image" "$dir"
	else
		makefs -t ffs -Z ${options} -N "${NANO_WORLDDIR}/etc" \
		    -R "${size}b" -T "$NANO_TIMESTAMP" "$image" "$dir"
	fi
}

#
# Convenient spot to work around any umount issues that your build environment
# hits by overriding this method
#
nano_umount() {
	umount ${1}
}

#
# Populate a partition from a source directory on a given device
# Input: $1 = device, $2 = source dir (optional), $3 = mount point,
# $4 = label suffix
#
populate_slice() {
	local dev dir mnt lbl
	dev=$1
	dir=$2
	mnt=$3
	lbl=$4
	echo "Creating ${dev} (mounting on ${mnt})"
	newfs_part ${dev} ${mnt} ${lbl}
	if [ -n "${dir}" -a -d "${dir}" ]; then
		echo "Populating ${lbl} from ${dir}"
		cd "${dir}"
		find . -print | grep -Ev '/(CVS|\.svn|\.hg|\.git)/' |
		    cpio ${CPIO_SYMLINK} -dumpv ${mnt}
	fi
	df -i ${mnt}
	nano_umount ${mnt}
}

#
# Create a UFS filesystem image from a directory
# Input: $1 = type (cfg/data), $2 = output image path, $3 = source dir,
# $4 = label, $5 = size in sectors, $6 = metalog
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

	# Use the directory provided, otherwise create an empty one temporarily
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
		# NANO_DEF_UNAME and NANO_DEF_GNAME for all entries in the spec
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

		nano_makefs "${NANO_MAKEFS}" "${metalog}" "${size}" "${fs}" "${dir}"
	fi
}

#
# Thin wrapper around populate_slice for the configuration partition
# Input: $1 = device, $2 = source dir, $3 = mount point, $4 = label
#
populate_cfg_slice() {
	populate_slice "$1" "$2" "$3" "$4"
}

#
# Thin wrapper around populate_part for creating
# the configuration partition image file
# Input: $1 = image path, $2 = source dir, $3 = slice number,
# $4 = size in sectors, $5 = metalog
#
populate_cfg_part() {
	populate_part "cfg" "$1" "$2" "$3" "$4" "$5"
}

#
# Thin wrapper around populate_slice for the data partition
# Input: $1 = device, $2 = source dir, $3 = mount point, $4 = label
#
populate_data_slice() {
	populate_slice "$1" "$2" "$3" "$4"
}

#
# Thin wrapper around populate_part for creating the data partition image file
# Input: $1 = image path, $2 = source dir, $3 = label, $4 = size, $5 = metalog
#
populate_data_part() {
	populate_part "data" "$1" "$2" "$3" "$4" "$5"
}

#
# Placeholder hook called after image build completes;
# override to copy or publish the finished image
#
last_orders() {
	# Redefine this function with any last orders you may have
	# after the build completed, for instance to copy the finished
	# image to a more convenient place:
	# cp ${NANO_DISKIMGDIR}/${NANO_IMG1NAME} /home/ftp/pub/nanobsd.disk
	true
}

#######################################################################
#
# Optional convenience functions
#
#######################################################################

# Print an error message to stderr and exits with code 2
err() {
	echo "$@" >&2
	exit 2
}

#
# Convert a human-readable size string with a suffix (b/k/m/g/t/w) into bytes.
# Also accepts "x"-delimited products followed by a suffix (e.g., "2x1024k")
# makefs(8)-size compatible.  See NetBSD's strsuftoll(3)
# Input: $1 = size string (e.g., "512m", "2x1024x1024k")
# Output: byte count
#
strsuftoll() {
	local num result unit

	num=${1%?}
	unit=${1#"${num}"}

	case "$unit" in
	[bB]) result="${num}x${NANO_SECTOR_SIZE}" ;;
	[kK]) result="${num}x1024" ;;
	[mM]) result="${num}x1024x1024" ;;
	[gG]) result="${num}x1024x1024x1024" ;;
	[tT]) result="${num}x1024x1024x1024x1024" ;;
	[wW]) result="${num}x4" ;; # sizeof(int)
	[0-9]) result="$1" ;;
	*)
		printf "%s\n" "'$1': illegal number"
		exit 1
		;;
	esac

	printf "%s" "$(echo "scale=0; $result" | tr 'x' '*' | bc)"
}

#######################################################################
# Common Flash device geometries
#

#
# Source FlashDevice.sub and call sub_FlashDevice to set NANO_MEDIASIZE
# and geometry vars for a named flash device
# Input: $1 = flash device name, $2 = size variant
#
FlashDevice() {
	if [ -d ${NANO_TOOLS} ]; then
		. ${NANO_TOOLS}/FlashDevice.sub
	else
		. ${NANO_SRC}/${NANO_TOOLS}/FlashDevice.sub
	fi
	sub_FlashDevice $1 $2
}

#######################################################################
# USB device geometries
#
# Usage:
#	UsbDevice Generic 1000	# a generic flash key sold as having 1GB
#
# This function will set NANO_MEDIASIZE, NANO_HEADS and NANO_SECTS for you.
#
# Note that the capacity of a flash key is usually advertised in MB or
# GB, *not* MiB/GiB. As such, the precise number of cylinders available
# for C/H/S geometry may vary depending on the actual flash geometry.
#
# The following generic device layouts are understood:
#  generic           An alias for generic-hdd.
#  generic-hdd       255H 63S/T xxxxC with no MBR restrictions.
#  generic-fdd       64H 32S/T xxxxC with no MBR restrictions.
#
# The generic-hdd device is preferred for flash devices larger than 1GB
#

#
# Set NANO_HEADS, NANO_SECTS, and NANO_MEDIASIZE for a USB device based
# on type (generic-fdd/generic-hdd) and advertised MB capacity
# Input: $1 = device type string, $2 = size in MB
#
UsbDevice() {
	local a1=$(echo $1 | tr '[:upper:]' '[:lower:]')
	case $a1 in
	generic-fdd)
		NANO_HEADS=64
		NANO_SECTS=32
		NANO_MEDIASIZE=$(( $2 * 1000 * 1000 / 512 ))
		;;
	generic|generic-hdd)
		NANO_HEADS=255
		NANO_SECTS=63
		NANO_MEDIASIZE=$(( $2 * 1000 * 1000 / 512 ))
		;;
	*)
		err "Unknown USB flash device"
		;;
	esac
}

#######################################################################
# Setup serial console

# Enable serial console in /etc/ttys and write NANO_BOOT2CFG to /boot.config
cust_comconsole() {
	# Enable getty on console
	sed -i "" -e '/^tty[du]0/s/off/onifconsole/' ${NANO_WORLDDIR}/etc/ttys

	# Disable getty on syscons or vt devices
	sed -i "" -E '/^ttyv[0-8]/s/\ton(ifexists)?/\toff/' ${NANO_WORLDDIR}/etc/ttys

	# Tell loader to use serial console early
	echo "${NANO_BOOT2CFG}" > ${NANO_WORLDDIR}/boot.config
	tgt_touch boot.config

	if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_update_file_sha256 etc/ttys
		tgt_pkg_update_config_files_content etc/ttys
	fi
}

#######################################################################
# Allow root login via ssh

# Enable root login via SSH by setting PermitRootLogin yes in sshd_config
cust_allow_ssh_root() {
	sed -i "" -E 's/^#?PermitRootLogin.*/PermitRootLogin yes/' \
	    ${NANO_WORLDDIR}/etc/ssh/sshd_config

	if $do_precompiled && [ -z "$NANO_NOPKGBASE" ]; then
		tgt_pkg_update_file_sha256 etc/ssh/sshd_config
		tgt_pkg_update_config_files_content etc/ssh/sshd_config
	fi
}

#######################################################################
# Install the stuff under ./Files

# Copy all files from NANO_TOOLS/Files into NANO_WORLDDIR
cust_install_files() {
	(
	cd "$NANO_CUST_FILESDIR"
	find . -print | grep -Ev '/(CVS|\.svn|\.hg|\.git)/' |
	    cpio ${CPIO_SYMLINK} -Ldumpv "$NANO_WORLDDIR"

	if [ -n "$NANO_CUST_FILES_MTREE" ] && [ -f "$NANO_CUST_FILES_MTREE" ]; then
		if [ -n "$NANO_NOPRIV_BUILD" ]; then
			# Entries in NANO_CUST_FILES_MTREE must precede NANO_METALOG
			cat "$NANO_CUST_FILES_MTREE" "$NANO_METALOG" > "${NANO_METALOG}.tmp"
			mv "${NANO_METALOG}.tmp" "$NANO_METALOG"
		else
			CR "mtree -eiU -p /" <"$NANO_CUST_FILES_MTREE"
		fi
	else
		tgt_touch $(find * -type f)
	fi
	)
}

#######################################################################
# Install packages from ${NANO_PACKAGE_DIR}

#
# Bootstrap pkg and install all packages from NANO_PACKAGE_DIR
# into NANO_WORLDDIR via a nullfs-mounted chroot
#
cust_pkgng() {
	if ! $do_root && [ -n "$NANO_NOPRIV_BUILD" ]; then
		pprint 2 'Skipping "cust_pkgng" (unprivileged builds not supported yet)'
		return 0
	fi

	mkdir -p ${NANO_WORLDDIR}/usr/local/etc
	local PKG_CONF="${NANO_WORLDDIR}/usr/local/etc/pkg.conf"
	local PKGCMD="env BATCH=YES ASSUME_ALWAYS_YES=YES PKG_DBDIR=${NANO_PKG_META_BASE}/pkg SIGNATURE_TYPE=none /usr/sbin/pkg"

	# Ensure pkg.conf points pkg to where the package meta data lives
	touch ${PKG_CONF}
	if grep -Eiq '^PKG_DBDIR:.*' ${PKG_CONF}; then
		sed -i -e "\|^PKG_DBDIR:.*|Is||PKG_DBDIR: "\"${NANO_PKG_META_BASE}/pkg\""|" ${PKG_CONF}
	else
		echo "PKG_DBDIR: \"${NANO_PKG_META_BASE}/pkg\"" >> ${PKG_CONF}
	fi

	# If the package directory doesn't exist, we're done
	NANO_PACKAGE_DIR="$(realpath $NANO_PACKAGE_DIR)"
	if [ ! -d ${NANO_PACKAGE_DIR} ]; then
		echo "DONE 0 packages"
		return 0
	fi

	# Find a pkg-* package
	for x in $(find -s ${NANO_PACKAGE_DIR} -iname 'pkg-*'); do
		_NANO_PKG_PACKAGE=$(basename "$x")
	done
	if [ -z "${_NANO_PKG_PACKAGE}" -o ! -f "${NANO_PACKAGE_DIR}/${_NANO_PKG_PACKAGE}" ]; then
		err "FAILED: need a pkg/ package for bootstrapping"
	fi

	# Mount packages into chroot
	mkdir -p ${NANO_WORLDDIR}/_.p
	mount -t nullfs -o noatime -o ro ${NANO_PACKAGE_DIR} ${NANO_WORLDDIR}/_.p
	mount -t devfs devfs ${NANO_WORLDDIR}/dev

	trap "nano_umount ${NANO_WORLDDIR}/dev; nano_umount ${NANO_WORLDDIR}/_.p ; rm -xrf ${NANO_WORLDDIR}/_.p" 1 2 15 EXIT

	# Install pkg-* package
	CR "${PKGCMD} add /_.p/${_NANO_PKG_PACKAGE}"

	(
		# Expand any glob characters in package list
		cd "${NANO_PACKAGE_DIR}"
		_PKGS=$(find ${NANO_PACKAGE_LIST} -not -name "${_NANO_PKG_PACKAGE}" -print | sort -u)

		# Show todo
		todo=$(echo "$_PKGS" | wc -l)
		echo "=== TODO: $todo"
		echo "$_PKGS"
		echo "==="

		# Install packages
		for _PKG in $_PKGS; do
			CR "${PKGCMD} add /_.p/${_PKG}"
		done
	)

	CR0 "${PKGCMD} info"

	trap - 1 2 15 EXIT
	nano_umount ${NANO_WORLDDIR}/dev
	nano_umount ${NANO_WORLDDIR}/_.p
	rm -xrf ${NANO_WORLDDIR}/_.p
}

#######################################################################
# Convenience function:
#	Register all args as early customize function to run just before
#	build commences

#
# Register one or more function names to run before buildworld
# by appending them to NANO_EARLY_CUSTOMIZE
# Input: $* = function name(s)
#
early_customize_cmd() {
	NANO_EARLY_CUSTOMIZE="$NANO_EARLY_CUSTOMIZE $*"
}

#######################################################################
# Convenience function:
# 	Register all args as customize function

#
# Register one or more function names to run after installworld/installkernel
# by appending them to NANO_CUSTOMIZE
# Input: $* = function name(s)
#
customize_cmd() {
	NANO_CUSTOMIZE="$NANO_CUSTOMIZE $*"
}

#######################################################################
# Convenience function:
# 	Register all args as late customize function to run just before
#	image creation

#
# Register one or more function names to run just before image creation
# by appending them to NANO_LATE_CUSTOMIZE
# Input: $* = function name(s)
#
late_customize_cmd() {
	NANO_LATE_CUSTOMIZE="$NANO_LATE_CUSTOMIZE $*"
}

#######################################################################
#
# All set up to go...
#
#######################################################################

#
# Progress Print
# Input: $1 = level, $2 = message
#
pprint() {
	if [ "$1" -le $PPLEVEL ]; then
		runtime=$(( $(date +%s) - NANO_STARTTIME ))
		printf "%s %.${1}s %s\n" \
		    "$(date -u -r $runtime +%H:%M:%S)" "#####" "$2" 1>&3
	fi
}

# Print the nanobsd.sh command-line option summary to stderr, exit with code 2
usage() {
	(
	echo "Usage: $0 [-BbfhIiKknPpqUvWwX] [-c config_file]"
	echo "	-B	suppress installs (both kernel and world)"
	echo "	-b	suppress builds (both kernel and world)"
	echo "	-c	specify config file"
	echo "	-f	suppress code slice extraction (implies -i)"
	echo "	-h	print this help summary page"
	echo "	-I	build disk image from existing build/install"
	echo "	-i	suppress disk image build"
	echo "	-K	suppress installkernel"
	echo "	-k	suppress buildkernel"
	echo "	-n	add -DNO_CLEAN to buildworld, buildkernel, etc"
	echo "	-P	use pre-compiled binaries"
	echo "	-p	suppress preparing the image"
	echo "	-q	make output more quiet"
	echo "	-U	add -DNO_ROOT to build without root privileges"
	echo "	-v	make output more verbose"
	echo "	-W	suppress installworld"
	echo "	-w	suppress buildworld"
	echo "	-X	make native-xtools"
	) 1>&2
	exit 2
}

#######################################################################
# Setup and Export Internal variables
#

#
# Export a variable and log its current value at verbosity level 3 via pprint
# Input: $1 = variable name
#
export_var() {
	var=$1
	# Lookup value of the variable
	eval val=\$$var
	pprint 3 "Setting variable: $var=\"$val\""
	export $1
}

# Call this function to set defaults _after_ parsing options
set_defaults_and_export() {
	: ${NANO_OBJ:=/usr/obj/nanobsd.${NANO_NAME}${NANO_LAYOUT:+.${NANO_LAYOUT}}}
	: ${MAKEOBJDIRPREFIX:=${NANO_OBJ}}
	: ${NANO_DISKIMGDIR:=${NANO_OBJ}}
	: ${NANO_WORLDDIR:=${NANO_OBJ}/_.w}
	: ${NANO_LOG:=${NANO_OBJ}}
	: ${NANO_PMAKE:="${NANO_MAKE} -j ${NANO_NCPU}"}
	if ! $do_clean; then
		NANO_PMAKE="${NANO_PMAKE} -DNO_CLEAN"
	fi
	if ! $do_root; then
		NANO_PMAKE="${NANO_PMAKE} -DNO_ROOT"
	fi
	NANO_MAKE_CONF_BUILD=${MAKEOBJDIRPREFIX}/make.conf.build
	NANO_MAKE_CONF_INSTALL=${NANO_OBJ}/make.conf.install

	# Set a default NANO_TOOLS to NANO_SRC/NANO_TOOLS if it exists
	[ ! -d "${NANO_TOOLS}" ] && [ -d "${NANO_SRC}/${NANO_TOOLS}" ] && \
		NANO_TOOLS="${NANO_SRC}/${NANO_TOOLS}" || true

	if [ -n "${NANO_NOPRIV_BUILD}" ] && [ -z "${NANO_METALOG}" ]; then
		NANO_METALOG=${NANO_OBJ}/_.metalog
	fi

	NANO_STARTTIME=$(date +%s)
	: ${NANO_TIMESTAMP:=${NANO_STARTTIME}}
	pprint 3 "Exporting NanoBSD variables"
	export_var MAKEOBJDIRPREFIX
	export_var NANO_ARCH
	export_var NANO_CODESIZE
	export_var NANO_CONFSIZE
	export_var NANO_CUSTOMIZE
	export_var NANO_DATASIZE
	export_var NANO_DISKIMGDIR
	export_var NANO_DRIVE
	export_var NANO_HEADS
	export_var NANO_IMAGES
	export_var NANO_IMGNAME
	export_var NANO_IMG1NAME
	export_var NANO_MAKE
	export_var NANO_MAKEFS
	export_var NANO_MAKE_CONF_BUILD
	export_var NANO_MAKE_CONF_INSTALL
	export_var NANO_MEDIASIZE
	export_var NANO_NAME
	export_var NANO_NCPU
	export_var NANO_NEWFS
	export_var NANO_OBJ
	export_var NANO_PMAKE
	export_var NANO_SECTS
	export_var NANO_SRC
	export_var NANO_SWAP_ENCRYPTION
	export_var NANO_SWAP_SIZE
	export_var NANO_TIMESTAMP
	export_var NANO_TOOLS
	export_var NANO_WORLDDIR
	export_var NANO_BOOT0CFG
	export_var NANO_BOOTLOADER
	export_var NANO_LABEL
	export_var NANO_MODULES
	export_var NANO_NOPRIV_BUILD
	export_var NANO_METALOG
	export_var NANO_NOPKGBASE
	export_var NANO_LOG
	export_var SRCCONF
	export_var SRC_ENV_CONF
}
