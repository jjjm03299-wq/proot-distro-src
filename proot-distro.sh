#!/@TERMUX_PREFIX@/bin/bash
##
## Script for managing proot'ed Linux distribution installations in Termux.
##
## This program is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program. If not, see <http://www.gnu.org/licenses/>.
##

PROGRAM_VERSION="3.0.3"

#############################################################################
#
# GLOBAL ENVIRONMENT AND INSTALLATION-SPECIFIC CONFIGURATION
#

set -e -u

PROGRAM_NAME="proot-distro"

# Where distribution plug-ins are stored.
DISTRO_PLUGINS_DIR="@TERMUX_PREFIX@/etc/proot-distro"
# Base directory where script keeps runtime data.
RUNTIME_DIR="@TERMUX_PREFIX@/var/lib/proot-distro"
# Where rootfs tarballs are downloaded.
DOWNLOAD_CACHE_DIR="${RUNTIME_DIR}/dlcache"
# Where extracted rootfs are stored.
INSTALLED_ROOTFS_DIR="${RUNTIME_DIR}/installed-rootfs"
# Security PIN files
PIN_FILE="${RUNTIME_DIR}/pin.lock"
PIN_LOCKOUT_FILE="${RUNTIME_DIR}/pin.lockout"
MAX_ATTEMPTS=3
LOCKOUT_DURATION=28800 # 8 hours in seconds

# Colors.
if [ -n "$(command -v tput)" ] && [ $(tput colors) -ge 8 ] && [ -z "${PROOT_DISTRO_FORCE_NO_COLORS-}" ]; then
	RST="$(tput sgr0)"
	RED="${RST}$(tput setaf 1)"
	BRED="${RST}$(tput bold)$(tput setaf 1)"
	GREEN="${RST}$(tput setaf 2)"
	YELLOW="${RST}$(tput setaf 3)"
	BYELLOW="${RST}$(tput bold)$(tput setaf 3)"
	BLUE="${RST}$(tput setaf 4)"
	CYAN="${RST}$(tput setaf 6)"
	BCYAN="${RST}$(tput bold)$(tput setaf 6)"
	ICYAN="${RST}$(tput sitm)$(tput setaf 6)"
else
	RED=""
	BRED=""
	GREEN=""
	YELLOW=""
	BYELLOW=""
	BLUE=""
	CYAN=""
	BCYAN=""
	ICYAN=""
	RST=""
fi

# Disable termux-exec or other things which may interfere with proot.
# It is expected that all dependencies have fixed hardcoded paths according
# to Termux file system layout.
unset LD_PRELOAD

#############################################################################
#
# FUNCTION TO PRINT A MESSAGE TO CONSOLE
#
# Prints a given text string to stderr. Handles escape sequences.
msg() {
	echo -e "$@" >&2
}

#############################################################################
#
# ANTI-ROOT FUSE
#
# This script should never be executed as root as can mess up the ownership,
# and SELinux labels in $PREFIX.
#
if [ "$(id -u)" = "0" ]; then
	msg
	msg "${BRED}Error: utility '${YELLOW}${PROGRAM_NAME}${BRED}' should not be used as root.${RST}"
	msg
	exit 1
fi

#############################################################################
#
# PIN LOCK SECURITY FUNCTIONS
#

check_pin_lockout() {
	if [ -f "$PIN_LOCKOUT_FILE" ]; then
		local lockout_time
		lockout_time=$(cat "$PIN_LOCKOUT_FILE")
		local current_time
		current_time=$(date +%s)
		local elapsed=$((current_time - lockout_time))
		if [ $elapsed -lt $LOCKOUT_DURATION ]; then
			local remaining=$(( (LOCKOUT_DURATION - elapsed) / 3600 ))
			[ $remaining -le 0 ] && remaining=1
			msg
			msg "${BRED}Too many failed attempts. Try again in approximately ${remaining} hour(s).${RST}"
			msg
			exit 1
		else
			rm -f "$PIN_LOCKOUT_FILE"
		fi
	fi
}

verify_pin() {
	if [ ! -f "$PIN_FILE" ]; then
		return 0
	fi

	check_pin_lockout

	local attempts=0
	local stored_hash
	stored_hash=$(cat "$PIN_FILE")

	while [ $attempts -lt $MAX_ATTEMPTS ]; do
		msg
		read -s -p "Enter PIN to login: " entered_pin
		echo ""
		local hashed_input
		hashed_input=$(echo -n "$entered_pin" | sha256sum | awk '{print $1}')

		if [ "$hashed_input" = "$stored_hash" ]; then
			msg "${GREEN}PIN verified successfully.${RST}"
			return 0
		else
			attempts=$((attempts + 1))
			local left=$((MAX_ATTEMPTS - attempts))
			msg "${BRED}Incorrect PIN. Attempts remaining: ${left}${RST}"
		fi
	done

	date +%s > "$PIN_LOCKOUT_FILE"
	msg
	msg "${BRED}Too many failed attempts try again in 8 hours.${RST}"
	msg
	exit 1
}

