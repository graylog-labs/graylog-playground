#!/bin/bash
# Graylog Automated Docker Install
# Recommend 16GB of RAM and at least 2 cpus but it CAN run on less

# Validated this script works on the following distros (as of May 22 2024):
# Debian 10, 11, 12
# Ubuntu 20.04, 22.04, 24.04
# RHEL 8, 9
# CentOS Stream 8, 9
# Rocky Linux 8, 9

# =========================== #
# Initialize global variables #
# =========================== #

# Formatting vars:
NC='\033[0m' # default color/format
RED='\033[0;31m' # red
URED='\033[4;31m' # underlined red
UGREEN='\033[4;32m' # underlined green
UYELLOW='\033[4;33m' # underlined yellow
BRED='\033[1;31m' # bold red
BGREEN='\033[1;32m' # bold green
BCYAN='\033[1;36m' # bold cyan
DGRAYBG='\033[0;100m' # dark gray background

# Flag vars:
GRAYLOG_VERSION=
OPENSEARCH_VERSION=
MONGODB_VERSION=
BRANCH="main"

# External system vars:
LOG_FILE="/var/log/graylog-server/deploy-graylog.log"
TOTAL_MEM=$(awk '/MemTotal/{printf "%d\n", $2 / 1024 / 1024;}' < /proc/meminfo)
GL_MEM=
OS_MEM=
ARCH=$(uname -m)

# Exit if running as non-root user:
if [ "$EUID" -ne 0 ]; then
  echo -e "${URED}ERROR - This script must be run as root, exiting...${NC}"
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
        # Use for sending info needed only when troubleshooting
        let prival++;;
      INFO)
        # Use for sending good to know command output, but not need to know during script execution
        ;;
      NOTICE)
        # Use for sending need to know info during script execution, but not anything that needs to be addressed
        let prival--
        echo -e "$message";; # Send to stdout to notify user as well
      WARN|WARNING)
        # Use for warning user about something that may need to be addressed but does not break anything
        let prival=$prival-2
        echo -e "${UYELLOW}$message${NC}";; # Send to stdout to notify user as well
      ERROR)
        # Use to show output of commands that break script execution. Should always be followed by an exit 1
        let prival=$prival-3
        echo -e "${URED}$message${NC}";; # Send to stdout to notify user as well
      *)
        log "DEBUG" "Unknown severity level $1. Supported severities are DEBUG, INFO, NOTICE, WARN, and ERROR";;
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
    echo "gogograylog.sh Usage:"
    echo
    echo -e " --graylog [version]\t\t-- Specify Graylog version to use (defaults to latest stable)"
    echo -e " --opensearch [version]\t\t-- Specify OpenSearch version to use (defaults to latest stable)"
    echo -e " --mongodb [version]\t\t-- Specify MongoDB version to use (defaults to latest stable)"
    echo -e " --graylog-memory [N]gb\t\t-- Specify GB of RAM for Graylog (defaults to 25% of system memory)"
    echo -e " --opensearch-memory [N]gb\t-- Specify GB of RAM for OpenSearch (defaults to 25% of system memory)"
    echo -e " -p|--preserve\t\t\t-- Does NOT delete existing containers & volumes"
    echo -e " --branch [branch]\t\t-- Specify which git branch of the script to use. Defaults to \"main.\" Only use if you know what you are doing!"
    echo -e " -h|--help\t\t\t-- Prints this help message"
    exit 0
}



# ================ #
# Preflight Checks #
# ================ #

# Clear current screen for cleanliness:
clear

