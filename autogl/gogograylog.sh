#!/bin/bash
# Graylog Automated Docker Install
# Recommed 16GB of RAM and at least 2 cpus but it CAN run on less
clear

if [ "$EUID" -ne 0 ]
  then echo "This script needs to run as root. Please sudo su before running"
  exit
fi

function isPresent { command -v "$1" &> /dev/null && echo 1; }
source /etc/os-release #Get OS Details

TOTAL_MEM=$(awk '/MemTotal/{printf "%d\n", $2 / 1024;}' < /proc/meminfo)
MEM_USED=$(awk '/MemTotal/{printf "%d\n", $2 * .5 / 1024;}' < /proc/meminfo)
HALF_MEM=$((TOTAL_MEM/2))
Q_RAM=$(awk '/MemTotal/{printf "%d\n", $2 * .25 / 1024;}' < /proc/meminfo)
ARCH=$(uname -m)
UFW_IS_PRESENT="$(isPresent ufw)"
FIREWALLCMD_IS_PRESENT="$(isPresent firewall-cmd)"
NFT_IS_PRESENT="$(isPresent nft)"
SELINUX_IS_INSTALLED="$(isPresent setsebool)"
DOCKER_IS_INSTALLED="$(isPresent docker)"
APT_IS_PRESENT="$(isPresent apt-get)"
YUM_IS_PRESENT="$(isPresent yum)"
JQ_IS_PRESENT="$(isPresent jq)"
IP_IS_PRESENT="$(isPresent ip)"

LOG_FILE="$HOME/gldockerinstall-$(date +%Y%m%d-%H%M%S).log"
INSTALL_SUMMARY=~/gldockerinstall.log
date > "$LOG_FILE"

if [ "$IP_IS_PRESENT" ]; then
	read -r _{,} GATEWAY_IP _ _ _ INTERNAL_IP _ < <(ip r g 1.0.0.0)
else
	INTERNAL_IP=$(hostname -I | cut -f 1 -d ' ')
fi

if [ "$CURL_IS_PRESENT" ]; then
	EXTERNAL_IP=$(curl https://ipecho.net/plain 2> /dev/null)
else
	EXTERNAL_IP=$(wget -qO- https://ipecho.net/plain 2> /dev/null)
fi

#Give some nice details
echo -e "System Information\nTotal Memory: $TOTAL_MEM\nRAM given to Graylog: $HALF_MEM\nSystem Architecture: $ARCH\nInteral IP: $INTERNAL_IP\nExternal IP: $EXTERNAL_IP\nLogfile: $LOG_FILE\n"

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
	echo "Graylog is only supported on x86_64 systems. You are running $ARCH"
	exit 64
fi

function updateSystem {
	echo "Updating System..."
	if [ "$APT_IS_PRESENT" ]; then
		apt-get update &>> "$LOG_FILE"
		apt-get upgrade -y &>> "$LOG_FILE"
	elif [ "$YUM_IS_PRESENT" ]; then
		yum update -y &>> "$LOG_FILE"
	fi
}

if [ "$DOCKER_IS_INSTALLED" ]; then
    echo -e "Warning! Docker is currently installed. \nThis Script will REMOVE current docker installs and replace with the latest version. \nDo you want to continue? \n[Y/N]"
    read -s CHOICE
    if [[ $CHOICE != @(y|Y|yes|YES|Yes) ]]; then
        echo -e "I got an input of $CHOICE so I'm assuming that's a no. Exiting!"
        exit 1
    fi
fi

if [ "$UFW_IS_PRESENT" ]; then
	UFWSTATUS=$(ufw status)
	if [[ "$UFWSTATUS" =~ "inactive" ]]; then unset UFW_IS_PRESENT; fi
fi

FIREWALL=none
if [ "$UFW_IS_PRESENT" ]; then FIREWALL=ufw;
elif [ "$FIREWALLCMD_IS_PRESENT" ]; then FIREWALL=firewalld;
elif [ "$IPTABLES_IS_PRESENT" ]; then FIREWALL=iptables; 
elif [ "$NFT_IS_PRESENT" ]; then FIREWALL=nft; fi;

if [ "$APT_IS_PRESENT" ]; then
	export DEBIAN_FRONTEND=noninteractive
    if [ "$DOCKER_IS_INSTALLED" ]; then
        echo "Removing current docker install"
        sudo apt-get remove docker docker-engine docker.io containerd runc &>> "$LOG_FILE"
    fi
    updateSystem

    apt-get install -y ca-certificates curl gnupg lsb-release wget &>> "$LOG_FILE"
    echo -e "Installing Docker"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    echo -e "\n\ndeb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    updateSystem
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin openjdk-11-jre-headless &>> "$LOG_FILE"
 
elif [ "$YUM_IS_PRESENT" ]; then
	    if [ "$DOCKER_IS_INSTALLED" ]; then
        echo -e "Removing current docker install"
        yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc  &>> "$LOG_FILE"
    fi
    updateSystem
    echo -e "Installing Docker" 
    yum install -y yum-utils &>> "$LOG_FILE"
    yum-config-manager --add-repo https://download.docker.com/linux/$ID/docker-ce.repo &>> "$LOG_FILE"
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin wget &>> "$LOG_FILE"

else
	echo -e "This system doesn't appear to be supported. No supported package manager (apt/yum/pacman) was found."
	echo -e "Automated installation is only availble for Debian and Red-Hat based distrubitions, including Ubuntu and CentOS."
	echo -e "$NAME is not a supported distribution at this time."
	exit
fi

wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/main/autogl/docker-compose.yml -P ~/ &>> "$LOG_FILE"
if [ ! -f ~/docker-compose.yml ]; then
    echo -e "Failed to grab docker compose file from GIT... Check your internet connection and try again"
    exit 1337
fi

function addFirewallRule {
	echo "Adding firewall rule for port $1 ($2) via $FIREWALL..."
	case "$FIREWALL" in
		none) echo "No firewall installed, please add port $1 manually to your inbound firewall" ;;
		ufw) ufw allow from any to any port "$1" proto tcp comment "$2" ;;
		firewalld) firewall-cmd "--add-port=$1/tcp" --permanent && firewall-cmd --reload ;;
		iptables) iptables -A INPUT -p tcp -m tcp --dport "$1" -j ACCEPT -m comment --comment "$2" && iptables-save > /etc/iptables/rules.v4 ;;
		nft) nft add rule filter INPUT tcp dport "$1" accept comment "\"$2\"" ;;
		*) echo "Unsupported Firewall!" ;;
	esac
}