command_set_pin() {
	msg
	msg "${CYAN}--- Configure System PIN Lock ---${RST}"
	while true; do
		read -s -p "Enter new PIN: " pin1
		echo ""
		read -s -p "Confirm new PIN: " pin2
		echo ""
		if [ "$pin1" = "$pin2" ]; then
			if [ -z "$pin1" ]; then
				msg "${BRED}Error: PIN cannot be empty.${RST}"
				continue
			fi
			if [ ! -d "$RUNTIME_DIR" ]; then
				mkdir -p "$RUNTIME_DIR"
			fi
			echo -n "$pin1" | sha256sum | awk '{print $1}' > "$PIN_FILE"
			chmod 600 "$PIN_FILE"
			msg "${GREEN}PIN successfully configured and saved.${RST}"
			break
		else
			msg "${BRED}Error: PINs do not match. Please try again.${RST}"
		fi
	done
}

command_remove_pin() {
	verify_pin
	if [ -f "$PIN_FILE" ]; then
		rm -f "$PIN_FILE"
		msg "${GREEN}PIN protection removed.${RST}"
	else
		msg "${YELLOW}No PIN is currently set.${RST}"
	fi
}

#############################################################################
#
# FUNCTION TO CHECK WHETHER DISTRIBUTION IS INSTALLED
#
# This is done by checking the presence of /bin directory in rootfs.
#
# Accepted arguments: $1 - name of distribution.
#
is_distro_installed() {
	if [ -e "${INSTALLED_ROOTFS_DIR}/${1}/bin" ]; then
		return 0
	else
		return 1
	fi
}

