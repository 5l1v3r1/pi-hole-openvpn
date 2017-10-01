#!/usr/bin/env bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Completely uninstalls Pi-hole
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

removeLocalDNS() {
  # Remove config lines added in setup 
  sed -i "nameserver 127.0.0.1/d" /etc/resolv.conf
  sed -i "s/# nameserver/nameserver/" /etc/resolv.conf
  
  # Uninstall bind and clean dirs if dummy file present
  if [[ "$OS" = 'debian' ]]; then
    #sed -zi "s/\n\s*listen-on { 127.0.0.1; $PRIV_IP; };\n\s*recursion yes;\n\s*allow-query { localnets; };//" /etc/bind/named.conf.options
    rm /etc/bind/named.conf.options
    mv /etc/bind/named.conf.options.orig /etc/bind/named.conf.options
    if [[ -e "/etc/bind/.del" ]]; then
      apt-get remove -y bind9
      rm -rf /etc/bind
    else
      mv -f /etc/bind/named.conf.options.orig /etc/bind/named.conf.options
    fi
    
    # Remove private interface if it was created with this script
    if [[ -e "/etc/network/.del" ]]; then
      ifdown eth0:1
      rm /etc/network/.del
      sed -zi "s/\n\s*iface eth0:1 inet static\n\saddress 192.168.2.1\n\snetmask 255.255.255.0//" /etc/network/interfaces
    fi
  else
    #sed -zi "s/\n\s*listen-on { 127.0.0.1; $PRIV_IP; };\n\s*recursion yes;\n\s*allow-query { localnets; };//" /etc/named.conf
    rm /etc/named.conf
    mv /etc/named.conf.orig /etc/named.conf
    if [[ -e "/etc/named/.del" ]]; then
      yum remove -y bind bind-utils
      rm -rf /etc/named*
    else
      mv -f /etc/named.conf.orig /etc/named.conf
    fi
    
    if [[ -e /etc/sysconfig/network-scripts/.openvpn.script ]]; then
      ifdown eth0:1
      rm /etc/sysconfig/network-scripts/.openvpn.script
      rm /etc/sysconfig/network-scripts/ifcfg-eth0:1
    fi
  fi
}

# Must be root to uninstall
if [[ ${EUID} -eq 0 ]]; then
	echo "::: You are root."
else
	echo "::: Sudo will be used for the uninstall."
	# Check if it is actually installed
	# If it isn't, exit because the unnstall cannot complete
	if [ -x "$(command -v sudo)" ]; then
		export SUDO="sudo"
	else
		echo "::: Please install sudo or run this as root."
		exit 1
	fi
fi

# Compatability
if [ -x "$(command -v rpm)" ]; then
	# Fedora Family
	if [ -x "$(command -v dnf)" ]; then
		PKG_MANAGER="dnf"
	else
		PKG_MANAGER="yum"
	fi
	PKG_REMOVE="${PKG_MANAGER} remove -y"
	PIHOLE_DEPS=( bind-utils bc dnsmasq nginx php70w-fpm git curl unzip wget findutils )
	package_check() {
		rpm -qa | grep ^$1- > /dev/null
	}
	package_cleanup() {
		${SUDO} ${PKG_MANAGER} -y autoremove
	}
elif [ -x "$(command -v apt-get)" ]; then
	# Debian Family
	PKG_MANAGER="apt-get"
	PKG_REMOVE="${PKG_MANAGER} -y remove --purge"
	PIHOLE_DEPS=( dnsutils bc dnsmasq nginx php7.0-fpm git curl unzip wget )
	package_check() {
		dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -c "ok installed"
	}
	package_cleanup() {
		${SUDO} ${PKG_MANAGER} -y autoremove
		${SUDO} ${PKG_MANAGER} -y autoclean
	}
else
	echo "OS distribution not supported"
	exit
fi

