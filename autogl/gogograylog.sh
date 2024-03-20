#!/bin/bash
# Graylog Automated Docker Install
# Recommend 16GB of RAM and at least 2 cpus but it CAN run on less
clear

NC='\033[0m'
URED='\033[4;31m'
UGREEN='\033[4;32m'
UYELLOW='\033[4;33m'
BGREEN='\033[1;32m' 
IBLACK='\033[0;100m'

if [ "$EUID" -ne 0 ]
  then echo -e "${URED}This script needs to run as root${NC}"
  exit
fi

if [[ "$1" == "--latest" ]]; then
    echo -e "${URED}You've opted to use the latest graylog release.${NC}\n\n You sure? [y/n]"
    read CHOICE
    if [[ $CHOICE != @(y|Y|yes|YES|Yes) ]]; then
        echo -e "I got an input of ${URED}$CHOICE${NC} so I'm assuming that's a no. Exiting!"
        exit 1
    else
        GLLATEST=true
    fi
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
CURL_IS_PRESENT="$(isPresent curl)"

#Test for WSL
if grep -qi microsoft /proc/version; then
  WSL=1
fi

LOG_FILE="$HOME/gldockerinstall-$(date +%Y%m%d-%H%M%S).log"
INSTALL_SUMMARY=~/gldockerinstall.log
date > "$LOG_FILE"

if [ "$IP_IS_PRESENT" ]; then
	read -r _{,} GATEWAY_IP _ _ _ INTERNAL_IP _ < <(ip r g 1.0.0.0)
else
	INTERNAL_IP=$(hostname -I | cut -f 1 -d ' ')
fi