#############################################################################
#
# FUNCTION TO INSTALL THE SPECIFIED DISTRIBUTION
#
command_install() {
	verify_pin
	local distro_name
	local override_alias
	local distro_plugin_script
	while (($# >= 1)); do
		case "$1" in
			--)
				shift 1
				break
				;;
			--help)
				command_install_help
				return 0
				;;
			--override-alias)
				if [ $# -ge 2 ]; then
					shift 1
					if [ -z "$1" ]; then
						msg
						msg "${BRED}Error: argument to option '${YELLOW}--override-alias${BRED}' should not be empty.${RST}"
						command_install_help
						return 1
					fi
					if ! grep -qP '^[a-z0-9._+][a-z0-9._+-]+$' <<< "$1"; then
						msg
						msg "${BRED}Error: argument to option '${YELLOW}--override-alias${BRED}' should be lowercase and can contain only alphanumeric characters and these symbols '._+-'. Also argument should not begin with '-'.${RST}"
						msg
						return 1
					fi
					if grep -qP '^.*\.sh$' <<< "$1"; then
						msg
						msg "${BRED}Error: argument to option '${YELLOW}--override-alias${BRED}' should not end with '.sh'.${RST}"
						msg
						return 1
					fi
					override_alias="$1"
				else
					msg
					msg "${BRED}Error: option '${YELLOW}$1${BRED}' requires an argument.${RST}"
					command_install_help
					return 1
				fi
				;;
			-*)
				msg
				msg "${BRED}Error: unknown option '${YELLOW}${1}${BRED}'.${RST}"
				command_install_help
				return 1
				;;
			*)
				if [ -z "${distro_name-}" ]; then
					distro_name="$1"
				else
					msg
					msg "${BRED}Error: unknown option '${YELLOW}${1}${BRED}'.${RST}"
					msg
					msg "${BRED}Error: you have already set distribution as '${YELLOW}${distro_name}${BRED}'.${RST}"
					command_install_help
					return 1
				fi
				;;
		esac
		shift 1
	done
	if [ -z "${distro_name-}" ]; then
		msg
		msg "${BRED}Error: distribution alias is not specified.${RST}"
		command_install_help
		return 1
	fi
	if [ -z "${SUPPORTED_DISTRIBUTIONS["$distro_name"]+x}" ]; then
		msg
		msg "${BRED}Error: unknown distribution '${YELLOW}${distro_name}${BRED}' was requested to be installed.${RST}"
		msg
		msg "${CYAN}Run '${GREEN}${PROGRAM_NAME} list${CYAN}' to see the supported distributions.${RST}"
		msg
		return 1
	fi
	if [ -n "${override_alias-}" ]; then
		if [ ! -e "${DISTRO_PLUGINS_DIR}/${override_alias}.sh" ] && [ ! -e "${DISTRO_PLUGINS_DIR}/${override_alias}.override.sh" ]; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Creating file '${DISTRO_PLUGINS_DIR}/${override_alias}.override.sh'...${RST}"
			distro_plugin_script="${DISTRO_PLUGINS_DIR}/${override_alias}.override.sh"
			cp "${DISTRO_PLUGINS_DIR}/${distro_name}.sh" "${distro_plugin_script}"
			sed -i "s/^\(DISTRO_NAME=\)\(.*\)\$/\1\"${SUPPORTED_DISTRIBUTIONS["$distro_name"]} - ${override_alias}\"/g" "${distro_plugin_script}"
			SUPPORTED_DISTRIBUTIONS["${override_alias}"]="${SUPPORTED_DISTRIBUTIONS["$distro_name"]}"
			distro_name="${override_alias}"
		else
			msg
			msg "${BRED}Error: you cannot use value '${YELLOW}${override_alias}${BRED}' as alias override.${RST}"
			msg
			return 1
		fi
	else
		distro_plugin_script="${DISTRO_PLUGINS_DIR}/${distro_name}.sh"
		if [ ! -f "${distro_plugin_script}" ]; then
			distro_plugin_script="${DISTRO_PLUGINS_DIR}/${distro_name}.override.sh"
		fi
	fi
	if is_distro_installed "$distro_name"; then
		msg
		msg "${BRED}Error: distribution '${YELLOW}${distro_name}${BRED}' is already installed.${RST}"
		msg
		msg "${CYAN}Log in: ${GREEN}${PROGRAM_NAME} login ${distro_name}${RST}"
		msg "${CYAN}Reinstall: ${GREEN}${PROGRAM_NAME} reset ${distro_name}${RST}"
		msg "${CYAN}Uninstall: ${GREEN}${PROGRAM_NAME} remove ${distro_name}${RST}"
		msg
		return 1
	fi
	if [ -f "${distro_plugin_script}" ]; then
		if ! grep -q 'tar (GNU tar)' <(tar --version 2>/dev/null | head -n 1); then
			msg
			msg "${BRED}Warning: tar binary that is available in PATH appears to be not a GNU tar. You may experience issues during installation, backup and restore operations.${RST}"
			msg
		fi
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Installing ${YELLOW}${SUPPORTED_DISTRIBUTIONS["$distro_name"]}${CYAN}...${RST}"
		if [ ! -d "${INSTALLED_ROOTFS_DIR}/${distro_name}" ]; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Creating directory '${INSTALLED_ROOTFS_DIR}/${distro_name}'...${RST}"
			mkdir -m 755 -p "${INSTALLED_ROOTFS_DIR}/${distro_name}"
		fi
		if [ -d "${INSTALLED_ROOTFS_DIR}/${distro_name}/.l2s" ]; then
			export PROOT_L2S_DIR="${INSTALLED_ROOTFS_DIR}/${distro_name}/.l2s"
		fi
		TARBALL_URL["aarch64"]=""
		TARBALL_URL["arm"]=""
		TARBALL_URL["i686"]=""
		TARBALL_URL["x86_64"]=""
		TARBALL_SHA256["aarch64"]=""
		TARBALL_SHA256["arm"]=""
		TARBALL_SHA256["i686"]=""
		TARBALL_SHA256["x86_64"]=""
		TARBALL_STRIP_OPT=1
		source "${distro_plugin_script}"
		if [ -z "${TARBALL_URL["$DISTRO_ARCH"]}" ]; then
			msg "${BLUE}[${RED}!${BLUE}] ${CYAN}Sorry, but distribution download URL is not defined for CPU architecture '$DISTRO_ARCH'.${RST}"
			return 1
		fi
		if ! grep -qP '^[0-9a-fA-F]+$' <<< "${TARBALL_SHA256["$DISTRO_ARCH"]}"; then
			msg
			msg "${BRED}Error: got malformed SHA-256 from ${distro_plugin_script}${RST}"
			msg
			return 1
		fi
		if [ ! -d "$DOWNLOAD_CACHE_DIR" ]; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Creating directory '$DOWNLOAD_CACHE_DIR'...${RST}"
			mkdir -p "$DOWNLOAD_CACHE_DIR"
		fi
		local tarball_name
		tarball_name=$(basename "${TARBALL_URL["$DISTRO_ARCH"]}")
		if [ ! -f "${DOWNLOAD_CACHE_DIR}/${tarball_name}" ]; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Downloading rootfs tarball...${RST}"
			msg
			rm -f "${DOWNLOAD_CACHE_DIR}/${tarball_name}.tmp"
			if ! curl --fail --retry 5 --retry-connrefused --retry-delay 5 --location \
				--output "${DOWNLOAD_CACHE_DIR}/${tarball_name}.tmp" "${TARBALL_URL["$DISTRO_ARCH"]}"; then
				msg "${BLUE}[${RED}!${BLUE}] ${CYAN}Download failure, please check your network connection.${RST}"
				rm -f "${DOWNLOAD_CACHE_DIR}/${tarball_name}.tmp"
				return 1
			fi
			msg
			mv -f "${DOWNLOAD_CACHE_DIR}/${tarball_name}.tmp" "${DOWNLOAD_CACHE_DIR}/${tarball_name}"
		else
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Using cached rootfs tarball...${RST}"
		fi
		if [ -n "${TARBALL_SHA256["$DISTRO_ARCH"]}" ]; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Checking integrity, please wait...${RST}"
			local actual_sha256
			actual_sha256=$(sha256sum "${DOWNLOAD_CACHE_DIR}/${tarball_name}" | awk '{ print $1}')
			if [ "${TARBALL_SHA256["$DISTRO_ARCH"]}" != "${actual_sha256}" ]; then
				msg "${BLUE}[${RED}!${BLUE}] ${CYAN}Integrity checking failed. Try to redo installation again.${RST}"
				rm -f "${DOWNLOAD_CACHE_DIR}/${tarball_name}"
				return 1
			fi
		else
			msg "${BLUE}[${RED}!${BLUE}] ${CYAN}Integrity checking of downloaded rootfs has been disabled.${RST}"
		fi
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Extracting rootfs, please wait...${RST}"
		proot --link2symlink \
			tar -C "${INSTALLED_ROOTFS_DIR}/${distro_name}" --warning=no-unknown-keyword \
			--delay-directory-restore --preserve-permissions --strip="$TARBALL_STRIP_OPT" \
			-xf "${DOWNLOAD_CACHE_DIR}/${tarball_name}" --exclude='dev'||:
		local profile_script
		if [ -d "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/profile.d" ]; then
			profile_script="${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/profile.d/termux-proot.sh"
		else
			chmod u+rw "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/profile" >/dev/null 2>&1 || true
			profile_script="${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/profile"
		fi
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Writing '$profile_script'...${RST}"
		local LIBGCC_S_PATH
		LIBGCC_S_PATH="/$(cd ${INSTALLED_ROOTFS_DIR}/${distro_name}; find usr/lib/ -name libgcc_s.so.1)"
		cat <<- EOF >> "$profile_script"
		export ANDROID_ART_ROOT=${ANDROID_ART_ROOT-}
		export ANDROID_DATA=${ANDROID_DATA-}
		export ANDROID_I18N_ROOT=${ANDROID_I18N_ROOT-}
		export ANDROID_ROOT=${ANDROID_ROOT-}
		export ANDROID_RUNTIME_ROOT=${ANDROID_RUNTIME_ROOT-}
		export ANDROID_TZDATA_ROOT=${ANDROID_TZDATA_ROOT-}
		export BOOTCLASSPATH=${BOOTCLASSPATH-}
		export COLORTERM=${COLORTERM-}
		export DEX2OATBOOTCLASSPATH=${DEX2OATBOOTCLASSPATH-}
		export EXTERNAL_STORAGE=${EXTERNAL_STORAGE-}
		[ -z "\$LANG" ] && export LANG=C.UTF-8
		export PATH=\${PATH}:@TERMUX_PREFIX@/bin:/system/bin:/system/xbin
		export TERM=${TERM-xterm-256color}
		export TMPDIR=/tmp
		export PULSE_SERVER=127.0.0.1
		export MOZ_FAKE_NO_SANDBOX=1
		EOF
		if [ "${LIBGCC_S_PATH}" != "/" ]; then
			echo "${LIBGCC_S_PATH}" >> "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/ld.so.preload"
			chmod 644 "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/ld.so.preload"
		fi
		unset LIBGCC_S_PATH
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Writing resolv.conf file (NS 1.1.1.1/1.0.0.1)...${RST}"
		rm -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/resolv.conf"
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/resolv.conf"
		nameserver 1.1.1.1
		nameserver 1.0.0.1
		EOF
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Writing hosts file...${RST}"
		chmod u+rw "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/hosts" >/dev/null 2>&1 || true
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/hosts"
		# IPv4.
		127.0.0.1 localhost.localdomain localhost
		# IPv6.
		::1 localhost.localdomain localhost ip6-localhost ip6-loopback
		fe00::0 ip6-localnet
		ff00::0 ip6-mcastprefix
		ff02::1 ip6-allnodes
		ff02::2 ip6-allrouters
		ff02::3 ip6-allhosts
		EOF
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Registering Android-specific UIDs and GIDs...${RST}"
		chmod u+rw "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/passwd" \
			"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/shadow" \
			"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/group" \
			"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/gshadow" >/dev/null 2>&1 || true
		echo "aid_$(id -un):x:$(id -u):$(id -g):Android user:/:/sbin/nologin" >> \
			"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/passwd"
		echo "aid_$(id -un):*:18446:0:99999:7:::" >> \
			"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/shadow"
		local group_name group_id
		while read -r group_name group_id; do
			echo "aid_${group_name}:x:${group_id}:root,aid_$(id -un)" >> \
				"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/group"
			if [ -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/gshadow" ]; then
				echo "aid_${group_name}:*::root,aid_$(id -un)" >> \
					"${INSTALLED_ROOTFS_DIR}/${distro_name}/etc/gshadow"
			fi
		done < <(paste <(id -Gn | tr ' ' '\n') <(id -G | tr ' ' '\n'))
		setup_fake_proc
		if declare -f -F distro_setup >/dev/null 2>&1; then
			msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Running distro-specific configuration steps...${RST}"
			(cd "${INSTALLED_ROOTFS_DIR}/${distro_name}"
				distro_setup
			)
		fi
		msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Installation finished.${RST}"
		msg
		msg "${CYAN}Now run '${GREEN}$PROGRAM_NAME login $distro_name${CYAN}' to log in.${RST}"
		msg
		return 0
	else
		msg "${BLUE}[${RED}!${BLUE}] ${CYAN}Cannot find '${distro_plugin_script}' which contains distro-specific install functions.${RST}"
		return 1
	fi
}

