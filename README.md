# Mihomo Gateway

Ubuntu/Debian Gateway + Mihomo + MetaCubeXD installer.

## Repository structure

```text
mihomo-gateway/
├── install-gateway-docker.sh
├── gateway.conf
├── mihomo.yaml.template
├── compose.yaml.template
└── README.md
```

## Configuration

### `gateway.conf`

This is the public configuration/defaults file. Edit it when you want to change defaults for new installations:

- LAN address
- DHCP range
- upstream DNS
- timezone
- Mihomo proxy/API ports
- Docker image names
- optional subscription URL

Do not put a real subscription URL containing a private token into a public repository. Leave:

```bash
SUBSCRIPTION_URL_DEFAULT=""
```

and enter the subscription interactively during installation.

If the repository is private and you deliberately want a pre-filled subscription, use:

```bash
SUBSCRIPTION_URL_DEFAULT="https://..."
```

### `mihomo.yaml.template`

This contains the complete Mihomo configuration that was previously embedded in the shell script.

The installer substitutes:

```text
LAN_IP
LAN_NETWORK
MIHOMO_PORT
MIHOMO_API_PORT
CLASH_SECRET
SUBSCRIPTION_URL
```

into the template and creates:

```text
/opt/mihomo-gateway/config/config.yaml
```

### `compose.yaml.template`

This contains the Docker Compose definition that was previously generated inside the script.

The installer substitutes:

```text
MIHOMO_IMAGE
METACUBEXD_IMAGE
TZ
DEFAULT_BACKEND_URL
```

and creates:

```text
/opt/mihomo-gateway/compose.yaml
```

## Runtime state

The installer still keeps machine-specific settings in:

```text
/var/lib/mihomo-gateway/gateway.env
```

This preserves the original behavior of the script. Interface names, MAC addresses, LAN settings, subscription and API password are kept locally.

Original host configurations are still backed up under:

```text
/var/lib/mihomo-gateway/original/
```

## First launch

The workflow remains:

1. Run the installer.
2. The script configures LAN/WAN and DHCP.
3. The script stops and asks you to reconnect through LAN using the configured gateway address.
4. Run the installer again.
5. Install Docker, Mihomo and MetaCubeXD.
6. Enter the API password and subscription, unless a default subscription was explicitly configured.
7. The script validates the Mihomo configuration and starts the containers.

## Important

The installer downloads these files from the `main` branch of the repository:

```text
gateway.conf
mihomo.yaml.template
compose.yaml.template
```

Therefore changes to these files affect subsequent installer runs.

The installer has built-in fallback defaults for the basic gateway settings if `gateway.conf` cannot be downloaded. The Mihomo and Compose templates, however, must be reachable when those configurations need to be generated.
