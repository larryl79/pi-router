#!/bin/bash
# Part of pi-router https://github.com/larryl79/pi-router
#
# See LICENSE file for copyright and license details

IACT=True
ASKREBOOT=0
CONFIG=/boot/config.txt
LANIF=()
WANIF=
SSID=
PASSWORD=


USER=${SUDO_USER:-$(who -m | awk '{ print $1 }')}

# Everything else needs to be run as root
if [ $(id -u) -ne 0 ]; then
  printf "PI Router installation tool.\nScript must be run as root. Try 'sudo $0'\n"
  exit 1
fi

is_pi () {
  ARCH=$(dpkg --print-architecture)
  if [ "$ARCH" = "armhf" ] || [ "$ARCH" = "arm64" ] ; then
    return 0
  else
    return 1
  fi
}

is_installed() {
  if [ "$(dpkg -l "$1" 2> /dev/null | tail -n 1 | cut -d ' ' -f 1)" != "ii" ]; then
    return 1
  else
    return 0
  fi
}


calc_w_size() {
  # NOTE: it's tempting to redirect stderr to /dev/null, so supress error 
  # output from tput. However in this case, tput detects neither stdout or 
  # stderr is a tty and so only gives default 80, 24 values
  W_HEIGHT=18
  W_WIDTH=$(tput cols)

  if [ -z "$W_WIDTH" ] || [ "$W_WIDTH" -lt 60 ]; then
    W_WIDTH=80
  fi
  if [ "$W_WIDTH" -gt 178 ]; then
    W_WIDTH=120
  fi
  W_MENU_HEIGHT=$(($W_HEIGHT-7))
}

do_about() {
  whiptail --msgbox "\
This tool provides a straightforward way of doing router 
configuration of the Raspberry Pi.

" 20 70 1
}