# Special function for executing a command in rootfs.
run_proot_cmd() {
	if [ -z "${distro_name-}" ]; then
		msg
		msg "${BRED}Error: called run_proot_cmd() but \${distro_name} is not set. Possible cause: using run_proot_cmd() outside of distro_setup()?${RST}"
		msg
		return 1
	fi
	if [ -z "${DISTRO_ARCH-}" ]; then
		msg
		msg "${BRED}Error: called run_proot_cmd() but \${DISTRO_ARCH} is not set.${RST}"
		msg
		return 1
	fi
	local qemu_arg=""
	if [ "$DISTRO_ARCH" != "$DEVICE_CPU_ARCH" ]; then
		local qemu_bin_path=""
		case "$DISTRO_ARCH" in
			aarch64) qemu_bin_path="@TERMUX_PREFIX@/bin/qemu-aarch64";;
			arm)
				if [ "$DEVICE_CPU_ARCH" != "aarch64" ]; then
					qemu_bin_path="@TERMUX_PREFIX@/bin/qemu-arm"
				fi
				;;
			i686)
				if [ "$DEVICE_CPU_ARCH" != "x86_64" ]; then
					qemu_bin_path="@TERMUX_PREFIX@/bin/qemu-i386"
				fi
				;;
			x86_64) qemu_bin_path="@TERMUX_PREFIX@/bin/qemu-x86_64";;
			*)
				msg
				msg "${BRED}Error: DISTRO_ARCH has unknown value '$DISTRO_ARCH'. Valid values are: aarch64, arm, i686, x86_64."
				msg
				return 1
			;;
		esac
		if [ -n "$qemu_bin_path" ]; then
			if [ -x "$qemu_bin_path" ]; then
				qemu_arg="-q ${qemu_bin_path}"
			else
				local qemu_user_pkg=""
				case "$DISTRO_ARCH" in
					aarch64) qemu_user_pkg="qemu-user-aarch64";;
					arm) qemu_user_pkg="qemu-user-arm";;
					i686) qemu_user_pkg="qemu-user-i386";;
					x86_64) qemu_user_pkg="qemu-user-x86-64";;
					*) qemu_user_pkg="qemu-user-${DISTRO_ARCH}";;
				esac
				msg
				msg "${BRED}Error: package '${qemu_user_pkg}' is not installed.${RST}"
				msg
				return 1
			fi
		fi
	fi
	if [ -n "$qemu_arg" ]; then
		[ -d "/apex" ] && qemu_arg="${qemu_arg} --bind=/apex"
		[ -e "/linkerconfig/ld.config.txt" ] && qemu_arg="${qemu_arg} --bind=/linkerconfig/ld.config.txt"
		qemu_arg="${qemu_arg} --bind=@TERMUX_PREFIX@"
		qemu_arg="${qemu_arg} --bind=/system"
		qemu_arg="${qemu_arg} --bind=/vendor"
		[ -f "/plat_property_contexts" ] && qemu_arg="${qemu_arg} --bind=/plat_property_contexts"
		[ -f "/property_contexts" ] && qemu_arg="${qemu_arg} --bind=/property_contexts"
	fi
	proot \
		$qemu_arg -L \
		--kernel-release=5.4.0-faked \
		--link2symlink \
		--kill-on-exit \
		--rootfs="${INSTALLED_ROOTFS_DIR}/${distro_name}" \
		--root-id \
		--cwd=/root \
		--bind=/dev \
		--bind="/dev/urandom:/dev/random" \
		--bind=/proc \
		--bind="/proc/self/fd:/dev/fd" \
		--bind="/proc/self/fd/0:/dev/stdin" \
		--bind="/proc/self/fd/1:/dev/stdout" \
		--bind="/proc/self/fd/2:/dev/stderr" \
		--bind=/sys \
		--bind="${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.loadavg:/proc/loadavg" \
		--bind="${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.stat:/proc/stat" \
		--bind="${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.uptime:/proc/uptime" \
		--bind="${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.version:/proc/version" \
		--bind="${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.vmstat:/proc/vmstat" \
		/usr/bin/env -i \
			"HOME=/root" \
			"LANG=C.UTF-8" \
			"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
			"TERM=$TERM" \
			"TMPDIR=/tmp" \
			"$@"
}

