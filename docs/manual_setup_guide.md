# Manual Deployment Guide for Bare-Metal Ubuntu

This guide outlines the steps to deploy the Dokploy environment on a fresh Ubuntu server (e.g., in a datacenter) using the provided automation scripts.

## Prerequisites

-   A fresh install of **Ubuntu 20.04 or 22.04 LTS**.
-   **Root or Sudo access** to the serve.
-   A **public IP address** for the server.
-   Access to manage your domain's **DNS records**.
-   **SSH Key Pair**: You must have an SSH private/public key pair on your local machine.

## 1. Prepare the Server

Ensure your server is accessible via SSH and has Python installed.

```bash
# SSH into your server
ssh user@your-server-ip

# Update and install Python (if not present)
sudo apt update && sudo apt install -y python3 python3-pip
```

## 2. Configure DNS

Point your wildcard domain to the server's public IP.

-   **Type**: A Record
-   **Name**: `*` (Wildcard)
-   **Value**: `YOUR_SERVER_IP`
-   **TTL**: 3600 (or default)

For example, if your domain is `example.com`, `*.example.com` will resolve to your server's IP.

## 3. Install Docker & Dokploy

You can install Docker and Dokploy manually, or let the automation script handle it. The script checks for their presence and installs them if missing.

If you prefer to install manually:
```bash
# Install Docker
curl -fsSL https://get.docker.com | sh

# Install Dokploy
curl -sSL https://dokploy.com/install.sh | sudo sh
```

## 4. Run the Automation Script

Run the `dokploy_automate.py` script from your **local machine** (not the server). This script will:
1.  Connect to your server via SSH.
2.  Configure Dokploy with your admin credentials.
3.  Deploy the applications defined in `dokploy_config.json`.

### Command

```bash
python3 automation/dokploy_automate.py \
  --url "http://YOUR_SERVER_IP:3000" \
  --email "admin@example.com" \
  --password "secure_password" \
  --domain "example.com" \
  --ssh-user "your-ssh-username" \
  --ssh-private "~/.ssh/id_rsa" \
  --ssh-public "~/.ssh/id_rsa.pub"
```

### Arguments

-   `--url`: The URL where Dokploy is running (usually `http://IP:3000`).
-   `--email`: Specific admin email for Dokploy.
-   `--password`: Admin password to set.
-   `--domain`: Your root domain (e.g., `ai.alshawwaf.ca`).
-   `--ssh-user`: **(New)** The SSH username on the remote server (defaults to `adminuser`).
-   `--ssh-private`: Path to your local private SSH key.
-   `--ssh-public`: Path to your local public SSH key.

## Troubleshooting

-   **SSH Connection Issues**: Ensure your public key is in `~/.ssh/authorized_keys` on the server for the user you are connecting as.
-   **Permission Denied**: The script attempts to use `sudo` for many operations. Ensure your user has passwordless sudo access or you may need to configure it.
    -   *Tip*: Add your user to sudoers with `NOPASSWD`.