if [ "$CURL_IS_PRESENT" ]; then
	EXTERNAL_IP=$(curl https://ipecho.net/plain -k 2> /dev/null)
else
	EXTERNAL_IP=$(wget -qO- https://ipecho.net/plain --no-check-certificate 2> /dev/null)
fi

#Give some nice details
echo -e "${IBLACK}System Information${NC}
Total Memory:\t\t${UGREEN}$TOTAL_MEM MB${NC}
RAM given to Graylog:\t${UGREEN}$HALF_MEM MB${NC}
System Architecture:\t${UGREEN}$ARCH${NC}
Internal IP:\t\t${UGREEN}$INTERNAL_IP${NC}
External IP:\t\t${UGREEN}$EXTERNAL_IP${NC}
Logfile:\t\t${UGREEN}$LOG_FILE${NC}
"

if [ $TOTAL_MEM -lt 2000 ]; then
    echo -e "Graylog ${URED}cannot run on less then 2GB of RAM.${NC} It is recommended to provide at least ${UGREEN}8GB of RAM${NC} for this single node deployment"
elif [ $TOTAL_MEM -lt 8000 ]; then 
    echo -e "Graylog running on a single node will perform much better with ${URED}8GB${NC} or more system memory"
    echo -e "Graylog will use ${URED}$HALF_MEM${NC}MB of your total: ${URED}$TOTAL_MEM${NC}MB"
    echo -e "${UYELLOW}Performance might be impacted...${NC}"
else
    echo -e "There is more then 8GB of RAM on this host! Excellent. We will be using HALF of system RAM"
    echo -e "Graylog will use ${UGREEN}$HALF_MEM${NC}MB of your total: ${UGREEN}$TOTAL_MEM${NC}MB system RAM"
fi

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
	echo -e "${URED}Graylog is only supported on x86_64 systems. You are running $ARCH${NC}"
	exit 64
fi

function updateSystem {
	echo -e "${UGREEN}Updating System...${NC}"
	if [ "$APT_IS_PRESENT" ]; then
		apt-get update &>> "$LOG_FILE"
		apt-get upgrade -y &>> "$LOG_FILE"
	elif [ "$YUM_IS_PRESENT" ]; then
		yum update -y &>> "$LOG_FILE"
	fi
}

if [ "$DOCKER_IS_INSTALLED" ]; then
    echo -e "${UYELLOW}Warning!${NC} Docker is currently installed. \nThis Script will ${URED}REMOVE${NC} current docker installs and replace with the latest version. \nDo you want to continue? \n[Y/N]"
    read CHOICE
    if [[ $CHOICE != @(y|Y|yes|YES|Yes) ]]; then
        echo -e "I got an input of ${URED}$CHOICE${NC} so I'm assuming that's a no. Exiting!"
        exit 1
    fi
    rm ~/docker-compose.yml &>> "$LOG_FILE" #cleanup potential left-overs if re-running
    rm ~/gl_* &>> "$LOG_FILE" #cleanup potential left-overs if re-running
fi

#Set Admin Password
PSWD="bunk"
until [ "$PSWD" == "$PSWD2" ]
do
        echo -e "${GREEN}\nEnter Desired Graylog Login Password${NC}"
        read -s -p "Password: " PSWD
        echo -e "${GREEN}\nEnter Desired Graylog Login Password again${NC}"
        read -s -p "Password: " PSWD2
        echo -e "\n"
        if [[ "$PSWD" == "$PSWD2" ]]; then
                GLSHA256=$(echo $PSWD | tr -d '\n'| sha256sum | cut -d" " -f1)
        else
                echo -e "${RED}\nPasswords do not match, press enter to try again${NC}"
                read
        fi
done

#Firewall Cleanup
if [ "$UFW_IS_PRESENT" ]; then
	UFWSTATUS=$(ufw status)
	if [[ "$UFWSTATUS" =~ "inactive" ]]; then unset UFW_IS_PRESENT; fi #No rules set
fi

if [ "$NFT_IS_PRESENT" ]; then
    NFTSTATUS=$(nft list ruleset)
    if [ -z "$NFTSTATUS" ]; then unset NFT_IS_PRESENT; fi #No rules set
    if [[ $NFTSTATUS != *"INPUT"* ]]; then unset NFT_IS_PRESENT; fi #No Ingress rules set
fi

FIREWALL=none
if [ "$UFW_IS_PRESENT" ]; then FIREWALL=ufw;
elif [ "$FIREWALLCMD_IS_PRESENT" ]; then FIREWALL=firewalld;
elif [ "$IPTABLES_IS_PRESENT" ]; then FIREWALL=iptables; 
elif [ "$NFT_IS_PRESENT" ]; then FIREWALL=nft; fi;

if [ "$APT_IS_PRESENT" ]; then
	export DEBIAN_FRONTEND=noninteractive
    if [ "$DOCKER_IS_INSTALLED" ]; then
        echo -e "${URED}Removing current docker install${NC}"
        sudo apt-get remove -y docker docker-engine docker.io containerd runc &>> "$LOG_FILE"
    fi
    updateSystem

    apt-get install -y ca-certificates curl gnupg lsb-release &>> "$LOG_FILE"
    echo -e "${UGREEN}Installing Docker${NC}"
    mkdir -p /etc/apt/keyrings &>> "$LOG_FILE"
    curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    echo -e "\n\ndeb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    updateSystem
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin openjdk-11-jre-headless jq &>> "$LOG_FILE"
 
elif [ "$YUM_IS_PRESENT" ]; then
	    if [ "$DOCKER_IS_INSTALLED" ]; then
        echo -e "${URED}Removing current docker install${NC}"
        yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc &>> "$LOG_FILE"
    fi
    updateSystem
    echo -e "${UGREEN}Installing Docker${NC}" 
    yum install -y yum-utils &>> "$LOG_FILE"
    ID=centos
    yum-config-manager --add-repo https://download.docker.com/linux/$ID/docker-ce.repo &>> "$LOG_FILE"
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin jq &>> "$LOG_FILE"

else
	echo -e "${URED}This system doesn't appear to be supported. No supported package manager ${UGREEN}(apt/yum)${URED} was found."
	echo -e "Automated installation is only availble for Debian and Red-Hat based distributions, including ${UGREEN}Ubuntu${URED} and ${UGREEN}CentOS${URED}."
	echo -e "${UGREEN}$NAME${URED} is not a supported distribution at this time.${NC}"
	exit
fi

curl https://raw.githubusercontent.com/graylog-labs/graylog-playground/main/autogl/docker-compose.yml -o ~/docker-compose.yml &>> "$LOG_FILE"
#wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/main/autogl/docker-compose.yml -P ~/ &>> "$LOG_FILE"
if [ ! -f ~/docker-compose.yml ]; then
    echo -e "${URED}Failed to grab docker compose file from GIT... Check your internet connection and try again${NC}"
    exit 1337
fi

#Latest GL Version
if [ $GLLATEST ]; then
    lgl=$(curl -L --fail "https://hub.docker.com/v2/repositories/graylog/graylog/tags/?page_size=1000" | jq '.results | .[] | .name' -r | sed 's/latest//' | sort --version-sort | tail -n 1)
    dcv=$(sed -n 's/image: "graylog\/graylog-enterprise://p' ~/docker-compose.yml | tr -d '"' | tr -d " ")
    sed -i "s+enterprise\:$dcv+enterprise\:$lgl+g" ~/docker-compose.yml
fi

function addFirewallRule {
	if [ "$YUM_IS_PRESENT" ]; then
        IPTABLESLOC="/etc/sysconfig/iptables"
    else
        IPTABLESLOC="/etc/iptables/rules.v4"
    fi
    echo -e "Adding firewall rule for port $1 $2 ($3) via $FIREWALL..."
    case "$FIREWALL" in
		none) echo -e "${URED}No firewall installed, please add port $1 manually to your inbound firewall${NC}" ;;
		ufw) ufw allow from any to any port "$1" proto $2 comment "$3" ;;
		firewalld) firewall-cmd "--add-port=$1/$2" --permanent && firewall-cmd --reload ;;
		iptables) iptables -A INPUT -p $2 -m $2 --dport "$1" -j ACCEPT -m comment --comment "$3" && iptables-save > $IPTABLESLOC ;;
		nft) nft add rule filter INPUT $2 dport "$1" accept comment "\"$3\"" ;;
		*) echo -e "${URED}Unsupported Firewall: $FIREWALL${NC}" ;;
	esac
}