setup_fake_proc() {
	mkdir -p "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc"
	chmod 700 "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc"
	if [ ! -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.loadavg" ]; then
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.loadavg"
		0.54 0.41 0.30 1/931 370386
		EOF
	fi
	if [ ! -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.stat" ]; then
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.stat"
		cpu 1050008 127632 898432 43828767 37203 63 99244 0 0 0
		EOF
	fi
	if [ ! -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.uptime" ]; then
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.uptime"
		284684.56 513853.46
		EOF
	fi
	if [ ! -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.version" ]; then
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.version"
		Linux version 5.4.0-faked (termux@androidos) (gcc version 4.9.x (Faked /proc/version by Proot-Distro) ) #1 SMP PREEMPT Fri Jul 10 00:00:00 UTC 2020
		EOF
	fi
	if [ ! -f "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.vmstat" ]; then
		cat <<- EOF > "${INSTALLED_ROOTFS_DIR}/${distro_name}/proc/.vmstat"
		nr_free_pages 146031
		EOF
	fi
}

command_install_help() {
	msg
	msg "${BYELLOW}Usage: ${BCYAN}$PROGRAM_NAME ${GREEN}install ${CYAN}[${GREEN}DISTRIBUTION ALIAS${CYAN}]${RST}"
	msg
	msg "${CYAN}This command will create a fresh installation of specified Linux${RST}"
	msg "${CYAN}distribution.${RST}"
	msg
	msg "${CYAN}Options:${RST}"
	msg " ${GREEN}--help ${CYAN}- Show this help information.${RST}"
	msg " ${GREEN}--override-alias [new alias] ${CYAN}- Set a custom alias for installed distribution.${RST}"
	show_version
	msg
}

command_remove() {
	verify_pin
	local distro_name
	if [ $# -ge 1 ]; then
		case "$1" in
			-h|--help)
				command_remove_help
				return 0
				;;
			*) distro_name="$1";;
		esac
	else
		msg
		msg "${BRED}Error: distribution alias is not specified.${RST}"
		command_remove_help
		return 1
	fi
	if [ -z "${SUPPORTED_DISTRIBUTIONS["$distro_name"]+x}" ]; then
		msg
		msg "${BRED}Error: unknown distribution '${YELLOW}${distro_name}${BRED}' was requested to be removed.${RST}"
		return 1
	fi
	if [ ! -d "${INSTALLED_ROOTFS_DIR}/${distro_name}" ]; then
		msg
		msg "${BRED}Error: distribution '${YELLOW}${distro_name}${BRED}' is not installed.${RST}"
		return 1
	fi
	if [ "${CMD_REMOVE_REQUESTED_RESET-false}" = "false" ] && [ -e "${DISTRO_PLUGINS_DIR}/${distro_name}.override.sh" ]; then
		rm -f "${DISTRO_PLUGINS_DIR}/${distro_name}.override.sh"
	fi
	msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Wiping the rootfs of ${YELLOW}${SUPPORTED_DISTRIBUTIONS["$distro_name"]}${CYAN}...${RST}"
	chmod u+rwx -R "${INSTALLED_ROOTFS_DIR}/${distro_name}" > /dev/null 2>&1 || true
	if ! rm -rf "${INSTALLED_ROOTFS_DIR:?}/${distro_name:?}"; then
		return 1
	fi
}

command_remove_help() {
	msg
	msg "${BYELLOW}Usage: ${BCYAN}$PROGRAM_NAME ${GREEN}remove ${CYAN}[${GREEN}DISTRIBUTION ALIAS${CYAN}]${RST}"
	show_version
	msg
}

command_reset() {
	verify_pin
	local distro_name
	if [ $# -ge 1 ]; then
		case "$1" in
			-h|--help)
				command_reset_help
				return 0
				;;
			*) distro_name="$1";;
		esac
	else
		msg
		msg "${BRED}Error: distribution alias is not specified.${RST}"
		command_reset_help
		return 1
	fi
	CMD_REMOVE_REQUESTED_RESET="true" command_remove "$distro_name"
	command_install "$distro_name"
}

command_reset_help() {
	msg
	msg "${BYELLOW}Usage: ${BCYAN}$PROGRAM_NAME ${GREEN}reset ${CYAN}[${GREEN}DISTRIBUTION ALIAS${CYAN}]${RST}"
	show_version
	msg
}

command_login() {
	verify_pin
	local isolated_environment=false
	local use_termux_home=false
	local no_link2symlink=false
	local no_sysvipc=false
	local no_kill_on_exit=false
	local fix_low_ports=false
	local make_host_tmp_shared=false
	local distro_name=""
	local login_user="root"
	local -a custom_fs_bindings
	local need_qemu=false

	while (($# >= 1)); do
		case "$1" in
			--)
				shift 1
				break
				;;
			--help)
				command_login_help
				return 0
				;;
			--fix-low-ports)
				fix_low_ports=true
				;;
			--isolated)
				isolated_environment=true
				;;
			--termux-home)
				use_termux_home=true
				;;
			--shared-tmp)
				make_host_tmp_shared=true
				;;
			--bind)
				if [ $# -ge 2 ]; then
					shift 1
					custom_fs_bindings+=("$1")
				else
					msg "${BRED}Error: option '--bind' requires an argument.${RST}"
					return 1
				fi
				;;
			--no-link2symlink)
				no_link2symlink=true
				;;
			--no-sysvipc)
				no_sysvipc=true
				;;
			--no-kill-on-exit)
				no_kill_on_exit=true
				;;
			--user)
				if [ $# -ge 2 ]; then
					shift 1
					login_user="$1"
				else
					msg "${BRED}Error: option '--user' requires an argument.${RST}"
					return 1
				fi
				;;
			-*)
				msg "${BRED}Error: unknown option '${1}'.${RST}"
				return 1
				;;
			*)
				if [ -z "$distro_name" ]; then
					distro_name="$1"
				else
					msg "${BRED}Error: multiple distributions provided.${RST}"
					return 1
				fi
				;;
		esac
		shift 1
	done

	if [ -z "$distro_name" ]; then
		msg "${BRED}Error: you should at least specify a distribution in order to log in.${RST}"
		command_login_help
		return 1
	fi

	if is_distro_installed "$distro_name"; then
		if [ -d "${INSTALLED_ROOTFS_DIR}/${distro_name}/.l2s" ]; then
			export PROOT_L2S_DIR="${INSTALLED_ROOTFS_DIR}/${distro_name}/.l2s"
		fi
		if [ $# -ge 1 ]; then
			local -a shell_command_args
			for i in "$@"; do
				shell_command_args+=("'$i'")
			done
			if stat "${INSTALLED_ROOTFS_DIR}/${distro_name}/bin/su" >/dev/null 2>&1; then
				set -- "/bin/su" "-l" "$login_user" "-c" "${shell_command_args[*]}"
			else
				set -- "/bin/bash" "-l" "-c" "${shell_command_args[*]}"
			fi
		else
			if stat "${INSTALLED_ROOTFS_DIR}/${distro_name}/bin/su" >/dev/null 2>&1; then
				set -- "/bin/su" "-l" "$login_user"
			else
				set -- "/bin/bash" "-l"
			fi
		fi
		set -- "/usr/bin/env" "-i" \
			"HOME=/root" \
			"LANG=C.UTF-8" \
			"TERM=${TERM-xterm-256color}" \
			"$@"
		set -- "--rootfs=${INSTALLED_ROOTFS_DIR}/${distro_name}" "$@"
		exec proot "$@"
	else
		msg "${BRED}Error: distribution '${distro_name}' is not installed.${RST}"
		return 1
	fi
}

