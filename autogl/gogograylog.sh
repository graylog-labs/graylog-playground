#!/bin/bash
# Graylog Automated Docker Install
# Recommend 16GB of RAM and at least 2 cpus but it CAN run on less

# =========================== #
# Initialize global variables #
# =========================== #

# Formatting vars:
NC='\033[0m' # default color/format
URED='\033[4;31m' # underlined red
UGREEN='\033[4;32m' # underlined green
UYELLOW='\033[4;33m' # underlined yellow
BGREEN='\033[1;32m' # bold green
DGRAYBG='\033[0;100m' # dark gray background

# Flag vars:
GRAYLOG_VERSION=
OPENSEARCH_VERSION=
MONGODB_VERSION=

# External system vars:
LOG_FILE="/var/log/graylog-server/deploy-graylog.log"
TOTAL_MEM=$(awk '/MemTotal/{printf "%d\n", $2 / 1024;}' < /proc/meminfo)
MEM_USED=$(awk '/MemTotal/{printf "%d\n", $2 * .5 / 1024;}' < /proc/meminfo)
HALF_MEM=$((TOTAL_MEM/2))
Q_RAM=$(awk '/MemTotal/{printf "%d\n", $2 * .25 / 1024;}' < /proc/meminfo)
ARCH=$(uname -m)

# Exit if running as non-root user:
if [ "$EUID" -ne 0 ]; then
  echo -e "${URED}CRITICAL - This script must be run as root, exiting...${NC}" 
  exit 1
fi

# ==================== #
# Supporting Functions #
# ==================== #

# Logging function - yeah.. I went there.
# We're a logging company. 
log() {
    # Capture parameters
    local severity="${1^^}" # ^^ converts value to uppercase
    local message="$2"

    # Get current date and time in RFC 5424 format (syslog compliant)
    # Note: The '+%Y-%m-%dT%H:%M:%SZ' format provides UTC time. Adjust if you need local time.
    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Set Syslog prival based on supplied $severity. Using local0 facility for all values.
    # Default prival is 134 aka INFO severity
    local prival=134
    case "$severity" in
      DEBUG)
        let prival++;;
      INFO)
        ;;
      NOTICE)
        let prival--;;
      WARN|WARNING)
        let prival=$prival-2
        echo -e "${UYELLOW}$message${NC}";; # Send to stdout to notify user as well
      ERROR)
        let prival=$prival-3
        echo -e "${UYELLOW}$message${NC}";; # Send to stdout to notify user as well
      CRIT|CRITICAL)
        let prival=$prival-4
        echo -e "${UYELLOW}$message${NC}";; # Send to stdout to notify user as well
      *)
        log "DEBUG" "Unknown severity level $1. Supported severities are DEBUG, INFO, NOTICE, WARN, ERROR, and CRIT";;
    esac

    # Construct the log message using an appropriate Syslog priority value
    # so we don't have to summon Satan every time we deploy Graylog :)
    local logMessage="<$prival>1 [$timestamp] - $severity - $message"
    
    # Create log dir if does not exist already
    if [ ! -d /var/log/graylog-server ]; then
        mkdir /var/log/graylog-server
    fi
    
    # Append the log message to the file
    echo "${logMessage}" >> "$LOG_FILE"
}

help() {
    echo
    echo "Usage:"
    echo
    echo " --graylog-version {version}     -- Specify Graylog version to use (defaults to latest stable)"
    echo " --opensearch-version {version}  -- Specify OpenSearch version to use (defaults to latest stable)"
    echo " --mongodb-version {version}     -- Specify MongoDB version to use (defaults to latest stable)"
    echo " -p|--preserve                      -- Does NOT delete existing containers & volumes"
    echo " -h|--help                       -- Prints this help message"
    exit 0
}



# ================ #
# Preflight Checks #
# ================ #

# Process flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --graylog-version)
      GRAYLOG_VERSION="$1"
      log "INFO" "Graylog version: $1"
      shift;;
    --opensearch-version)
      OPENSEARCH_VERSION="$1"
      log "INFO" "Opensearch version: $1"
      shift;;
    --mongodb-version)
      MONGODB_VERSION="$1"
      log "INFO" "MongoDB version: $1"
      shift;;
    -p|--preserve)
      PRESERVE=y
      shift;;
    -h|--help)
      help;;
    *)
      log "WARN" "Unknown flag: $1"
      help;;
  esac