if [[ "$FIREWALL" != "none" ]]; then
    echo -e "Adding Firewall Rules for Graylog Service Ports and Inputs"
    addFirewallRule "9000" "Default GUI"
    addFirewallRule "5044" "Beats TCP Input"
    addFirewallRule "12201" "GELF TCP Input"
    addFirewallRule "9000" "Default GUI"
fi

echo -e "Updating Memory Configurations to match system"
sed -i "s+Xms2g+Xms$Q_RAM\m+g" ~/docker-compose.yml
sed -i "s+Xmx2g+Xmx$Q_RAM\m+g" ~/docker-compose.yml
sed -i "/GRAYLOG_MONGODB_URI/a\      \GRAYLOG_SERVER_JAVA_OPTS: \"-Xms$Q_RAM\m -Xmx$Q_RAM\m -XX:NewRatio=1 -server -XX:+ResizeTLAB -XX:-OmitStackTraceInFastThrow -Djdk.tls.acknowledgeCloseNotify=true -Dlog4j2.formatMsgNoLookups=true\"" ~/docker-compose.yml
#

echo -e "Starting up Docker Containers"
docker compose -f ~/docker-compose.yml pull -q &>> "$LOG_FILE"
docker compose -f ~/docker-compose.yml create &>> "$LOG_FILE"
docker compose -f ~/docker-compose.yml up -d

count=0
while ! curl -s -u 'admin:yabba dabba doo' http://localhost:9000/api/system/cluster/nodes &>> "$LOG_FILE"; do
	((count++))
    if [ "$count" -eq "30" ]; then
        echo "Welp. Something went terribly wrong. Check the log file: $LOG_FILE. I'm giving up now! Byeeeeee"
        exit 1
    else
        echo -e "Waiting for graylog to come online"
        sleep 10s
    fi   
done

clear
echo -e "Your Graylog Instance is up and running! Acceess it here: http://$INTERNAL_IP:9000\nIf external access it here: http://$EXTERNAL_IP:9000"
echo -e "Default user: admin"
echo -e "Password: yabba dabba doo"