spinner() {
	local pid=$1
	local delay=0.50
	local spinstr='/-\|'
	while [ "$(ps a | awk '{print $1}' | grep "${pid}")" ]; do
		local temp=${spinstr#?}
		printf " [%c]  " "${spinstr}"
		local spinstr=${temp}${spinstr%"$temp}"}
		sleep ${delay}
		printf "\b\b\b\b\b\b"
	done
	printf "    \b\b\b\b"
}

removeAndPurge() {
	# Purge dependencies
	echo ":::"
	for i in "${PIHOLE_DEPS[@]}"; do
		package_check ${i} > /dev/null
		if [ $? -eq 0 ]; then
			while true; do
				read -rp "::: Do you wish to remove ${i} from your system? [y/n]: " yn
				case ${yn} in
					[Yy]* ) printf ":::\tRemoving %s..." "${i}"; ${SUDO} ${PKG_REMOVE} "${i}" &> /dev/null & spinner $!; printf "done!\n"; break;;
					[Nn]* ) printf ":::\tSkipping %s\n" "${i}"; break;;
					* ) printf "::: You must answer yes or no!\n";;
				esac
			done
		else
			printf ":::\tPackage %s not installed... Not removing.\n" "${i}"
		fi
	done

	# Remove dependency config files
	echo "::: Removing dnsmasq config files..."
	${SUDO} rm /etc/dnsmasq.conf /etc/dnsmasq.conf.orig /etc/dnsmasq.d/01-pihole.conf &> /dev/null

	# Take care of any additional package cleaning
	printf "::: Auto removing & cleaning remaining dependencies..."
	package_cleanup &> /dev/null & spinner $!; printf "done!\n";

	# Call removeNoPurge to remove PiHole specific files
	removeNoPurge
}

removeNoPurge() {
	echo ":::"
	# Only web directories/files that are created by pihole should be removed.
	echo "::: Removing the Pi-hole Web server files..."
	${SUDO} rm -rf /var/www/html/admin &> /dev/null
	${SUDO} rm -rf /var/www/html/pihole &> /dev/null

	# If the web directory is empty after removing these files, then the parent html folder can be removed.
	if [ -d "/var/www/html" ]; then
		if [[ ! "$(ls -A /var/www/html)" ]]; then
    			${SUDO} rm -rf /var/www/html &> /dev/null
		fi
	fi

	# Attempt to preserve backwards compatibility with older versions
	# to guarantee no additional changes were made to /etc/crontab after
	# the installation of pihole, /etc/crontab.pihole should be permanently
	# preserved.
	if [[ -f /etc/crontab.orig ]]; then
		echo "::: Initial Pi-hole cron detected.  Restoring the default system cron..."
		${SUDO} mv /etc/crontab /etc/crontab.pihole
		${SUDO} mv /etc/crontab.orig /etc/crontab
		${SUDO} service cron restart
	fi

	# Attempt to preserve backwards compatibility with older versions
	if [[ -f /etc/cron.d/pihole ]]; then
		echo "::: Removing cron.d/pihole..."
		${SUDO} rm /etc/cron.d/pihole &> /dev/null
	fi

	echo "::: Removing config files and scripts..."
	package_check nginx > /dev/null
	if [ $? -eq 1 ]; then
    # Check if nginx was installed prior to pi-hole 
    if [[ -e "/etc/nginx/.del" ]]; then
      ${SUDO} rm -rf /etc/nginx/ &> /dev/null
    else
      ${SUDO} mv /etc/nginx/nginx.conf.orig /etc/nginx/nginx.conf
    fi
	fi

	${SUDO} rm /etc/dnsmasq.d/adList.conf &> /dev/null
	${SUDO} rm /etc/dnsmasq.d/01-pihole.conf &> /dev/null
	${SUDO} rm -rf /var/log/*pihole* &> /dev/null
	${SUDO} rm -rf /etc/pihole/ &> /dev/null
	${SUDO} rm -rf /etc/.pihole/ &> /dev/null
	${SUDO} rm -rf /opt/pihole/ &> /dev/null
	${SUDO} rm /usr/local/bin/pihole &> /dev/null
	${SUDO} rm /etc/bash_completion.d/pihole &> /dev/null
	${SUDO} rm /etc/sudoers.d/pihole &> /dev/null

	# If the pihole user exists, then remove
	if id "pihole" >/dev/null 2>&1; then
        	echo "::: Removing pihole user..."
		${SUDO} userdel -r pihole
	fi

	echo ":::"
	printf "::: Finished removing PiHole from your system. Sorry to see you go!\n"
	printf "::: Reach out to us at https://github.com/pi-hole/pi-hole/issues if you need help\n"
	printf "::: Reinstall by simpling running\n:::\n:::\tcurl -sSL https://install.pi-hole.net | bash\n:::\n::: at any time!\n:::\n"
	printf "::: PLEASE RESET YOUR DNS ON YOUR ROUTER/CLIENTS TO RESTORE INTERNET CONNECTIVITY!\n"
}

######### SCRIPT ###########
echo "::: Preparing to remove packages, be sure that each may be safely removed depending on your operating system."
echo "::: (SAFE TO REMOVE ALL ON RASPBIAN)"
while true; do
	read -rp "::: Do you wish to purge PiHole's dependencies from your OS? (You will be prompted for each package) [y/n]: " yn
	case ${yn} in
		[Yy]* ) removeAndPurge; break;;

		[Nn]* ) removeNoPurge; break;;
	esac
done