done

# Create new log file. If file exists, append its creation date to end and delete original.
if [ -e "$LOG_FILE" ]; then
    cp "$LOG_FILE" "$LOG_FILE.$(date -r "$LOG_FILE" "+%Y-%m-%d_%H-%M-%S")"
    rm "$LOG_FILE"
fi
date > "$LOG_FILE"

# Source info from /etc/os-release, fail if missing
if [ -e /etc/os-release ]; then
    source /etc/os-release
else
    log "CRITICAL" "No /etc/os-release file found. This script only works in Linux! Exiting..."
    exit 1
fi

# Test for WSL
if grep -qi microsoft /proc/version; then
  WSL=1
fi

# Get interface IP address of system
if [ $(which ip) ]; then
	read -r _{,} GATEWAY_IP _ _ _ INTERNAL_IP _ < <(ip r g 1.0.0.0)
else
	INTERNAL_IP=$(hostname -I | cut -f 1 -d ' ')
fi

# Get external IP of system:
if [ $(which curl) ]; then
	EXTERNAL_IP=$(curl https://ipecho.net/plain -k 2> /dev/null)
else
	EXTERNAL_IP=$(wget -qO- https://ipecho.net/plain --no-check-certificate 2> /dev/null)
fi

# CPU arch check
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
	echo -e "${URED}Graylog is only supported on x86_64 systems. You are running $ARCH${NC}"
	exit 1
fi


# ===================== #
# Main script execution #
# ===================== #

# Initialize log file:
log "INFO" "Started new gogograylog deployment!"

# Clear current screen for cleanliness:
clear

# Display system details for user:
echo -e "${DGRAYBG}System Information${NC}
Total Memory:\t\t${UGREEN}$TOTAL_MEM MB${NC}
RAM given to Graylog:\t${UGREEN}$HALF_MEM MB${NC}
System Architecture:\t${UGREEN}$ARCH${NC}
Internal IP:\t\t${UGREEN}$INTERNAL_IP${NC}
External IP:\t\t${UGREEN}$EXTERNAL_IP${NC}
Logfile:\t\t${UGREEN}$LOG_FILE${NC}\n"

# Memory capacity logic checks:
if [ $TOTAL_MEM -lt 2000 ]; then
    echo -e "Graylog ${URED}cannot run on less than 2GB of RAM.${NC} It is recommended to provide at least ${UGREEN}8GB of RAM${NC} for this single node deployment.\n"
elif [ $TOTAL_MEM -lt 8000 ]; then 
    echo -e "Graylog running on a single node will perform much better with ${URED}8GB${NC} or more system memory"
    echo -e "Graylog will use ${URED}$HALF_MEM${NC}MB of your total: ${URED}$TOTAL_MEM${NC}MB"
    echo -e "${UYELLOW}Performance might be impacted...${NC}\n"
else
    echo -e "There is more then 8GB of RAM on this host! Excellent. We will be using HALF of system RAM"
    echo -e "Graylog will use ${UGREEN}$HALF_MEM${NC}MB of your total: ${UGREEN}$TOTAL_MEM${NC}MB system RAM\n"
fi

# Check for AVX support in CPU (bc MongoDB 5.0+ needs it):
if [ ! $(grep avx /proc/cpuinfo) ]; then
    echo -e "${UYELLOW}Your CPU does not support AVX instructions, so you cannot install MongoDB v5.0 or later.${NC}\n"
fi

# Cleanup old docker containers and volumes from previous runs
echo "By default, this script performs a clean install of Graylog, MongoDB, and OpenSearch, deleting existing containers and volumes from previous runs of this script."
echo "This is generally best practice, as reusing existing volumes is problematic if changing software versions between script executions."
echo
echo -e "${URED}Confirm deletion of all existing Graylog, MongoDB, and OpenSearch containers and volumes [Y/n]: ${NC}"
read x
x=${x,,} # ,, converts value to lowercase
if [ $x == "n" ]; then
    echo -e "${UGREEN}NOT deleting existing Docker containers & volumes. Note: You can skip this prompt next time by passing the '--preserve' flag to the script!${NC}\n"
else
    echo -e "${URED}Deleting existing Graylog Docker containers and volumes...${NC}\n"
    docker compose -f ~/docker-compose.yml stop &>> "$LOG_FILE" 
    docker compose -f ~/docker-compose.yml rm -f &>> "$LOG_FILE" 
    docker volume rm -f graylog_config &>> "$LOG_FILE"
    docker volume rm -f graylog_data &>> "$LOG_FILE"
    docker volume rm -f graylog_journal &>> "$LOG_FILE"
    docker volume rm -f mongodb_data &>> "$LOG_FILE"
    docker volume rm -f opensearch_data &>> "$LOG_FILE"
fi

# ================ #
# First User Input #
# ================ #

# Set Admin Password
PSWD="bunk"
until [ "$PSWD" == "$PSWD2" ]
do
    read -sp "Enter Desired Graylog Admin Password: " PSWD
    read -sp "Enter Desired Graylog Admin Password again: " PSWD2
    echo
    if [[ "$PSWD" == "$PSWD2" ]]; then
        GLSHA256=$(echo $PSWD | tr -d '\n'| sha256sum | cut -d" " -f1)
    else
        echo -e "${RED}\nPasswords do not match, press enter to try again${NC}"
        read
    fi
done

# Upgrade base system:
echo -e "${UGREEN}Updating System...${NC}"
if [ $(which apt-get) ]; then
    apt-get update &>> "$LOG_FILE"
    apt-get upgrade -y &>> "$LOG_FILE"
elif [ $(which yum) ]; then
    yum update -y &>> "$LOG_FILE"
fi

# Install Docker
if [ $(which docker) ]; then
    echo -e "\n${UGREEN}Docker version installed:${NC} $(docker -v | cut -d' ' -f3 | cut -d',' -f1)"
else
    if [ $(which apt-get) ]; then
        export DEBIAN_FRONTEND=noninteractive
        echo -e "\n${UGREEN}Installing Docker and prerequisites...${NC}"
        apt-get install -y ca-certificates curl gnupg lsb-release &>> "$LOG_FILE"
        mkdir -p /etc/apt/keyrings &>> "$LOG_FILE"
        curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        echo -e "\n\ndeb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin jq &>> "$LOG_FILE"
    elif [ $(which yum) ]; then
        echo -e "\n${UGREEN}Installing Docker and prerequisites...${NC}"
        yum install -y yum-utils &>> "$LOG_FILE"
        # Force using CentOS repo since RHEL on x86_64 isn't supported yet:
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &>> "$LOG_FILE"
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin jq &>> "$LOG_FILE"
    else
        echo -e "${URED}This system doesn't appear to be supported. No supported package manager ${UGREEN}(apt/yum)${URED} was found."
        echo -e "Automated installation is only availble for Debian and Red-Hat based distributions, including ${UGREEN}Ubuntu${URED} and ${UGREEN}CentOS${URED}."
        echo -e "${UGREEN}$NAME${URED} is not a supported distribution at this time.${NC}"
        exit 1
    fi
fi

# Fetch docker-compose.yml from repo:
if [ $(which curl) ]; then
	curl https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/docker-compose.yml -o ~/docker-compose.yml &>> "$LOG_FILE"
    curl https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/.env -o ~/.env &>> "$LOG_FILE"
else
	wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/docker-compose.yml -P ~/ &>> "$LOG_FILE"
    wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/.env -P ~/ &>> "$LOG_FILE"
fi

# Exit if failed to get docker-compose.yml from repo:
if [ ! -f ~/docker-compose.yml ]; then
    echo -e "${URED}Failed to grab docker compose file from GIT... Check your internet connection and try again${NC}"
    exit 1
fi

# Update docker-compose.yml with selected versions:
### Graylog ###
# Fetch available Graylog versions from Docker hub:
GRAYLOG_VERSIONS_AVAILABLE=($(curl -sL --fail "https://hub.docker.com/v2/namespaces/graylog/repositories/graylog/tags/?page_size=1000" | jq '.results | .[] | .name' -r | grep -Ev "\-1$"))
# If version is supplied, validate it against list of available versions:
if [ $GRAYLOG_VERSION ]; then
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    if [[ ! "${GRAYLOG_VERSIONS_AVAILABLE[@]}" =~ ^$GRAYLOG_VERSION$ ]]; then
        ver="${GRAYLOG_VERSION:0:2}"
        echo -e "${URED}Graylog version not found: $GRAYLOG_VERSION\n${NC}However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${GRAYLOG_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
    fi
else
    # Set to latest Graylog version available:
    GRAYLOG_VERSION=$(for i in "${GRAYLOG_VERSIONS_AVAILABLE[@]}"; do echo $i; done | sort --version-sort | tail -n 1)
fi

### MongoDB ###
# MongoDB tag pulling is currently borked, but that's ok bc they have a ton of addtl tags to parse through anyway, so just listing all compatible versions manually:
MONGODB_VERSIONS_AVAILABLE=(4.0 4.2 4.4 5.0 6.0 7.0)
# If version is supplied, validate it against list of available versions:
if [ $MONGODB_VERSION ]; then
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    if [[ ! "${MONGODB_VERSIONS_AVAILABLE[@]}" =~ ^$MONGODB_VERSION$ ]]; then
        ver="${MONGODB_VERSION:0:2}"
        echo -e "${URED}MongoDB version not found: $MONGODB_VERSION\n${NC}However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${MONGODB_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
    fi
else
    MONGODB_VERSION=$(for i in "${MONGODB_VERSIONS_AVAILABLE[@]}"; do echo $i; done | sort --version-sort | tail -n 1)
fi

### Opensearch ###
# Fetch available Opensearch versions from Docker hub:
OPENSEARCH_VERSIONS_AVAILABLE=($(curl -sL --fail "https://hub.docker.com/v2/namespaces/opensearchproject/repositories/opensearch/tags/?page_size=1000" | jq '.results | .[] | .name' -r))
# If version is supplied, validate it against list of available versions:
if [ $OPENSEARCH_VERSION ]; then
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    if [[ ! "${OPENSEARCH_VERSIONS_AVAILABLE[@]}" =~ ^$OPENSEARCH_VERSION$ ]]; then
        ver="${OPENSEARCH_VERSION:0:2}"
        echo -e "${URED}Opensearch version not found: $OPENSEARCH_VERSION\n${NC}However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${OPENSEARCH_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
    fi
else
    OPENSEARCH_VERSION="latest"
fi

echo -e "Graylog version    : $GRAYLOG_VERSION"
echo -e "MongoDB version    : $MONGODB_VERSION"
echo -e "Opensearch version : $OPENSEARCH_VERSION"

# Update docker-compose.yml with Graylog stack versions:
sed -i "s/GRAYLOG_VERSION=/GRAYLOG_VERSION=$GRAYLOG_VERSION/" ~/.env
sed -i "s/MONGODB_VERSION=/MONGODB_VERSION=$MONGODB_VERSION/" ~/.env
sed -i "s/OPENSEARCH_VERSION=/OPENSEARCH_VERSION=$OPENSEARCH_VERSION/" ~/.env

echo -e "${UGREEN}Updating Memory Configurations to match system${NC}"
sed -i "s+Xms2g+Xms$Q_RAM\m+g" ~/docker-compose.yml
sed -i "s+Xmx2g+Xmx$Q_RAM\m+g" ~/docker-compose.yml
sed -i "/GRAYLOG_MONGODB_URI/a\      \GRAYLOG_SERVER_JAVA_OPTS: \"-Xms$Q_RAM\m -Xmx$Q_RAM\m -XX:NewRatio=1 -server -XX:+ResizeTLAB -XX:-OmitStackTraceInFastThrow -Djdk.tls.acknowledgeCloseNotify=true -Dlog4j2.formatMsgNoLookups=true\"" ~/docker-compose.yml
sed -i "s+941828f6268291fa3aa87a866e8367e609434f42761bdf02dc7fc7958897bae6+$GLSHA256+g" ~/docker-compose.yml
unset GLSHA256

#Because RH
if [ $(which yum) ]; then
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

echo -e "${UGREEN}Starting up Docker Containers${NC}"
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
curl https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/gl_starter_pack.json -o ~/gl_starter_pack.json &>> "$LOG_FILE"
#wget https://raw.githubusercontent.com/graylog-labs/graylog-playground/add-version-selection/autogl/gl_starter_pack.json -P ~/ &>> "$LOG_FILE"
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