command_login_help() {
	msg
	msg "${BYELLOW}Usage: ${BCYAN}$PROGRAM_NAME ${GREEN}login ${CYAN}[${GREEN}OPTIONS${CYAN}] [${GREEN}DISTRO ALIAS${CYAN}]${RST}"
	show_version
	msg
}

command_list() {
	msg
	if [ -z "${!SUPPORTED_DISTRIBUTIONS[*]}" ]; then
		msg "${YELLOW}You do not have any distribution plugins configured.${RST}"
	else
		msg "${CYAN}Supported distributions:${RST}"
		local i
		for i in $(echo "${!SUPPORTED_DISTRIBUTIONS[@]}" | tr ' ' '\n' | sort -d); do
			msg
			msg " ${CYAN}* ${YELLOW}${SUPPORTED_DISTRIBUTIONS[$i]}${RST}"
			msg " ${CYAN}Alias: ${YELLOW}${i}${RST}"
			if is_distro_installed "$i"; then
				msg " ${CYAN}Status: ${GREEN}installed${RST}"
			else
				msg " ${CYAN}Status: ${RED}NOT installed${RST}"
			fi
		done
	fi
	msg
}

command_backup() {
	verify_pin
	local distro_name=""
	local tarball_file_path=""
	while (($# >= 1)); do
		case "$1" in
			--output)
				shift 1
				tarball_file_path="$1"
				;;
			*)
				[ -z "$distro_name" ] && distro_name="$1"
				;;
		esac
		shift 1
	done
	if [ -z "$distro_name" ]; then
		msg "${BRED}Error: distribution not specified.${RST}"
		return 1
	fi
	msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Backing up ${distro_name}...${RST}"
	if [ -n "$tarball_file_path" ]; then
		tar -c --auto-compress -f "$tarball_file_path" -C "${INSTALLED_ROOTFS_DIR}/../" "$(basename "$INSTALLED_ROOTFS_DIR")/${distro_name}"
	else
		tar -c -C "${INSTALLED_ROOTFS_DIR}/../" "$(basename "$INSTALLED_ROOTFS_DIR")/${distro_name}"
	fi
}

