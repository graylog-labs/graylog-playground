# GoGoGraylog! aka graylog.me/want
This script fetches and deploys a fully-functional single-node Graylog stack in Docker.

Simply run either of the following commands:

- As `root` user: `bash <(wget -qO- graylog.me/want)`
- As a non-root user: `wget -qO- graylog.me/want > gogograylog.sh && sudo bash gogograylog.sh`


# Usage

```
 --graylog [version]		-- Specify Graylog version to use (defaults to latest stable)
 --opensearch [version]		-- Specify OpenSearch version to use (defaults to latest stable)
 --mongodb [version]		-- Specify MongoDB version to use (defaults to latest stable)
 --graylog-memory [N]gb		-- Specify GB of RAM for Graylog (defaults to 25% of system memory)
 --opensearch-memory [N]gb	-- Specify GB of RAM for OpenSearch (defaults to 25% of system memory)
 -p|--preserve			    -- Does NOT delete existing containers & volumes
 --branch [branch]		    -- Specify which git branch of the script to use. Defaults to "main." Only use if you know what you are doing!
 -h|--help			        -- Prints this help message
```


# What it Does

- Installs Docker if not present. (Does ***NOT*** update existing Docker install)
- Enables Docker system service
- Allows you to select which version of Graylog/MongoDB/OpenSearch you want to use by passing flags. Defaults to latest versions of each.
  - Also allows selecting pre-release versions of Graylog (e.g. "alpha", "beta", and "rc")
- Deletes existing Docker resources created by previous runs of the script (allows you to preserve these though by passing the --preserve flag). Specifically:
  - Containers created by its `docker-compose.yml`,
  - graylog_config volume
  - graylog_data volume
  - graylog_journal volume
  - mongodb_data volume
  - opensearch_data volume
  - graylog_network network
- Fetches the `docker-compose.yml` file from this repo and modifies it based on user supplied parameters:
  - Graylog, MongoDB, and OpenSearch versions
  - RAM assigned to Graylog and OpenSearch containers
  - Graylog admin password
- Grabs the `gl_start_pack.json` Content Pack which contains common inputs, and automatically installs and enables it


# What it Doesn’t Do

- Allow users to run without root
- Change anything not immediately relevant to installing & running Graylog, like:
    - Upgrading Docker
    - Changing firewall rules
    - Upgrading unrelated base system packages
- Allow running on hosts with less then 2GB of RAM
- Checks selected versions against the Graylog compatibility matrix to ensure you’re using a supported version combination.
    - This is intentional as it allows users to test things!


# Pre-Configured Ports

The following ports are included in the `docker-compose.yml`. All are disabled by default except for 443 and 9000.

To enable ports, edit `docker-compose.yml` then run `docker compose up -f /root/docker-compose.yml -d`.

| Port | Description |
| ---- | ----------- |
| tcp/443  | Server API (https) |
| udp/514  | Syslog |
| tcp/514 | Syslog |
| tcp/5044 | Beats |
| tcp/5050 | Raw |
| udp/5050 | Raw |
| tcp/5555 | CEF |
| udp/5555 | CEF |
| tcp/5556 | Palo Alto Networks v9+ |
| tcp/5557 | Palo Alto Networks v8.x |
| tcp/9000 | Server API (plaintext) |
| tcp/12201 | GELF/Graylog Forwarder |
| udp/12201 | GELF |


## Distro Specific Stuff
### WSL

- Updates wsl.conf to run Docker on WSL start
- Updates BashRC to prompt with the Graylog instance IP/Port because WSL IP's change with each startup
