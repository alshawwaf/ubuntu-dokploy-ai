import paramiko
import os
import argparse
import time
import sys

def setup_server(ip, username, password, ssh_public_key_path):
    print(f"Connecting to {ip} as {username}...")
    
    # Initialize SSH client
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        client.connect(ip, username=username, password=password)
        print("Connected successfully.")
        
        # 1. Read local public key
        try:
            with open(os.path.expanduser(ssh_public_key_path), "r") as f:
                public_key = f.read().strip()
        except Exception as e:
            print(f"Error reading public key: {e}")
            return False

        # 2. Add public key to authorized_keys
        print("Adding public key to authorized_keys...")
        commands = [
            "mkdir -p ~/.ssh",
            "chmod 700 ~/.ssh",
            f"grep -qF '{public_key}' ~/.ssh/authorized_keys || echo '{public_key}' >> ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys"
        ]
        
        for cmd in commands:
            stdin, stdout, stderr = client.exec_command(cmd)
            exit_status = stdout.channel.recv_exit_status()
            if exit_status != 0:
                print(f"Error executing command: {cmd}")
                print(stderr.read().decode())
                return False
        print("SSH key added.")

        # 3. Setup sudo (optional, but good for passwordless sudo if needed later)
        # Actually dokploy_automate uses sudo. If the user has password, sudo might prompt.
        # We should check if we can run sudo without password.
        print("Checking sudo access...")
        stdin, stdout, stderr = client.exec_command("sudo -n true")
        if stdout.channel.recv_exit_status() != 0:
            print("Sudo requires password. Configuring passwordless sudo for user...")
            # This is risky but often needed for automation if we can't interact
            # This is risky but often needed for automation if we can't interact
            sudo_cmd = f"sudo -S -p '' sh -c 'echo \"{username} ALL=(ALL) NOPASSWD:ALL\" | tee /etc/sudoers.d/{username}'"
            stdin, stdout, stderr = client.exec_command(sudo_cmd)
            stdin.write(password + "\n")
            stdin.flush()
            # Wait for command to finish
            if stdout.channel.recv_exit_status() != 0:
                print("Failed to set up passwordless sudo. Automation might fail later.")
                print(stderr.read().decode())
            else:
                print("Passwordless sudo configured.")

        # 4. Install Docker & Dokploy
        print("Installing Docker and Dokploy...")
        install_cmds = [
             "command -v docker >/dev/null 2>&1 || (curl -fsSL https://get.docker.com | sudo -S -p '' sh)",
             "test -f /etc/dokploy/dokploy.sh || (curl -sSL https://dokploy.com/install.sh | sudo -S -p '' sh)"
        ]

        for cmd in install_cmds:
            print(f"Executing: {cmd[:50]}...")
            stdin, stdout, stderr = client.exec_command(cmd)
            stdin.write(password + "\n")
            stdin.flush()
            
            # Wait for long running commands
            while not stdout.channel.exit_status_ready():
               if stdout.channel.recv_ready():
                   # Print output to keep connection alive and show progress
                   sys.stdout.write(stdout.channel.recv(1024).decode())
               if stderr.channel.recv_ready():
                   sys.stderr.write(stderr.channel.recv(1024).decode())
               time.sleep(1)
            
            if stdout.channel.recv_exit_status() != 0:
                print(f"Command failed: {cmd}")
                print(stderr.read().decode())
                return False

        # 5. Install Python3 for automation script
        print("Ensuring Python3 is installed...")
        print("Ensuring Python3 is installed...")
        py_cmd = "sudo -S -p '' apt-get update && sudo -S -p '' apt-get install -y python3 python3-pip"
        stdin, stdout, stderr = client.exec_command(py_cmd)
        stdin.write(password + "\n")
        stdin.flush()
        # Drain output
        stdout.read() 
        
        print("Bootstrap complete!")
        return True

    except Exception as e:
        print(f"Connection failed: {e}")
        return False
    finally:
        client.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bootstrap Ubuntu Server")
    parser.add_argument("--ip", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--pubkey", default="~/.ssh/id_rsa.pub")
    
    args = parser.parse_args()
    
    success = setup_server(args.ip, args.user, args.password, args.pubkey)
    if not success:
        sys.exit(1)