command_restore() {
	verify_pin
	local tarball_file_path="${1:-}"
	if [ -z "$tarball_file_path" ] && [ -t 0 ]; then
		msg "${BRED}Error: no tarball provided.${RST}"
		return 1
	fi
	msg "${BLUE}[${GREEN}*${BLUE}] ${CYAN}Restoring distribution...${RST}"
	if [ -n "$tarball_file_path" ]; then
		tar -x --auto-compress -f "$tarball_file_path" -C "${INSTALLED_ROOTFS_DIR}/../"
	else
		tar -x -C "${INSTALLED_ROOTFS_DIR}/../"
	fi
}

command_clear_cache() {
	verify_pin
	rm -rf "${DOWNLOAD_CACHE_DIR}"/*
	msg "${GREEN}Download cache cleared.${RST}"
}

command_help() {
	msg
	msg "${BYELLOW}Usage: ${BCYAN}$PROGRAM_NAME${CYAN} [${GREEN}COMMAND${CYAN}] [${GREEN}ARGUMENTS${CYAN}]${RST}"
	msg "${CYAN}Available commands:${RST}"
	msg " ${GREEN}install${CYAN}     - Install a specified distribution."
	msg " ${GREEN}login${CYAN}       - Start login shell for a distribution."
	msg " ${GREEN}remove${CYAN}      - Delete a distribution."
	msg " ${GREEN}reset${CYAN}       - Reinstall a distribution."
	msg " ${GREEN}list${CYAN}        - List supported distributions."
	msg " ${GREEN}set-pin${CYAN}     - Set or update security PIN."
	msg " ${GREEN}remove-pin${CYAN}  - Remove security PIN."
	msg " ${GREEN}backup${CYAN}      - Backup a distribution."
	msg " ${GREEN}restore${CYAN}     - Restore a distribution."
	msg " ${GREEN}clear-cache${CYAN} - Clear cached downloads."
	show_version
	msg
}

show_version() {
	msg "${ICYAN}Proot-Distro v${PROGRAM_VERSION} by Termux (PIN Secured).${RST}"
}

trap 'echo -e "\\r${BLUE}[${RED}!${BLUE}] ${CYAN}Exiting immediately.${RST}"; exit 1;' HUP INT TERM

for i in awk bzip2 curl find gzip proot sed tar xz sha256sum; do
	if [ -z "$(command -v "$i")" ]; then
		msg "${BRED}Utility '${i}' is not installed. Cannot continue.${RST}"
		exit 1
	fi
done

case "$(uname -m)" in
	armv7l|armv8l) DEVICE_CPU_ARCH="arm";;
	*) DEVICE_CPU_ARCH=$(uname -m);;
esac
DISTRO_ARCH=$DEVICE_CPU_ARCH

declare -A TARBALL_URL TARBALL_SHA256
declare -A SUPPORTED_DISTRIBUTIONS
declare -A SUPPORTED_DISTRIBUTIONS_COMMENTS

if [ -d "$DISTRO_PLUGINS_DIR" ]; then
	while read -r filename; do
		distro_name=$(. "$filename"; echo "${DISTRO_NAME-}")
		distro_comment=$(. "$filename"; echo "${DISTRO_COMMENT-}")
		distro_alias=${filename%%.override.sh}
		distro_alias=${distro_alias%%.sh}
		distro_alias=$(basename "$distro_alias")
		if [ -n "$distro_name" ]; then
			SUPPORTED_DISTRIBUTIONS["$distro_alias"]="$distro_name"
			[ -n "$distro_comment" ] && SUPPORTED_DISTRIBUTIONS_COMMENTS["$distro_alias"]="$distro_comment"
		fi
	done < <(find "$DISTRO_PLUGINS_DIR" -maxdepth 1 -type f -iname "*.sh" 2>/dev/null)
fi

if [ $# -ge 1 ]; then
	case "$1" in
		-h|--help|help) shift 1; command_help;;
		install) shift 1; command_install "$@";;
		list) shift 1; command_list;;
		login) shift 1; command_login "$@";;
		remove) shift 1; CMD_REMOVE_REQUESTED_RESET="false" command_remove "$@";;
		reset) shift 1; command_reset "$@";;
		backup) shift 1; command_backup "$@";;
		restore) shift 1; command_restore "$@";;
		clear-cache) shift 1; command_clear_cache "$@";;
		set-pin) shift 1; command_set_pin;;
		remove-pin) shift 1; command_remove_pin;;
		*)
			msg "${BRED}Error: unknown command '${1}'.${RST}"
			command_help
			exit 1
			;;
	esac
else
	msg "${BRED}Error: no command provided.${RST}"
	command_help
fi

exit 0
