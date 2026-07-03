#!/bin/sh
#
# Copyright (c) 2005.
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

#######################################################################
# Poudriere variables and helpers
#
# Sourced unconditionally by nanobsd.sh.  cust_pkgng() in customize.subr
# calls _nano_poudriere_build() when NANO_PKGLIST is set.

NANO_PKGLIST=""				        # path to pkglist file (ports origins, one per line)
NANO_POUDRIERE_JAIL="nanobsd"		# poudriere jail name
NANO_POUDRIERE_PORTS="latest"		# poudriere ports tree name
NANO_POUDRIERE_ZPOOL=""			    # ZFS pool for poudriere (required when NANO_PKGLIST set)
NANO_POUDRIERE_DATA="/usr/local/poudriere/data"
NANO_POUDRIERE_CONF="/usr/local/etc/poudriere.conf"
NANO_POUDRIERE_PORTS_URL="https://github.com/freebsd/freebsd-ports.git"
NANO_POUDRIERE_PORTS_BRANCH="main"

# Set NANO_POUDRIERE_CONF with the required ZPOOL and BUILD_AS_NON_ROOT settings
_nano_poudriere_conf() {
	local conf="${NANO_POUDRIERE_CONF}"

	if [ ! -f "${conf}" ]; then
		if [ -f "${conf}.sample" ]; then
			cp "${conf}.sample" "${conf}"
		else
			touch "${conf}"
		fi
	fi

	# Set/replace ZPOOL line
	if grep -q '^#\{0,1\}ZPOOL=' "${conf}" 2>/dev/null; then
		sed -i '' "s|^#\{0,1\}ZPOOL=.*|ZPOOL=${NANO_POUDRIERE_ZPOOL}|" "${conf}"
	else
		echo "ZPOOL=${NANO_POUDRIERE_ZPOOL}" >> "${conf}"
	fi

	# Set/replace BUILD_AS_NON_ROOT line
	if grep -q '^#\{0,1\}BUILD_AS_NON_ROOT=' "${conf}" 2>/dev/null; then
		sed -i '' 's|^#\{0,1\}BUILD_AS_NON_ROOT=.*|BUILD_AS_NON_ROOT=no|' "${conf}"
	else
		echo "BUILD_AS_NON_ROOT=no" >> "${conf}"
	fi
}

# Build ports packages via Poudriere using NANO_WORLDDIR as the null-mounted jail base.
_nano_poudriere_build() {
	if ! command -v poudriere > /dev/null 2>&1; then
		err "poudriere not found; install ports-mgmt/poudriere-devel"
	fi
	if [ ! -f "${NANO_PKGLIST}" ]; then
		err "NANO_PKGLIST=${NANO_PKGLIST} not found"
	fi
	if [ -z "${NANO_POUDRIERE_ZPOOL}" ]; then
		err "NANO_POUDRIERE_ZPOOL must be set for Poudriere build"
	fi

	pprint 2 "poudriere: configure ${NANO_POUDRIERE_CONF}"
	_nano_poudriere_conf

	mkdir -p /usr/ports/distfiles

	# Derive the OS release string from the installed world
	local _ver
	_ver=$(chroot ${NANO_WORLDDIR} /bin/freebsd-version -u 2>/dev/null || uname -r)

	# Create poudriere jail (null-mounted from NANO_WORLDDIR)
	if poudriere jail -l -q 2>/dev/null | awk '{print $1}' | grep -qx "${NANO_POUDRIERE_JAIL}"; then
		pprint 2 "poudriere jail ${NANO_POUDRIERE_JAIL} already exists, skipping creation"
	else
		pprint 2 "poudriere: create jail ${NANO_POUDRIERE_JAIL} from ${NANO_WORLDDIR} (${_ver})"
		poudriere jail -c \
		    -j "${NANO_POUDRIERE_JAIL}" \
		    -M "${NANO_WORLDDIR}" \
		    -m null \
		    -v "${_ver}"
	fi

	# Create ports tree
	if poudriere ports -l -q 2>/dev/null | awk '{print $1}' | grep -qx "${NANO_POUDRIERE_PORTS}"; then
		pprint 2 "poudriere ports tree ${NANO_POUDRIERE_PORTS} already exists, skipping creation"
	else
		pprint 2 "poudriere: create ports tree ${NANO_POUDRIERE_PORTS}"
		poudriere ports -c \
		    -U "${NANO_POUDRIERE_PORTS_URL}" \
		    -B "${NANO_POUDRIERE_PORTS_BRANCH}" \
		    -p "${NANO_POUDRIERE_PORTS}"
	fi

	# Build packages
	pprint 2 "poudriere: bulk build from ${NANO_PKGLIST}"
	poudriere bulk \
	    -j "${NANO_POUDRIERE_JAIL}" \
	    -b "${NANO_POUDRIERE_PORTS}" \
	    -p "${NANO_POUDRIERE_PORTS}" \
	    -f "${NANO_PKGLIST}"

	NANO_PACKAGE_DIR="${NANO_POUDRIERE_DATA}/packages/${NANO_POUDRIERE_JAIL}-${NANO_POUDRIERE_PORTS}/All"
	pprint 2 "poudriere: packages in ${NANO_PACKAGE_DIR}"
}