if [[ "$FIREWALL" != "none" ]]; then
    echo -e "${UGREEN}Adding Firewall Rules for Graylog Service Ports and Inputs${NC}"
    addFirewallRule "443" "tcp" "Default GUI"
    addFirewallRule "514" "tcp" "Syslog TCP Input"
    addFirewallRule "514" "udp" "Syslog TCP Input"
    addFirewallRule "5044" "tcp" "Beats TCP Input"
    addFirewallRule "5050" "tcp" "RAW TCP Input"
    addFirewallRule "5050" "udp" "RAW UDP Input"
    addFirewallRule "5555" "tcp" "CEF TCP Input"
    addFirewallRule "5555" "udp" "CEF UDP Input"
    addFirewallRule "5556" "tcp" "Palo Alto Networks v9+ TCP Input"
    addFirewallRule "5557" "tcp" "Palo Alto Networks v8.x TCP Input"
    addFirewallRule "9000" "tcp" "Default GUI"
    addFirewallRule "12201" "tcp" "GELF TCP Input"
    addFirewallRule "12201" "udp" "GELF UDP Input"
fi

echo -e "${UGREEN}Updating Memory Configurations to match system${NC}"
sed -i "s+Xms2g+Xms$Q_RAM\m+g" ~/docker-compose.yml
sed -i "s+Xmx2g+Xmx$Q_RAM\m+g" ~/docker-compose.yml
sed -i "/GRAYLOG_MONGODB_URI/a\      \GRAYLOG_SERVER_JAVA_OPTS: \"-Xms$Q_RAM\m -Xmx$Q_RAM\m -XX:NewRatio=1 -server -XX:+ResizeTLAB -XX:-OmitStackTraceInFastThrow -Djdk.tls.acknowledgeCloseNotify=true -Dlog4j2.formatMsgNoLookups=true\"" ~/docker-compose.yml
sed -i "s+941828f6268291fa3aa87a866e8367e609434f42761bdf02dc7fc7958897bae6+$GLSHA256+g" ~/docker-compose.yml
unset GLSHA256

#Because RH
if [ "$YUM_IS_PRESENT" ]; then
    systemctl enable docker.service &>> "$LOG_FILE"
    systemctl restart docker &>> "$LOG_FILE"
fi