# Process flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --graylog)
      shift
      [ $# = 0 ] && log "ERROR" "No Graylog version specified." && exit 1
      GRAYLOG_VERSION="$1"
      log "INFO" "Graylog version: $1"
      shift;;
    --opensearch)
      shift
      [ $# = 0 ] && log "ERROR" "No OpenSearch version specified." && exit 1
      OPENSEARCH_VERSION="$1"
      log "INFO" "Opensearch version: $1"
      shift;;
    --mongodb)
      shift
      [ $# = 0 ] && log "ERROR" "No MongoDB version specified." && exit 1
      MONGODB_VERSION="$1"
      log "INFO" "MongoDB version: $1"
      shift;;
    -p|--preserve)
      PRESERVE=y
      shift;;
    --random-password)
      RANDOM_PASSWORD=y
      shift;;
    --branch)
      shift
      if [ $# = 0 ]; then
        log "NOTICE" "No branch specified, defaulting to \"main\""
      else
        BRANCH="$1"
        echo -e "\n${UYELLOW}Using branch \"$1\" of this script, good luck!${NC}\n"
      fi
      shift;;
    --graylog-memory)
      shift
      GL_MEM=$(echo $1 | tr -d [[:alpha:]])
      log "NOTICE" "${UYELLOW}User override:${NC} Using ${UYELLOW}$GL_MEM GB${NC} of RAM for Graylog.\n"
      shift;;
    --opensearch-memory)
      shift
      OS_MEM=$(echo $1 | tr -d [[:alpha:]])
      log "NOTICE" "${UYELLOW}User override:${NC} Using ${UYELLOW}$OS_MEM GB${NC} of RAM for OpenSearch.\n"
      shift;;
    -h|--help)
      help;;
    *)
      log "WARN" "Unknown flag: $1"
      help;;
  esac
done

log "NOTICE" "Executing preflight checks..."
echo

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
    log "ERROR" "No /etc/os-release file found. This script only works in Linux! Exiting..."
    exit 1
fi

# Test for WSL
if grep -qi microsoft /proc/version; then
  WSL=1
fi

# Get interface IP address of system
if [ $(command -v ip) ]; then
    read -r _{,} GATEWAY_IP _ _ _ INTERNAL_IP _ < <(ip r g 1.0.0.0)
else
    INTERNAL_IP=$(hostname -I | cut -f 1 -d ' ')
fi

# Install prerequisites:
log "NOTICE" "Installing prerequisites..."

# Install jq separately bc 1) it has no runtime deps, and 2) it is not available in RHEL 7 at all. 
# So installing it from its Github repo avoids unnecessary logic below.
curl -fsSL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux64 -o /usr/bin/jq
chmod +x /usr/bin/jq
# Use jq to make sure you have the latest non-rc version installed (ugly I know but can't think of a better way right now)
curl -fsSL https://github.com/jqlang/jq/releases/download/$(curl -fsSL https://api.github.com/repos/jqlang/jq/tags | jq -r '.[0].name | select(test("rc")|not?)')/jq-linux64 -o /usr/bin/jq

echo
if [ $(command -v apt-get) ]; then
    apt-get update &>> "$LOG_FILE"
    apt-get install -y ca-certificates curl gnupg lsb-release jq curl &>> "$LOG_FILE"
elif [ $(command -v yum) ]; then
    yum check-update &>> "$LOG_FILE"
    yum install -y ca-certificates curl gnupg curl yum-utils &>> "$LOG_FILE"
else
    echo -e "${URED}This system doesn't appear to be supported. No supported package manager ${UGREEN}(apt/yum)${URED} was found."
    echo -e "Automated installation is only availble for Debian and Red-Hat based distributions, including ${UGREEN}Ubuntu${URED} and ${UGREEN}CentOS${URED}."
    echo -e "${UGREEN}$NAME${URED} is not a supported distribution at this time.${NC}"
    exit 1
fi

