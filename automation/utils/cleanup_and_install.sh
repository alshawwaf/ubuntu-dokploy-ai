#!/bin/bash
set -x

# Kill processes on critical ports
echo "Apps on port 80:"
sudo lsof -t -i:80 | xargs -r sudo kill -9
echo "Apps on port 443:"
sudo lsof -t -i:443 | xargs -r sudo kill -9
echo "Apps on port 3000:"
sudo lsof -t -i:3000 | xargs -r sudo kill -9

# Stop and remove all docker containers
if [ -n "$(sudo docker ps -aq)" ]; then
    echo "Stopping containers..."
    sudo docker stop $(sudo docker ps -aq)
    echo "Removing containers..."
    sudo docker rm -f $(sudo docker ps -aq)
fi

# Remove all volumes
if [ -n "$(sudo docker volume ls -q)" ]; then
    echo "Removing volumes..."
    sudo docker volume rm $(sudo docker volume ls -q)
fi

# Prune everything
echo "Pruning docker system..."
sudo docker system prune -a --volumes -f

# Remove Dokploy directory
echo "Removing /etc/dokploy..."
sudo rm -rf /etc/dokploy

# Install Dokploy
echo "Installing Dokploy..."
curl -sSL https://dokploy.com/install.sh | sudo sh