is_number() {
  case $1 in
    ''|*[!0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

get_wifi_country() {
  CODE=${1:-0}
  IFACE="$(list_wlan_interfaces | head -n 1)"
  if [ -z "$IFACE" ]; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi
  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi
  wpa_cli -i "$IFACE" save_config > /dev/null 2>&1
  COUNTRY="$(wpa_cli -i "$IFACE" get country)"
  if [ "$COUNTRY" = "FAIL" ]; then
    return 1
  fi
  if [ $CODE = 0 ]; then
    echo "$COUNTRY"
  fi
  return 0
}

do_wifi_country() {
  IFACE="$(list_wlan_interfaces | head -n 1)"
  if [ -z "$IFACE" ]; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi

  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi

  IFS="$IFS"
  if [ "$IACT" = True ]; then
    value=$(cat /usr/share/zoneinfo/iso3166.tab | tail -n +26 | tr '\t' '/' | tr '\n' '/')
    IFS="/"
    COUNTRY=$(whiptail --menu "Select the country in which the Pi is to be used" 20 60 10 ${value} 3>&1 1>&2 2>&3)
  else
    COUNTRY=$1
    true
  fi
  if [ $? -eq 0 ];then
    wpa_cli -i "$IFACE" set country "$COUNTRY"
    wpa_cli -i "$IFACE" save_config > /dev/null 2>&1
    if iw reg set "$COUNTRY" 2> /dev/null; then
      ASKREBOOT=1
    fi
    if hash rfkill 2> /dev/null; then
      rfkill unblock wifi
      if is_pi ; then
        for filename in /var/lib/systemd/rfkill/*:wlan ; do
          echo 0 > $filename
        done
      fi
    fi
    if [ "$IACT" = True ]; then
      whiptail --msgbox "Wireless LAN country set to $COUNTRY" 20 60 1
    fi
  fi
  IFS=$oIFS
}

get_net_names() {
  if grep -q "net.ifnames=0" $CMDLINE || \
    ( [ "$(readlink -f /etc/systemd/network/99-default.link)" = "/dev/null" ] && \
      [ "$(readlink -f /etc/systemd/network/73-usb-net-by-mac.link)" = "/dev/null" ] ); then
    echo 1
  else
    echo 0
  fi
}

do_update() {
  apt-get update &&
  apt-get upgrade -y &&
  printf "Sleeping 5 seconds before reloading\n" &&
  sleep 5 &&
  exec $0
}

list_wlan_interfaces() {
  for dir in /sys/class/net/*/wireless; do
    if [ -d "$dir" ]; then
      basename "$(dirname "$dir")"
    fi
  done
}

do_wlan_check(){
  RET=0
  IFACE_LIST="$(list_wlan_interfaces)"
  IFACE="$(echo "$IFACE_LIST" | head -n 1)"

  if [ -z "$IFACE" ]; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "No wireless interface found" 20 60
    fi
    return 1
  fi

  if ! wpa_cli -i "$IFACE" status > /dev/null 2>&1; then
    if [ "$IACT" = True ]; then
      whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
    fi
    return 1
  fi

  if [ "$IACT" = True ] && [ -z "$(get_wifi_country)" ]; then
    do_wifi_country
  fi
}

do_AP_SSID(){
  do_wlan_check
  SSID="$1"
  while [ -z "$SSID" ] && [ "$IACT" = True ]; do
    SSID=$(whiptail --inputbox "Please enter AP SSID" 20 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      return 0
    elif [ -z "$SSID" ]; then
      whiptail --msgbox "AP SSID cannot be empty. Please try again." 20 60
    fi
  done

}


do_AP_passwd() {
  do_wlan_check
  if [ -z "$SSID" ]; then 
    do_AP_SSID
  fi
  
  PASSWORD="$1"
  while [ ${#PASSWORD} -lt 8 ] && [ "$IACT" = True ]; do
    PASSWORD=$(whiptail --inputbox "Please enter AP password. It cannot be empty and least 8 character." 20 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
      return 0
    fi
  done


  
  return $RET
}

do_select_wan() {
    WANIF="$1"
    DISPLAY=()
    INTERFACES=$(ip l | grep -E '[a-z].*: ' | cut -d ':' -f2 | cut -d ' ' -f2)
    set $INTERFACES

    for i in $@
	do
	  if ([ $i != "lo" ] && [ $i != "br0" ]); then
    	    IP=$(ip a | grep -E "$i$" | cut -d ' ' -f6)
    	    DISPLAY+=("$i" "$IP")
	  fi
	done

	WANIF=$(whiptail --title "WAN Interface" --menu "Choose the internet interface" $W_HEIGHT $W_WIDTH $W_MENU_HEIGHT \
        "${DISPLAY[@]}" 3>&1 1>&2 2>&3)

	RET=$?
	if [ $RET = 0 ]; then
	    return 0
	else
	    return $RET
	fi
}

do_lan_select() {
    LANIF="$1"
    DISPLAY=()
    INTERFACES=$(ip l | grep -E '[a-z].*: ' | cut -d ':' -f2 | cut -d ' ' -f2)
    set $INTERFACES

    for i in $@
	do
	  IP=$(ip a | grep -E "$i$" | cut -d ' ' -f6)
	  if ([ $i != "lo" ] && [ $i != "br0" ] && [ $i != "$WANIF" ]); then
    	    DISPLAY+=("$i" "$IP" OFF)
	  fi
	done

	LANIF=$(whiptail --title "LAN Interfaces" --checklist "Choose LAN interfaces to bridge" $W_HEIGHT 40 10 \
        "${DISPLAY[@]}" 3>&1 1>&2 2>&3)

	RET=$?
	if [ $RET = 0 ]; then
	    return 0
	else
	    return $RET
	fi
}

installer(){
	echo "Installing required packages"
	rfkill unblock wifi
	apt update
	apt install -y hostapd dnsmasq bridge-utils
	DEBIAN_FRONTEND=noninteractive apt install -y netfilter-persistent iptables-persistent

	# edit dhcpcd
	echo "Prepare /etc/dhcpcd.conf"
	mv /etc/dhcpcd.conf /etc/dhcpcd.conf.bak
	touch /etc/dhcpcd.conf
	BRIDGE=$(echo $LANIF | sed 's/"//g')
	printf "# A sample configuration for dhcpcd.
# See dhcpcd.conf(5) for details.

# Allow users of this group to interact with dhcpcd via the control socket.
#controlgroup wheel

# Inform the DHCP server of our hostname for DDNS.
hostname PI2-tether

# Use the hardware address of the interface for the Client ID.
clientid

# or
# Use the same DUID + IAID as set in DHCPv6 for DHCPv4 ClientID as per RFC4361.
# Some non-RFC compliant DHCP servers do not reply with this set.
# In this case, comment out duid and enable clientid above.
#duid

# Persist interface configuration when dhcpcd exits.
persistent

# Rapid commit support.
# Safe to enable by default because it requires the equivalent option set
# on the server to actually work.
option rapid_commit

# A list of options to request from the DHCP server.
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
# Respect the network MTU. This is applied to DHCP routes.
option interface_mtu

# Most distributions have NTP support.
#option ntp_servers

# A ServerID is required by RFC2131.
require dhcp_server_identifier

# Generate SLAAC address using the Hardware Address of the interface
#slaac hwaddr
# OR generate Stable Private IPv6 Addresses based from the DUID
slaac private

# Example static IP configuration:
#interface eth0
#static ip_address=192.168.0.10/24
#static ip6_address=fd51:42f8:caae:d92e::ff/64
#static routers=192.168.0.1
#static domain_name_servers=1.1.1.1 1.0.0.1

# It is possible to fall back to a static IP if DHCP fails:
# define static profile
#profile static_eth0
#static ip_address=192.168.1.23/24
#static routers=192.168.1.1
#static domain_name_servers=192.168.1.1

# fallback to static profile on eth0
#interface eth0
#fallback static_eth0
" >/etc/dhcpcd.conf
	printf "\n
denyinterface eth0
interface eth0
    static ip_address=

profile static_br0
    static ip_address=192.168.50.1/24
    #static domain_name_servers=1.1.1.1 1.0.0.1

interface br0
    bridge_ports $BRIDGE
    fallback static_br0

interface wlan0
    static ip_address=
    nohook wpa_supplicant
\n" >>/etc/dhcpcd.conf

	# edit routed-ap-conf
	echo "Prepare /etc/sysctl.d/routed-ap.conf for enable routing"
	mv /etc/sysctl.d/routed-ap.conf /etc/sysctl.d/routed-ap.conf.bak
	touch /etc/sysctl.d/routed-ap.conf
	printf "net.ipv4.ip_foprward=1" >> /etc/sysctl.d/routed-ap.conf

	
	# DNS MASQ
	echo "Prepare /etc/default/dnsmasq"
	mv /etc/default/dnsmasq /etc/default/dnsmasq.bak
	touch /etc/default/dnsmasq
	printf "ENABLED=1\n
CONFIG_DIR=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new
\n"> /etc/default/dnsmasq

        echo "Prepare /etc/dnsmasq.conf"
	mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
	touch /etc/dnsmasq.conf
	printf "interface=br0,wlan0                                             # Listening interface
dhcp-range=192.168.50.100,192.168.50.200,255.255.255.0,48h      # Pool of IP addresses served via DHCP for 48h
domain=wlan                                                     # Local LAN DNS domain
address=/rt.wlan/192.168.50.1                                   # Alias for this router
address=/pi.router/192.168.50.1                                 # Alias for this router
\n" > /etc/dnsmasq.conf
	
	# hostapd
	echo "Prepare /etc/hostapd/hostapd.conf"
	mv /etc/hostapd/hostapd.conf /etc/hostapd/hostapd.conf.bak
	touch /etc/hostapd/hostapd.conf
	printf "interface=wlan0
bridge=br0
ssid=$SSID
# a = IEEE 802.11a (5 GHz) (Raspberry Pi 3B+ onwards)
# b = IEEE 802.11b (2.4 GHz)
# g = IEEE 802.11g (2.4 GHz)
hw_mode=g
channel=7
macaddr_acl=0
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
country_code=GB
\n" > /etc/hostapd/hostapd.conf

	# bridge
	echo "Prepare /etc/default/bridge-utils"
	mv /etc/default/bridge-utils /etc/default/bridge-utils.bak
	touch /etc/default/bridge-utils

	printf "# /etc/default/bridge-utils

# Shoud we add the ports of a bridge to the bridge when they are hotplugged?
BRIDGE_HOTPLUG=yes" > /etc/default/bridge-utils

	# resolvconf
	echo "Prepare /etc/resolv.conf"
	printf "# Generated by resolvconf
nameserver 127.0.0.1\n" > /etc/resolv.conf

	# iptables NAT
	echo "Set iptables NAT"
	netfilter-persistent flush
	iptables -t nat -F
	iptables -t nat -A POSTROUTING -o $WANIF -j MASQUERADE
	netfilter-persistent save

	#services
	echo "Restart services"
	systemctl enable hciuart.service
	systemctl unmask hostapd.service
	systemctl enable hostapd.service
	systemctl enable wpa_supplicant.service
	systemctl restart dhcpcd.service
	systemctl restart hostapd.service
	systemctl restart dnsmasq.service
	

ASKREBOOT=1
}

do_install() {
    if ([ ! -z "$WANIF" ] && [ ! -z "$SSID" ] && [ ! -z "$PASSWORD" ] && [ ! -z ${LANIF[0]} ]) ; then
	whiptail --title "Install" --msgbox "Run install, please wait." 20 60
#    fi
#    RET=$?
#    if [ $RET = 0 ]; then
#	return 0
    installer;
    else
	whiptail --title "Error" --msgbox "Error, finish configure first." 20 60
	return $RET
    fi
}


do_finish() {
  if [ $ASKREBOOT -eq 1 ]; then
    whiptail --yesno "Would you like to reboot now?" 20 60 2
    if [ $? -eq 0 ]; then # yes
      sync
      reboot
    fi
  fi
echo "${LANIF[*]}"
  exit 0
}


#
# Command line options for non-IACT use
#
#for i in $*
#do
#  case $i in
#  nonint)
#    IACT=False
#    "$@"
#    exit $?
#    ;;
#  *)
#    # unknown option
#    ;;
#  esac
#done


#
# IACT use loop
#
if [ "$IACT" = True ]; then
  calc_w_size
  while [ "$USER" = "root" ] || [ -z "$USER" ]; do
    if ! USER=$(whiptail --inputbox "pi-router could not determine the default user.\\n\\n" 20 60 3>&1 1>&2 2>&3); then
      return 0
    fi
  done
  while true; do
    if is_pi ; then
      SELE=$(whiptail --title "Pi Router Installation Tool (pi-router)" --backtitle "$(cat /proc/device-tree/model )" --menu "Install Options" $W_HEIGHT $W_WIDTH $W_MENU_HEIGHT --cancel-button Exit --ok-button Select \
        "1 System Update"         "Do System Update" \
        "2 Set Wi-Fi County"      "Set Wi-Fi country" \
	"3 Set Wi-Fi AP SSID"     "$(/usr/bin/printf "AP SSID: %b" "$SSID" )" \
	"4 Add Wi-Fi AP Password" "$(/usr/bin/printf "AP passsword: %b" "$PASSWORD" )" \
        "5 Select LAN interfaces" "$(/usr/bin/printf "LAN interface: %b" "$LANIF" )" \
        "6 Select WAN interface"  "$(/usr/bin/printf "WAN interface: %b" "$WANIF" )" \
        "7 Install"               "Run Install Script" \
        "8 About pi-router" "Information about this router configuration tool" \
         3>&1 1>&2 2>&3)
#line 369: warning: command substitution: ignored null byte in input
    fi
    RET=$?
    if [ $RET -eq 1 ]; then
      do_finish
    elif [ $RET -eq 0 ]; then
      case "$SELE" in
	1\ *) do_update ;;
        2\ *) do_wifi_country ;;
	3\ *) do_AP_SSID ;;
	4\ *) do_AP_passwd ;;
	5\ *) do_lan_select ;;
	6\ *) do_select_wan ;;
	7\ *) do_install ;;
	8\ *) do_about ;;
	*) whiptail --msgbox "Programmer error: unrecognized option" 20 60 1 ;;
      esac || whiptail --msgbox "There was an error running option $SELE" 20 60 1
    else
      exit 1
    fi
  done
fi

# maybe never need it

  # Escape special characters for embedding in regex below
  local ssid="$(echo "$SSID" \
   | sed 's;\\;\\\\;g' \
   | sed -e 's;\.;\\\.;g' \
         -e 's;\*;\\\*;g' \
         -e 's;\+;\\\+;g' \
         -e 's;\?;\\\?;g' \
         -e 's;\^;\\\^;g' \
         -e 's;\$;\\\$;g' \
         -e 's;\/;\\\/;g' \
         -e 's;\[;\\\[;g' \
         -e 's;\];\\\];g' \
         -e 's;{;\\{;g'   \
         -e 's;};\\};g'   \
         -e 's;(;\\(;g'   \
         -e 's;);\\);g'   \
         -e 's;";\\\\\";g')"