# Get external IP of system:
EXTERNAL_IP=$(curl https://ipecho.net/plain -k 2> /dev/null)

# CPU arch check
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    echo -e "${URED}Graylog is only supported on x86_64 systems. You are running $ARCH${NC}"
    exit 1
fi

# Check for AVX support in CPU (bc MongoDB 5.0+ needs it):
if [ ! $(grep avx /proc/cpuinfo) ]; then
    NO_AVX=true
fi

# Determine default Graylog & OpenSearch RAM assignment:
if [ -z $GL_MEM ] && [ -z $OS_MEM ]; then
    # Set OpenSearch mem to 50% system mem, max of 31:
    OS_MEM=$((TOTAL_MEM / 2))
    if [ $OS_MEM -gt 31 ]; then
        OS_MEM=31
    fi

    # Set Graylog mem to 25% system mem, max of 8:
    GL_MEM=$(awk '/MemTotal/{printf "%d\n", $2 * .25 / 1024 / 1024;}' < /proc/meminfo)
    if [ $GL_MEM -gt 8 ]; then
        GL_MEM=8
    fi
fi



# ===================== #
# Main script execution #
# ===================== #

# Initialize log file:
log "INFO" "Started new gogograylog deployment!"

# Clear current screen for cleanliness:
clear

# ===================== #
# Cleanup Previous Runs #
# ===================== #

echo -e "${URED}### IMPORTANT! ###${NC}"
echo
echo "By default, this script performs a clean install of Graylog, MongoDB, and OpenSearch, deleting existing containers and volumes from previous runs of this script."
echo
echo "This is generally best practice, as reusing existing volumes is problematic if changing software versions between script executions."
echo
read -p "$(echo -e "${URED}Confirm deletion of all existing Graylog, MongoDB, and OpenSearch resources [Y/n]:${NC} ")" x
x=${x,,} # ,, converts value to lowercase
if [ "$x" == "n" ]; then
    echo -e "\n${UGREEN}NOT deleting existing Docker resources. Note: You can skip this prompt next time by passing the '--preserve' flag to the script!${NC}\n"
else
    if [ $(command -v docker) ]; then
        echo -e "\n${URED}Deleting existing Graylog Docker resources...${NC}\n"
        docker compose -f ~/docker-compose.yml stop &>> "$LOG_FILE"
        docker compose -f ~/docker-compose.yml rm -f &>> "$LOG_FILE"
        docker volume rm -f graylog_config &>> "$LOG_FILE"
        docker volume rm -f graylog_data &>> "$LOG_FILE"
        docker volume rm -f graylog_journal &>> "$LOG_FILE"
        docker volume rm -f mongodb_data &>> "$LOG_FILE"
        docker volume rm -f opensearch_data &>> "$LOG_FILE"
        docker network rm -f graylog_network &>> "$LOG_FILE"
    fi
fi

# Delete existing docker-compose.yml file:
[[ -e ~/docker-compose.yml ]] && rm -f ~/docker-compose.yml

# Clear current screen for cleanliness:
clear



# ================= #
# Version Selection #
# ================= #

### Graylog ###
# If user specified a Graylog version, check it against available versions.
# Else fetch and use latest GA Graylog version.
if [ $GRAYLOG_VERSION ]; then
    # Fetch ALL available Graylog versions from Docker hub:
    GRAYLOG_VERSIONS_AVAILABLE=($(curl -sL --fail "https://hub.docker.com/v2/repositories/graylog/graylog/tags/?page_size=1000" | jq '.results | .[] | .name' -r | sort --version-sort))
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    while [[ ! "${GRAYLOG_VERSIONS_AVAILABLE[@]}" =~ (^| )"$GRAYLOG_VERSION"( |$) ]]; do
        ver="${GRAYLOG_VERSION:0:2}"
        echo -e "${BCYAN}Graylog ${BRED}version not found: $GRAYLOG_VERSION${NC}"
        echo "However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${GRAYLOG_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
        read -p "Choose another Graylog version: " GRAYLOG_VERSION
        clear
    done
else
    GRAYLOG_VERSION=$(curl -sL --fail "https://hub.docker.com/v2/repositories/graylog/graylog/tags/?page_size=1000" | jq '.results | .[] | .name' -r | sort --version-sort | awk '!/beta/' | awk '!/alpha/' | awk '!/-rc/' | grep -v "\-1$" | tail -n1)
fi

### MongoDB ###
# MongoDB tag pulling is currently borked, but that's ok bc they have a ton of addtl tags to parse through anyway, so just listing all compatible versions manually:
MONGODB_VERSIONS_AVAILABLE=(4.0 4.2 4.4 5.0 6.0 7.0)
# If version is supplied, validate it against list of available versions:
if [ $MONGODB_VERSION ]; then
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    while [[ ! "${MONGODB_VERSIONS_AVAILABLE[@]}" =~ (^| )${MONGODB_VERSION}( |$) ]]; do
        ver="${MONGODB_VERSION:0:2}"
        echo -e "${BCYAN}MongoDB ${BRED}version not found: $MONGODB_VERSION${NC}"
        echo "However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${MONGODB_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
        read -p "Choose another MongoDB version: " MONGODB_VERSION
        clear
    done
else
    MONGODB_VERSION=$(for i in "${MONGODB_VERSIONS_AVAILABLE[@]}"; do echo $i; done | sort --version-sort | tail -n 1)
fi

# Check if supplied MongoDB version is compatible with CPU:
ver="${MONGODB_VERSION:0:1}" # note that this instance $ver is diff than above. Above includes a trailing "." bc it is used for string comparison. This instance has no "." bc it is used for numeric comparison.
if [ $NO_AVX ] && [ $ver -ge 5 ]; then
    log "ERROR" "Your CPU does not support AVX Instructions, please choose a MongoDB version less than 5.x!"
    echo -e "Alternatively, if running this on a VM, change the vCPU generation to Intel Sandy Bridge or newer and try again."
    exit 1
fi

### Opensearch ###
# If user specified an Opensearch version, check it against available versions.
# Else fetch and use latest stable version (hard limit of 2.x for now until 3.x goes GA AND is supported by Graylog)
OPENSEARCH_VERSIONS_AVAILABLE=($(curl -sL --fail "https://hub.docker.com/v2/namespaces/opensearchproject/repositories/opensearch/tags/?page_size=1000" | jq '.results | .[] | .name' -r | grep -v "latest"))
# If version is supplied, validate it against list of available versions:
if [ $OPENSEARCH_VERSION ]; then
    # If version supplied is not found in list of available versions, search the list again for the first 2 characters of the supplied version for suggestions:
    while [[ ! "${OPENSEARCH_VERSIONS_AVAILABLE[@]}" =~ (^| )${OPENSEARCH_VERSION}( |$) ]]; do
        ver="${OPENSEARCH_VERSION:0:2}"
        echo -e "${BCYAN}Opensearch ${BRED}version not found: $OPENSEARCH_VERSION${NC}"
        echo "However we found similar ones here:"
        # Search available version list again for partial matches of supplied version:
        for i in "${OPENSEARCH_VERSIONS_AVAILABLE[@]}"; do [[ $i =~ ^$ver ]] && echo $i; done
        read -p "Choose another OpenSearch version: " OPENSEARCH_VERSION
        clear
    done
else
    OPENSEARCH_VERSION=$(for i in "${OPENSEARCH_VERSIONS_AVAILABLE[@]}"; do echo $i; done | sort --version-sort | awk '!/beta/' | awk '!/alpha/' | awk '!/-rc/' | awk '!/3/' | grep -v "\-1$" |  tail -n 1)
fi



# ==================== #
# Display Info to User #
# ==================== #

# Clear current screen for cleanliness:
clear

# Display system details for user:
echo -e "${DGRAYBG}System Information${NC}"
echo -e "Total Memory\t\t: ${UGREEN}$TOTAL_MEM GB${NC}"
echo -e "RAM given to Graylog\t: ${UGREEN}$GL_MEM GB${NC}"
echo -e "RAM given to OpenSearch\t: ${UGREEN}$OS_MEM GB${NC}"
echo -e "System Architecture\t: ${UGREEN}$ARCH${NC}"
echo -e "Internal IP\t\t: ${UGREEN}$INTERNAL_IP${NC}"
echo -e "External IP\t\t: ${UGREEN}$EXTERNAL_IP${NC}"
echo -e "Log file location\t: ${UGREEN}$LOG_FILE${NC}"
echo
echo -e "${DGRAYBG}Software Versions${NC}"
if [ $(command -v docker) ]; then
    echo -e "Docker version\t\t: ${UGREEN}$(docker -v | cut -d' ' -f3 | cut -d',' -f1)${NC}"
else
    echo -e "Docker version\t\t: [not installed]"
fi
echo -e "Graylog version\t\t: ${UGREEN}$GRAYLOG_VERSION${NC}"
echo -e "MongoDB version\t\t: ${UGREEN}$MONGODB_VERSION${NC}"
echo -e "Opensearch version\t: ${UGREEN}$OPENSEARCH_VERSION${NC}\n"

echo -e "${DGRAYBG}Other Notices:${NC}\n"

# Memory capacity logic checks:
if [ $TOTAL_MEM -le 2 ]; then
    echo -e "  - ${UYELLOW}WARNING:${NC} Your system only has ${UYELLOW}$TOTAL_MEM${NG} GB of RAM. Graylog and OpenSearch should have at least ${UYELLOW}1 GB of RAM EACH${NG}. ${URED}Continuing with this deployment may break your machine!${NC}\n"
elif [ $TOTAL_MEM -le 8 ]; then
    echo -e "  - NOTICE: Graylog running on a single node will perform much better with at least ${UGREEN}8 GB${NC} of system memory! ${UYELLOW}Performance might be impacted...${NC}\n"
fi

[ $PRESERVE ] && log "NOTICE" " - Preserving existing Docker environment."
[ $RANDOM_PASSWORD ] && log "NOTICE" " - Using random Graylog admin password."

echo
read -p "Review all information above. Do you still want to proceed with deployment? [y/N] " x
x=${x,,} # ,, converts value to lowercase
x=${x:0:1} # reduces to first character only
if [ "$x" != "y" ]; then
    log "INFO" "User cancelled deployment, exiting..."
    exit 0
fi

# =================== #
# Configure & Install #
# =================== #

# Clear current screen for cleanliness:
clear

# Set Admin Password
if [ $RANDOM_PASSWORD ]; then
    PSWD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; echo)"
    GLSHA256=$(echo "$PSWD" | tr -d '\n'| sha256sum | cut -d" " -f1)
