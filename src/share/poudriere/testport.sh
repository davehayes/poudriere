#!/bin/sh
# 
# Copyright (c) 2010-2013 Baptiste Daroussin <bapt@FreeBSD.org>
# Copyright (c) 2010-2011 Julien Laffaye <jlaffaye@FreeBSD.org>
# Copyright (c) 2012-2013 Bryan Drewery <bdrewery@FreeBSD.org>
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
set -e

usage() {
	echo "poudriere testport [parameters] [options]

Parameters:
    -o origin   -- Specify an origin in the portstree

Options:
    -c          -- Run make config for the given port
    -J n        -- Run n jobs in parallel for dependencies
    -j name     -- Run inside the given jail
    -i          -- Interactive mode. Enter jail for interactive testing and automatically cleanup when done.
    -I          -- Advanced Interactive mode. Leaves jail running with port installed after test.
    -n          -- No custom prefix
    -p tree     -- Specify the path to the portstree
    -s          -- Skip sanity checks
    -v          -- Be verbose; show more information. Use twice to enable debug output
    -z set      -- Specify which SET to use"
	exit 1
}

SCRIPTPATH=`realpath $0`
SCRIPTPREFIX=`dirname ${SCRIPTPATH}`
CONFIGSTR=0
. ${SCRIPTPREFIX}/common.sh
NOPREFIX=0
SETNAME=""
SKIPSANITY=0
INTERACTIVE_MODE=0
PTNAME="default"

while getopts "o:cnj:J:iIp:svz:" FLAG; do
	case "${FLAG}" in
		c)
			CONFIGSTR=1
			;;
		o)
			ORIGIN=${OPTARG}
			;;
		n)
			NOPREFIX=1
			;;
		j)
			jail_exists ${OPTARG} || err 1 "No such jail: ${OPTARG}"
			JAILNAME="${OPTARG}"
			;;
		J)
			PARALLEL_JOBS=${OPTARG}
			;;
		i)
			INTERACTIVE_MODE=1
			;;
		I)
			INTERACTIVE_MODE=2
			;;
		p)
			PTNAME=${OPTARG}
			;;
		s)
			SKIPSANITY=1
			;;
		z)
			[ -n "${OPTARG}" ] || err 1 "Empty set name"
			SETNAME="${OPTARG}"
			;;
		v)
			VERBOSE=$((${VERBOSE:-0} + 1))
			;;
		*)
			usage
			;;
	esac
done

[ -z ${ORIGIN} ] && usage

export SKIPSANITY

[ -z "${JAILNAME}" ] && err 1 "Don't know on which jail to run please specify -j"
porttree_exists ${PTNAME} || err 2 "No such ports tree ${PTNAME}"

MASTERNAME=${JAILNAME}-${PTNAME}${SETNAME:+-${SETNAME}}
MASTERMNT=${POUDRIERE_DATA}/build/${MASTERNAME}/ref
export MASTERNAME
export MASTERMNT
export POUDRIERE_BUILD_TYPE=bulk

jail_start ${JAILNAME} ${PTNAME} ${SETNAME}

[ $CONFIGSTR -eq 1 ] && injail env TERM=${SAVED_TERM} make -C /usr/ports/${ORIGIN} config

LISTPORTS=$(list_deps ${ORIGIN} )
prepare_ports

log=$(log_path)

POUDRIERE_BUILD_TYPE=bulk parallel_build ${JAILNAME} ${PTNAME} ${SETNAME}
if [ $(bget stats_failed) -gt 0 ] || [ $(bget stats_skipped) -gt 0 ]; then
	failed=$(bget ports.failed | awk '{print $1 ":" $3 }' | xargs echo)
	skipped=$(bget ports.skipped | awk '{print $1}' | sort -u | xargs echo)

	cleanup

	msg "Depends failed to build"
	msg "Failed ports: ${failed}"
	[ -n "${skipped}" ] && 	msg "Skipped ports: ${skipped}"

	exit 1
fi


bset status "testing:"

PKGNAME=`injail make -C /usr/ports/${ORIGIN} -VPKGNAME`
LOCALBASE=`injail make -C /usr/ports/${ORIGIN} -VLOCALBASE`
: ${PREFIX:=$(injail make -C /usr/ports/${ORIGIN} -VPREFIX)}
if [ "${USE_PORTLINT}" = "yes" ]; then
	[ ! -x `which portlint` ] &&
		err 2 "First install portlint if you want USE_PORTLINT to work as expected"
	msg "Portlint check"
	set +e
	cd ${MASTERMNT}/usr/ports/${ORIGIN} &&
		PORTSDIR="${MASTERMNT}/usr/ports" portlint -C | \
		tee ${log}/logs/${PKGNAME}.portlint.log
	set -e
