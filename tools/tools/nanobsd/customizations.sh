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

# Poudriere-compatible package list (used by the legacy plan)
NANO_PACKAGE_LIST=""

# Path to a package list file: one ports origin or package name per line,
NANO_PKGLIST=""

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
# Install packages from ${NANO_PACKAGE_DIR} or the online pkg repo

#
# Install the packages listed in the NANO_PKGLIST file plus their
# dependencies. Two sources:
#   - NANO_PACKAGE_DIR set: a directory of pre-built packages (e.g. a
#     poudriere All/ directory). It must contain every listed package
#     and all of their dependencies; missing packages abort the build.
#   - NANO_PACKAGE_DIR unset: packages are downloaded from the online
#     FreeBSD-ports repository into the local cache and installed.
#
cust_pkgng() {
	local pkgs

	if ! $do_root && [ -n "$NANO_NOPRIV_BUILD" ]; then
		pprint 2 'Skipping "cust_pkgng" (unprivileged builds not supported yet)'
		return 0
	fi

	if [ -z "$NANO_PKGLIST" ]; then
		err "NANO_PKGLIST must be set when using cust_pkgng"
	fi
	if [ ! -f "$NANO_PKGLIST" ]; then
		err "NANO_PKGLIST file not found: '${NANO_PKGLIST}'"
	fi

	pkgs="ports-mgmt/pkg $(sed -e 's/#.*//' "$NANO_PKGLIST" | xargs)"

	if [ -n "$NANO_PACKAGE_DIR" ]; then
		cust_pkgng_local_dir $pkgs
	else
		cust_pkgng_online $pkgs
	fi
}

#
# Verify that every requested package and all of their dependencies are
# present in NANO_PACKAGE_DIR, then install from there.
# Input: $@ = package list
#
cust_pkgng_local_dir() {
	local pkgfile repodir

	if [ ! -d "$NANO_PACKAGE_DIR" ]; then
		err "NANO_PACKAGE_DIR is not a directory: '${NANO_PACKAGE_DIR}'"
	fi

	# pkg-repo(8) writes its index into the repository directory and
	# NANO_PACKAGE_DIR may be read-only: index a symlinked copy instead
	repodir="${NANO_OBJ}/_.pkgdir-repo"
	rm -rf "$repodir"
	mkdir -p "$repodir"
	for pkgfile in "${NANO_PACKAGE_DIR}"/*.pkg "${NANO_PACKAGE_DIR}"/*.txz; do
		[ -f "$pkgfile" ] && ln -sf "$pkgfile" "$repodir/"
	done
	pkg_cmd repo "$repodir"

	cat > "$(nano_pkg_repos_dir)/NanoBSD-pkgdir.conf" <<EOF
NanoBSD-pkgdir: {
  url: "file://${repodir}",
  enabled: yes
}
EOF
	tgt_pkg update -r NanoBSD-pkgdir

	# Resolve the full dependency graph against the directory alone and
	# report anything missing before touching the image
	if ! tgt_pkg install -n -r NanoBSD-pkgdir "$@" \
	    > "${NANO_OBJ}/_.pkgdir-check" 2>&1; then
		cat "${NANO_OBJ}/_.pkgdir-check" >&2
		err "NANO_PACKAGE_DIR '${NANO_PACKAGE_DIR}' is missing packages" \
		    "or dependencies (see above)."
	fi

	tgt_pkg install -U -r NanoBSD-pkgdir "$@"
	rm -f "$(nano_pkg_repos_dir)/NanoBSD-pkgdir.conf"
}

#
# Download the requested packages and their dependencies from the online
# FreeBSD-ports repository into the local cache and install them.
# Input: $@ = package list
#
cust_pkgng_online() {
	if $do_clean; then
		tgt_pkg install -F "$@"
	fi
	tgt_pkg install "$@"
}