else
    PSWD="bunk"
    until [ "$PSWD" == "$PSWD2" ]
    do
        read -sp "Enter Desired Graylog Admin Password: " PSWD
        echo
        read -sp "Enter Desired Graylog Admin Password again: " PSWD2
        echo
        if [[ "$PSWD" == "$PSWD2" ]]; then
            GLSHA256=$(echo "$PSWD" | tr -d '\n'| sha256sum | cut -d" " -f1)
        else
            echo -e "${RED}\nPasswords do not match, please try again...${NC}\n"
        fi
    done
fi

# Install Docker
clear
if [ $(command -v docker) ]; then
    echo -e "\n${UGREEN}Docker version installed:${NC} $(docker -v | cut -d' ' -f3 | cut -d',' -f1)"
else
    if [ $(command -v apt-get) ]; then
        export DEBIAN_FRONTEND=noninteractive
        echo -e "\n${UGREEN}Installing Docker...${NC}"
        # First, uninstall old packages if still present:
        for i in $(dpkg --get-selections | grep -E "(docker|containerd|runc)" | awk '{ print $1 }'); do apt-get remove $i; done
        mkdir -p /etc/apt/keyrings &>> "$LOG_FILE"
        curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        echo -e "\n\ndeb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        clear
    else
        echo -e "\n${UGREEN}Installing Docker and prerequisites...${NC}"
        # First, uninstall old packages if still present:
        for i in $(yum list installed | grep -E "(docker|containerd|runc)" | awk '{ print $1 }'); do yum remove $i; done
        # Force using CentOS repo since RHEL on x86_64 isn't supported yet:
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &>> "$LOG_FILE"
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        clear
    fi
