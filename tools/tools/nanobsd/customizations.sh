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

# XXXJL
# Some of these defaults will be moved to legacy.sh,
# the remaining ones will be moved back to defaults.sh.

# Where cust_pkgng() finds packages to install
NANO_PACKAGE_DIR=${NANO_SRC}/${NANO_TOOLS}/Pkg
NANO_PACKAGE_LIST="*"

# where package metadata gets placed
NANO_PKG_META_BASE=/var/db

# Path to the files directory used by cust_install_files()
NANO_CUST_FILESDIR="${NANO_TOOLS}/Files"

#
# Path to mtree file to apply to anything copied by cust_install_files().
# If you specify this, the mtree file *must* have an entry for every file and
# directory located in Files
#
#NANO_CUST_FILES_MTREE=""

#
# boot2 flags/options.
# Default force serial console
#
NANO_BOOT2CFG="-h -S115200"

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
