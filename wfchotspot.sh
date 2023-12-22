#!/bin/bash

set -e  # exit if any command fails

# Name of the network to create
SSID=NintendoWifi
# The access point interface. This is the wifi card that acts as the hotspot
AP_IFACE=wlan1
# 24-bit IP prefix used for the subnet (everything will be 192.168.69.x)
IP_PREFIX=192.168.69
# set to yes for verbose
VERBOSE=no
# custom DNS server
CUSTOM_DNS=none

function help()
{
	echo "usage: $0 [OPTION]..."
	echo "Creates an access point compatible with Nintendo DS and Wii"
	echo ""
	echo "Options:"
	echo "  -d, --dns         Optional IP address of custom DNS server to use. You may specify a Wiimmfi DNS server here instead of in the Wii/DS settings if so desired."
	echo "  -h, --help        Displays this help message"
	echo "  -i, --interface   Network interface to start the hotspot on (default: $AP_IFACE)"
	echo "  -s, --ssid        Network name (default: $SSID)"
	echo "  -v, --verbose     Enables additional debugging output and logs all DNS queries"
	exit 1
}

# parse command-line
while [[ "$#" -gt 0 ]]
do
	case "$1" in
		-d|--dns)
			CUSTOM_DNS="$2"
			shift; shift
			;;
		-h|--help)
			help
			;;
		-i|--interface)
			AP_IFACE="$2"
			shift; shift
			;;
		-s|--ssid)
			SSID="$2"
			shift; shift
			;;
		-v|--verbose)
			VERBOSE=yes
			shift;
			;;
		*)
			echo "Unrecognized option $1"
			help
			;;
	esac
done

echo '*** Specified Options: ***'
echo "  SSID:                   $SSID"
echo "  Access point interface: $AP_IFACE"
echo "  Custom DNS server:      $CUSTOM_DNS"
echo "  Verbose:                $VERBOSE"

# try to find out which interface is connected to the internet
INET_IFACE="$(ip route get 1.1.1.1 | grep -oP '(?<=dev )\w+')"
if [ -z "$INET_IFACE" ]
then
	echo "You don't appear to be connected to the internet. Check your connection and try again."
	exit 1
fi

# Make sure we're not trying to use the same interface for both
if [ "$AP_IFACE" = "$INET_IFACE" ]
then
	echo "Can't use $AP_IFACE for both internet connection and a hotspot"
	exit 1
fi

# assign an IP address for the access point interface
AP_IFACE_IP="$IP_PREFIX.1"
echo "*** Assigning IP address $AP_IFACE_IP to interface $AP_IFACE ***"
ip link set dev "$AP_IFACE" up                 # bring up the interface
ip addr flush dev "$AP_IFACE"                  # remove any existing IP address
ip addr add "$AP_IFACE_IP"/24 dev "$AP_IFACE"  # set the new IP address

# set up packet routing
echo '*** Setting up routing tables ***'
sysctl net.ipv4.ip_forward=1                                   # enable forwarding in the kernel
iptables -F                                                    # remove any existing IP rules
iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE  # enable NAT
iptables -A FORWARD -p all -j ACCEPT                           # allow all traffic to be forwarded
if [ "$VERBOSE" = yes ]; then iptables -L; fi

# start the DHCP server
echo '*** Starting DHCP server ***'
function dhcp_died()
{
	echo 'a process unexpectedly died!'
	exit 1
}
trap dhcp_died SIGCHLD
# enable the -q option to log all DNS queries in verbose mode
if [ "$VERBOSE" = yes ]; then LOG_REQUESTS=-q; fi
# override the default resolv.conf with our own if a custom DNS server was specified
if [ "$CUSTOM_DNS" != none ]; then RESOLV_OPTS='-r /dev/stdin'; fi
# start the server
dnsmasq -d $LOG_REQUESTS -i "$AP_IFACE" -G "$AP_IFACE_IP" -F "$IP_PREFIX.2,$IP_PREFIX.200,12h" -l /tmp/dnsmasq.leases $RESOLV_OPTS << EOF &
nameserver $CUSTOM_DNS
EOF
DNSMASQ_PID="$!"
#echo "PID $DNSMASQ_PID"

# create the access point
echo "*** Creating access point on $AP_IFACE with SSID '$SSID' ***"
DEBUG_OPT=-d
if [ "$VERBOSE" = yes ]; then DEBUG_OPT=-dd; fi
exec hostapd $DEBUG_OPT /dev/stdin << EOF
interface=$AP_IFACE
ssid=$SSID
hw_mode=g
channel=1
EOF