fi
[ ${NOPREFIX} -ne 1 ] && PREFIX="${BUILDROOT:-/prefix}/`echo ${PKGNAME} | tr '[,+]' _`"
[ "${PREFIX}" != "${LOCALBASE}" ] && PORT_FLAGS="PREFIX=${PREFIX}"
msg "Building with flags: ${PORT_FLAGS}"

if [ -d ${MASTERMNT}${PREFIX} -a "${PREFIX}" != "/usr" ]; then
	msg "Removing existing ${PREFIX}"
	[ "${PREFIX}" != "${LOCALBASE}" ] && rm -rf ${MASTERMNT}${PREFIX}
fi

PKGENV="PACKAGES=/tmp/pkgs PKGREPOSITORY=/tmp/pkgs"
mkdir -p ${MASTERMNT}/tmp/pkgs
[ ${PKGNG} -eq 0 ] && injail mkdir -p ${PREFIX}
PORTTESTING=yes
export DEVELOPER_MODE=yes
export NO_WARNING_PKG_INSTALL_EOL=yes
sed -i '' '/DISABLE_MAKE_JOBS=poudriere/d' ${MASTERMNT}/etc/make.conf
log_start
buildlog_start /usr/ports/${ORIGIN}
if ! build_port /usr/ports/${ORIGIN}; then
	failed_status=$(bget status)
	failed_phase=${failed_status%:*}

	save_wrkdir ${MASTERMNT} "${PKGNAME}" "/usr/ports/${ORIGIN}" "${failed_phase}" || :

	ln -s ../${PKGNAME}.log ${log}/logs/errors/${PKGNAME}.log
	badd ports.failed "${ORIGIN} ${PKGNAME} ${failed_phase} ${errortype}"
	update_stats

	if [ ${INTERACTIVE_MODE} -eq 0 ]; then
		stop_build /usr/ports/${ORIGIN}
		err 1 "Build failed in phase: ${failed_phase}"
	fi
else
	badd ports.built "${ORIGIN} ${PKGNAME}"
	if [ -f ${MASTERMNT}/usr/ports/${ORIGIN}/.keep ]; then
		save_wrkdir ${MASTERMNT} "${PKGNAME}" "/usr/ports/${ORIGIN}" \
		    "noneed" || :
	fi
	update_stats
fi

if [ -f ${MASTERMNT}/tmp/pkgs/${PKGNAME}.${PKG_EXT} ]; then
	msg "Installing from package"
	injail ${PKG_ADD} /tmp/pkgs/${PKGNAME}.${PKG_EXT} || :
fi

# Interactive test mode
if [ $INTERACTIVE_MODE -gt 0 ]; then
	print_phase_header "Interactive"

	# Stop the tee process and stop redirecting stdout so that
	# the terminal can be properly used in the jail
	log_stop

	msg "Installing run-depends"
	# Install run-depends since this is an interactive test
	echo "PACKAGES=/packages" >> ${MASTERMNT}/etc/make.conf
	echo "127.0.0.1 ${MASTERNAME}" >> ${MASTERMNT}/etc/hosts
	injail make -C /usr/ports/${ORIGIN} run-depends ||
		msg "Failed to install RUN_DEPENDS"

	# Enable networking
	jstop
	jstart 1

	# Create a pkgng repo configuration, and disable FreeBSD
	if [ ${PKGNG} -eq 1 ]; then
		msg "Installing local Pkg repository to ${LOCALBASE}/etc/pkg/repos"
		mkdir -p ${MASTERMNT}${LOCALBASE}/etc/pkg/repos
		cat > ${MASTERMNT}${LOCALBASE}/etc/pkg/repos/local.conf << EOF
FreeBSD: {
	enabled: no
}

local: {
	url: "file:///packages",
	enabled: yes
}
EOF
	fi

	if [ $INTERACTIVE_MODE -eq 1 ]; then
		msg "Entering interactive test mode. Type 'exit' when done."
		injail env -i TERM=${SAVED_TERM} \
			/usr/bin/login -fp root
		[ -z "${failed_phase}" ] || err 1 "Build failed in phase: ${failed_phase}"
	elif [ $INTERACTIVE_MODE -eq 2 ]; then
		msg "Leaving jail ${MASTERNAME} running, mounted at ${MASTERMNT} for interactive run testing"
		msg "To enter jail: jexec ${MASTERNAME} env -i TERM=\$TERM /usr/bin/login -fp root"
		msg "To stop jail: poudriere jail -k -j ${MASTERNAME}"
		CLEANED_UP=1
		exit 0
	fi
	print_phase_footer
fi

msg "Cleaning up"
injail make -C /usr/ports/${ORIGIN} clean

msg "Deinstalling package"
injail ${PKG_DELETE} ${PKGNAME}

stop_build /usr/ports/${ORIGIN}

cleanup
set +e

exit 0