#Because WSL, start and enable service to run on wsl start
if [ "$WSL" ]; then
    service docker start &>> "$LOG_FILE"
    #Since WSL IP Changes on fresh start, prompt it for users via dashrc. Prevent adding twice on a re-run
    BRCF=$(cat ~/.bashrc)
    if [[ "$BRCF" != *"Graylog Instance:"* ]]; then
        echo "echo \"Graylog Instance: $(hostname -I | cut -f 1 -d ' '):9000"\" >> ~/.bashrc
    fi
    #Add to start with WSL
    if [ -f /etc/wsl.conf ]; then
        WSLCONF=$(cat /etc/wsl.conf)
        if [[ "$WSLCONF" != *"service docker start"* ]]; then
            echo -e "command=\"service docker start\"" >> /etc/wsl.conf
        fi
    else
        echo -e "[boot]\ncommand=\"service docker start\"" > /etc/wsl.conf
    fi
fi

#JIC Script is ran more than once, cleanup.
GLDOVOL=$(docker volume ls | awk '{ print $2 }' | grep root_)
if [[ $GLDOVOL == *"graylog"* ]]; then
    echo -e "${URED}Removing Existing Graylog Docker Related Volumes${NC}"
    docker compose -f ~/docker-compose.yml stop &>> "$LOG_FILE" 
    docker compose -f ~/docker-compose.yml rm -f &>> "$LOG_FILE" 
    for vol in $GLDOVOL
    do
        docker volume rm -f $vol &>> "$LOG_FILE"
    done
fi

echo -e "${UGREEN}Starting up Docker Containers${NC}"
docker compose -f ~/docker-compose.yml pull -q &>> "$LOG_FILE"
docker compose -f ~/docker-compose.yml create &>> "$LOG_FILE"
docker compose -f ~/docker-compose.yml up -d

count=0
while ! curl -s -u "admin:$PSWD" http://localhost:9000/api/system/cluster/nodes &>> "$LOG_FILE"; do
	((count++))
    if [ "$count" -eq "30" ]; then
        echo -e "${URED}Welp. Something went terribly wrong. Check the log file: $LOG_FILE. I'm giving up now! Byeeeeee${NC}"
        exit 1
    else
        echo -e "${BGREEN}Waiting for graylog to come online${NC}"
        sleep 10s
    fi   
done

#Add inputs via CP
curl https://raw.githubusercontent.com/graylog-labs/graylog-playground/main/autogl/gl_starter_pack.json -o ~/gl_starter_pack.json &>> "$LOG_FILE"
#wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/main/autogl/gl_starter_pack.json -P ~/ &>> "$LOG_FILE"
for entry in ~/gl_*
do
  echo -e "\n\nInstalling Content Package: ${UGREEN}$entry${NC}\n"
  id=$(cat $entry | jq -r '.id')
  ver=$(cat $entry | jq -r '.rev')
  echo -e "\n\nID:${UGREEN}$id${NC} and Version: ${UGREEN}$ver${NC}\n"
  curl -u "admin:$PSWD" -XPOST "http://localhost:9000/api/system/content_packs"  -H 'Content-Type: application/json' -H 'X-Requested-By: PS_Packer' -d @"$entry" &>> "$LOG_FILE"
  echo -e "\n\nEnabling Content Package: ${UGREEN}gl_starter_pack${NC}\n"
  curl -u "admin:$PSWD" -XPOST "http://localhost:9000/api/system/content_packs/$id/$ver/installations" -H 'Content-Type: application/json' -H 'X-Requested-By: PS_TeamAwesome' -d '{"parameters":{},"comment":""}' &>> "$LOG_FILE"
done

clear
echo -e "${BGREEN}Your Graylog Instance is up and running\nAcceess it here: ${UYELLOW}http://$INTERNAL_IP:9000${BGREEN}\nIf external access it here: ${UYELLOW}http://$EXTERNAL_IP:9000${NC}"
echo -e "${BGREEN}Default user: ${UYELLOW}admin${NC}"
echo -e "${BGREEN}Password: ${UYELLOW}$PSWD${NC}"
echo -e "Docker Compose file is located: ${UYELLOW}$(ls ~/docker-compose.yml)${NC}"
echo -e "Make changes as needed to open more ports for inputs!"
echo -e "To make changes, edit the compose file and run:\n${UYELLOW}docker compose -f ~/docker-compose.yml up -d${NC}"

unset PSWD
unset PSWD2