fi

# Fetch docker-compose.yml and .env files from repo:
curl -fsSL https://raw.githubusercontent.com/graylog-labs/graylog-playground/$BRANCH/autogl/docker-compose.yml -o ~/docker-compose.yml &>> "$LOG_FILE"
curl -fsSL https://raw.githubusercontent.com/graylog-labs/graylog-playground/$BRANCH/autogl/.env -o ~/.env &>> "$LOG_FILE"

# Exit if failed to get docker-compose.yml from repo:
if [ ! -f ~/docker-compose.yml ]; then
    echo -e "${URED}Failed to grab docker compose file from GIT... Check your internet connection and try again${NC}"
    exit 1
fi

# Update .env:
log "NOTICE" "Updating Docker configurations to match specified specs..."
sed -i "s/GRAYLOG_VERSION=.*/GRAYLOG_VERSION=$GRAYLOG_VERSION/" ~/.env
sed -i "s/MONGODB_VERSION=.*/MONGODB_VERSION=$MONGODB_VERSION/" ~/.env
sed -i "s/OPENSEARCH_VERSION=.*/OPENSEARCH_VERSION=$OPENSEARCH_VERSION/" ~/.env
sed -i "s/GRAYLOG_MEMORY=.*/GRAYLOG_MEMORY=$GL_MEM/" ~/.env
sed -i "s/OPENSEARCH_MEMORY=.*/OPENSEARCH_MEMORY=$OS_MEM/" ~/.env
sed -i "s/GRAYLOG_ROOT_PASSWORD_SHA2=.*/GRAYLOG_ROOT_PASSWORD_SHA2=$GLSHA256/" ~/.env
unset GLSHA256

#Because RH
if [ $(command -v yum) ]; then
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

# Install syslog replay script:
curl -fsSL https://raw.githubusercontent.com/mrworkman/replay-syslog/master/replay-syslog.pl -o ~/replay-syslog.pl &>> "$LOG_FILE"
chmod 777 ~/replay-syslog.pl
if [ ! -d ~/log-samples ]; then
    mkdir --mode=755 ~/log-samples
fi

# ============== #
# Launch Graylog #
# ============== #

echo -e "\n${UGREEN}Starting up Docker Containers${NC}\n"
docker compose -f ~/docker-compose.yml up -d

count=0
while [[ ! $(curl -sI -u "admin:$PSWD" http://localhost:9000/api/system/cluster/nodes | head -n1 | cut -d' ' -f2) =~ ^2 ]] &>> "$LOG_FILE"; do
    ((count++))
    # Exit if any container returns ExitCode 1 (aka application within container indicated failure to start)
    if [ $(docker container inspect -f '{{.State.ExitCode}}' mongodb) -eq 1 ]; then
        log "ERROR" "MongoDB container failed to start. Run \`docker logs mongodb\` for more info."
        exit 1
    fi
    if [ $(docker container inspect -f '{{.State.ExitCode}}' opensearch) -eq 1 ]; then
        log "ERROR" "OpenSearch container failed to start. Run \`docker logs opensearch\` for more info."
        exit 1
    fi
    if [ $(docker container inspect -f '{{.State.ExitCode}}' graylog) -eq 1 ]; then
        log "ERROR" "Graylog container failed to start. Run \`docker logs graylog\` for more info."
        exit 1
    fi
    # If fail to reach Graylog API within 5 minutes, exit 1:
    if [ "$count" -eq "30" ]; then
        echo -e "${URED}Welp. Something went terribly wrong. Check the log file: $LOG_FILE. I'm giving up now! Byeeeeee${NC}"
        log "ERROR" "Graylog API failed to become reachable within 5 minutes, so exiting. Check container logs for MongoDB, Opensearch, and Graylog for more info."
        exit 1
    else
        echo -e "${BGREEN}Waiting for graylog to come online${NC}"
        sleep 10s
    fi
done

# Add inputs via CP
curl -fsSL https://raw.githubusercontent.com/graylog-labs/graylog-playground/$BRANCH/autogl/gl_starter_pack.json -o ~/gl_starter_pack.json &>> "$LOG_FILE"
for entry in ~/gl_*
do
  echo -e "\nInstalling Content Package: ${UGREEN}$entry${NC}\n"
  CP_ID=$(cat $entry | jq -r '.id')
  CP_VER=$(cat $entry | jq -r '.rev')
  echo -e "\n\nID:${UGREEN}$CP_ID${NC} and Version: ${UGREEN}$CP_VER${NC}\n"
  curl -fsSL -u "admin:$PSWD" -XPOST "http://localhost:9000/api/system/content_packs"  -H 'Content-Type: application/json' -H 'X-Requested-By: PS_Packer' -d @"$entry" &>> "$LOG_FILE"
  echo -e "\n\nEnabling Content Package: ${UGREEN}gl_starter_pack${NC}\n"
  curl -fsSL -u "admin:$PSWD" -XPOST "http://localhost:9000/api/system/content_packs/$CP_ID/$CP_VER/installations" -H 'Content-Type: application/json' -H 'X-Requested-By: PS_TeamAwesome' -d '{"parameters":{},"comment":""}' &>> "$LOG_FILE"
done



# ================== #
# Final Info Display #
# ================== #

# Clear current screen for cleanliness:
clear

echo -e "${BGREEN}Your Graylog Instance is up and running!${NC}"
echo -e "Internal URL:\t\t${UYELLOW}http://$INTERNAL_IP:9000${NC}"
echo -e "External URL:\t\t${UYELLOW}http://$EXTERNAL_IP:9000${NC}"
echo -e "Default user:\t\t${BCYAN}admin${NC}"
echo -e "Password:\t\t${BRED}$PSWD${NC}"
echo -e "Docker Compose file:\t${BGREEN}$(ls ~/docker-compose.yml)${NC}"
echo
echo -e "To make changes, edit the compose file and run:"
echo -e "${UYELLOW}docker compose -f ~/docker-compose.yml up -d${NC}"
echo
echo -e "Next Steps:"
echo
echo -e "\t1. Uncomment ports in $(ls ~/docker-compose.yml) to expose Inputs"
echo -e "\t2. Send in logs"
echo -e "\t3. Check out www.graylog.com for news and updates!"
echo
echo -e "Happy Logging!"
echo
echo -e "  ${BCYAN}- The Graylog Team${NC}\n"

unset PSWD
unset PSWD2