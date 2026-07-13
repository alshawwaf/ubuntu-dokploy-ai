import time
import argparse
import sys
import subprocess
import json
import os
import shlex

# Ensure requests and paramiko are installed
try:
    import requests
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
    import requests

try:
    import paramiko
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "paramiko"])
    import paramiko

print("DEBUG: Script started...")

ROOT_DOMAIN = os.environ.get("ROOT_DOMAIN", "")

def replace_domain(content):
    if content is None: return None
    if isinstance(content, str):
        return content.replace("{{DOMAIN}}", ROOT_DOMAIN)
    if isinstance(content, list):
        return [replace_domain(i) for i in content]
    if isinstance(content, dict):
        return {k: replace_domain(v) for k, v in content.items()}
    return content

def find_env_file(app_name):
    slugs = [
        app_name.lower().replace(" ", "-"),
        app_name.lower().replace(" ", "_"),
        app_name.lower(),
        "agentic" if "agentic" in app_name.lower() else None,
        "dev-hub" if "dev hub" in app_name.lower() else None,
    ]
    slugs = [s for s in slugs if s]
    search_dirs = [".", "automation", "automation/envs", "envs"]
    for directory in search_dirs:
        for slug in slugs:
            path = os.path.join(directory, f".env_{slug}")
            if os.path.exists(path):
                return path
    return None

def copy_env_file_to_remote(local_path, remote_ip, app_slug):
    try:
        target_path = f"/etc/dokploy/compose/{app_slug}/code/.env"
        print(f"Ensuring {target_path} on {remote_ip}...")
        
        # Check if we're running locally on the target VM
        is_local = False
        try:
            import socket
            if os.path.exists(f"/etc/dokploy/compose/{app_slug}"):
                is_local = True
        except:
            pass

        if is_local:
            print(f"Detected local execution. Copying {local_path} to {target_path}...")
            subprocess.run(["sudo", "mkdir", "-p", os.path.dirname(target_path)], check=True)
            subprocess.run(["sudo", "cp", local_path, target_path], check=True)
            subprocess.run(["sudo", "chmod", "644", target_path], check=True)
        else:
            # SSH copy
            print(f"Using SCP to copy {local_path} to {target_path} on {remote_ip}...")
            # We assume the user has sudo rights without password or we use a temporary directory
            subprocess.run([
                "ssh", "-o", "StrictHostKeyChecking=no", "-i", os.path.expanduser("~/.ssh/id_rsa"),
                f"{args.ssh_user}@{remote_ip}", f"sudo mkdir -p {os.path.dirname(target_path)}"
            ], check=True)
            
            # Copy to temp first then move with sudo
            temp_path = f"/tmp/.env_{app_slug}"
            subprocess.run(["scp", "-o", "StrictHostKeyChecking=no", "-i", os.path.expanduser("~/.ssh/id_rsa"), local_path, f"{args.ssh_user}@{remote_ip}:{temp_path}"], check=True)
            subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", "-i", os.path.expanduser("~/.ssh/id_rsa"), f"{args.ssh_user}@{remote_ip}", f"sudo mv {temp_path} {target_path}"], check=True)
            subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", "-i", os.path.expanduser("~/.ssh/id_rsa"), f"{args.ssh_user}@{remote_ip}", f"sudo chmod 644 {target_path}"], check=True)
            
        return True
    except Exception as e:
        print(f"Error copying env file: {e}")
        return False


def request_with_retry(
    method, url, max_retries=3, backoff_factor=2, timeout=30, **kwargs
):
    """Makes an HTTP request with retry logic for transient failures."""
    for attempt in range(max_retries):
        try:
            print(f"DEBUG: [REQ] {method} {url} (Attempt {attempt + 1})")
            start_ptr = time.time()
            response = requests.request(method, url, timeout=timeout, **kwargs)
            duration = time.time() - start_ptr
            print(f"DEBUG: [RES] {response.status_code} ({duration:.2f}s)")

            if response.status_code < 500:
                print(f"DEBUG: [BODY] {response.text[:200]}...")
                return response

            print(f"DEBUG: Server error {response.status_code}, retrying...")
        except requests.exceptions.RequestException as e:
            print(f"DEBUG: Request failed: {e}")
            if attempt == max_retries - 1:
                raise

        sleep_time = backoff_factor**attempt
        print(f"DEBUG: Sleeping {sleep_time}s before retry...")
        time.sleep(sleep_time)

    return requests.request(method, url, timeout=timeout, **kwargs)


def wait_for_dokploy(url, timeout=300):
    """Wait for Dokploy service to be accessible."""
    start_time = time.time()
    print(f"Waiting for Dokploy at {url}...")
    while time.time() - start_time < timeout:
        try:
            response = requests.get(url, timeout=10)
            if response.status_code == 200:
                print("Dokploy is up and running!")
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(5)
    print("Timeout waiting for Dokploy")
    return False


def register_admin(url, email, password, name="Admin", last_name="User"):
    """Register admin user via the Better Auth sign-up endpoint."""
    signup_url = f"{url}/api/auth/sign-up/email"
    headers = {"Content-Type": "application/json", "Accept": "*/*"}
    payload = {
        "email": email,
        "password": password,
        "name": name,
        "lastName": last_name,
    }

    print(f"Checking/Registering admin with email: {email}")
    try:
        response = request_with_retry("POST", signup_url, json=payload, headers=headers)
        if response.status_code in [200, 201]:
            print("SUCCESS! Admin account created successfully!")
            return True
        elif response.status_code == 422 and "USER_ALREADY_EXISTS" in response.text:
            print("Admin account already exists, proceeding to login.")
            return True
        else:
            print(f"Registration status: {response.status_code}")
            print(f"DEBUG: Response Body: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"Error during registration: {e}")
        return False


def login(url, email, password):
    """Log in to Dokploy and return the session token cookie."""
    login_url = f"{url}/api/auth/sign-in/email"
    payload = {"email": email, "password": password}

    print(f"Logging in as {email}...")
    try:
        response = request_with_retry("POST", login_url, json=payload)
        if response.status_code == 200:
            print("Login successful!")
            return response.cookies
        else:
            print(f"Login failed: {response.status_code}")
            print(f"DEBUG: Response Body: {response.text}")
            return None
    except Exception as e:
        print(f"Error during login: {e}")
        return None


def setup_ssh_and_server(
    url, cookies, ip_address, organization_id, username="adminuser"
):
    """Generate SSH key, add to authorized_keys, and register server."""
    # 1. Generate SSH Key in Dokploy
    trpc_url_gen = f"{url}/api/trpc/sshKey.generate?batch=1"
    payload_gen = {"0": {"json": {}}}

    import time

    timestamp = int(time.time())
    key_name = f"Key-{timestamp}"
    server_name = f"Server-{timestamp}"

    print(f"Generating SSH key ({key_name}) in Dokploy...")
    try:
        resp_gen = request_with_retry(
            "POST", trpc_url_gen, json=payload_gen, cookies=cookies
        )
        keys = resp_gen.json()[0]["result"]["data"]["json"]
        private_key = keys["privateKey"]
        public_key = keys["publicKey"]

        # 2. Add public key to authorized_keys on VM (both adminuser and root)
        # This is critical for Dokploy to be able to manage the server via passwordless root SSH.
        print(f"Authorizing public key on VM ({ip_address}) for {username} and root...")
        
        target_commands = [
            f"mkdir -p ~/.ssh && echo '{public_key}' >> ~/.ssh/authorized_keys",
            # Enable root login and reload SSH
            f"sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config",
            f"sudo sed -i 's/PermitRootLogin no/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config",
            "sudo systemctl reload ssh",
            # Ensure root has the key as well
            "sudo mkdir -p /root/.ssh",
            f"echo '{public_key}' | sudo tee /root/.ssh/authorized_keys > /dev/null"
        ]
        
        # We use paramiko for the initial authorization if a password is provided,
        # otherwise we fallback to the standard system SSH command.
        if getattr(args, 'ssh_password', None):
            print(f"Using password-based SSH for initial authorization via paramiko...")
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(ip_address, username=username, password=args.ssh_password)
            for cmd in target_commands:
                print(f"  Executing: {cmd}")
                stdin, stdout, stderr = ssh.exec_command(cmd)
                stdout.read() # Wait for completion
            ssh.close()
        else:
            print(f"Using key-based SSH for initial authorization...")
            # Fallback to existing ssh command logic
            full_cmd = " && ".join(target_commands)
            ssh_cmd = [
                "ssh",
                "-i",
                os.path.expanduser(args.ssh_private),
                "-o",
                "StrictHostKeyChecking=no",
                f"{username}@{ip_address}",
                full_cmd
            ]
            subprocess.run(ssh_cmd, check=True)

        # 3. Create SSH Key record in Dokploy
        trpc_url_key = f"{url}/api/trpc/sshKey.create?batch=1"
        payload_key = {
            "0": {
                "json": {
                    "name": key_name,
                    "description": "Automated key for local deployment",
                    "privateKey": private_key,
                    "publicKey": public_key,
                    "organizationId": organization_id,
                }
            }
        }
        print(f"Registering SSH key record ({key_name}) in Dokploy...")
        request_with_retry("POST", trpc_url_key, json=payload_key, cookies=cookies)

        # 4. Fetch the created SSH key ID by name
        trpc_url_all_keys = f"{url}/api/trpc/sshKey.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%7D%7D"
        resp_all = request_with_retry("GET", trpc_url_all_keys, cookies=cookies)
        keys_list = resp_all.json()[0]["result"]["data"]["json"]
        ssh_key_id = next(
            (k["sshKeyId"] for k in keys_list if k["name"] == key_name), None
        )

        if not ssh_key_id:
            print(f"Error: Could not find created SSH key with name {key_name}")
            return None

        print(f"Found SSH Key ID: {ssh_key_id}")

        # 4. Create Server record in Dokploy (using ROOT)
        trpc_url_srv = f"{url}/api/trpc/server.create?batch=1"
        payload_srv = {
            "0": {
                "json": {
                    "name": server_name,
                    "description": "Primary deployment server",
                    "ipAddress": ip_address,
                    "port": 22,
                    "username": "root",
                    "sshKeyId": ssh_key_id,
                    "serverType": "deploy",
                    "organizationId": organization_id,
                }
            }
        }
        print(f"Initializing server ({server_name}) in Dokploy...")
        resp_srv = request_with_retry(
            "POST", trpc_url_srv, json=payload_srv, cookies=cookies
        )
        data_srv = resp_srv.json()

        if isinstance(data_srv, list) and len(data_srv) > 0:
            res_srv = data_srv[0].get("result", {})
            if "error" in res_srv:
                print(f"Server creation error: {res_srv['error']}")
                return None
            server_id = res_srv.get("data", {}).get("json", {}).get("serverId")
        else:
            print(f"DEBUG: Unexpected server creation response: {data_srv}")
            return None

        # 5. Start server setup
        print("Triggering server setup...")
        trpc_url_setup = f"{url}/api/trpc/server.setup?batch=1"
        request_with_retry(
            "POST",
            trpc_url_setup,
            json={"0": {"json": {"serverId": server_id}}},
            cookies=cookies,
            timeout=60,  # Increased timeout for initial setup trigger
        )

        return server_id
    except Exception as e:
        print(f"Error during SSH/Server setup: {e}")
        return None


def delete_all_services(url, cookies, env_id):
    """Delete all services (apps and compose) in the environment using environment.one."""
    trpc_url_one = f"{url}/api/trpc/environment.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22environmentId%22%3A%22{env_id}%22%7D%7D%7D"
    try:
        resp = request_with_retry("GET", trpc_url_one, cookies=cookies)
        env_data = resp.json()[0]["result"]["data"]["json"]

        # Delete Compose Applications
        composes = env_data.get("compose", [])
        for comp in composes:
            print(f"Deleting compose app: {comp['name']}...")
            trpc_url_del = f"{url}/api/trpc/compose.delete?batch=1"
            request_with_retry(
                "POST",
                trpc_url_del,
                json={"0": {"json": {"composeId": comp["composeId"], "deleteVolumes": True}}},
                cookies=cookies,
            )

        # Delete Single Applications
        apps = env_data.get("applications", [])
        for app in apps:
            print(f"Deleting application: {app['name']}...")
            trpc_url_del = f"{url}/api/trpc/application.delete?batch=1"
            request_with_retry(
                "POST",
                trpc_url_del,
                json={"0": {"json": {"applicationId": app["applicationId"]}}},
                cookies=cookies,
            )
    except Exception as e:
        print(f"DEBUG: Warning - could not cleanup services: {e}")
        pass


def get_all_project_ids(url, cookies):
    """Find all existing projects and return their IDs and a list of all Env IDs."""
    trpc_url = f"{url}/api/trpc/project.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%7D%7D%7D"
    matches = []
    try:
        response = requests.get(trpc_url, cookies=cookies, timeout=30)
        data = response.json()
        projects = data[0]["result"]["data"]["json"]
        for p in projects:
            projectId = p["projectId"]
            env_ids = get_all_environment_ids(url, cookies, projectId)
            matches.append((projectId, env_ids, p["name"]))
    except Exception as e:
        print(f"DEBUG: Error listing all projects: {e}")
    return matches


def get_all_environment_ids(url, cookies, project_id):
    """Get all environment IDs for the project."""
    trpc_url = f"{url}/api/trpc/project.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22projectId%22%3A%22{project_id}%22%7D%7D%7D"
    ids = []
    try:
        response = requests.get(trpc_url, cookies=cookies, timeout=30)
        data = response.json()
        environments = data[0]["result"]["data"]["json"]["environments"]
        for env in environments:
            ids.append(env["environmentId"])
    except Exception:
        pass
    return ids


def get_environment_id(url, cookies, project_id):
    """Get the production environment ID for the project."""
    trpc_url = f"{url}/api/trpc/project.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22projectId%22%3A%22{project_id}%22%7D%7D%7D"
    try:
        response = requests.get(trpc_url, cookies=cookies, timeout=30)
        data = response.json()
        environments = data[0]["result"]["data"]["json"]["environments"]
        for env in environments:
            if env["name"] == "production":
                return env["environmentId"]
    except Exception:
        pass
    return None


def delete_project(url, cookies, project_id):
    """Delete a project and all its resources."""
    print(f"Deleting project {project_id}...")
    trpc_url_del = f"{url}/api/trpc/project.delete?batch=1"
    payload = {"0": {"json": {"projectId": project_id}}}
    
    # Retry logic for project deletion
    max_retries = 3
    for attempt in range(max_retries):
        try:
            resp = requests.post(trpc_url_del, json=payload, cookies=cookies, timeout=60)
            print(f"DEBUG: Delete project response status: {resp.status_code}")
            
            if resp.status_code == 200:
                try:
                    data = resp.json()
                    # Check for errors in TRPC response
                    if data and isinstance(data, list) and len(data) > 0:
                        result = data[0].get("result", {})
                        if "error" in result or "error" in data[0]:
                            error_msg = result.get("error") or data[0].get("error")
                            print(f"DEBUG: TRPC error in response: {error_msg}")
                            if attempt < max_retries - 1:
                                print(f"Retrying delete... (attempt {attempt + 2}/{max_retries})")
                                time.sleep(2)
                                continue
                            return False
                    print(f"Project {project_id} deleted successfully.")
                    return True
                except Exception as parse_err:
                    print(f"DEBUG: Could not parse response: {parse_err}")
                    # If we can't parse but got 200, assume success
                    print(f"Project {project_id} deleted (assumed success).")
                    return True
            else:
                print(f"Failed to delete project: {resp.status_code} - {resp.text[:200]}")
                if attempt < max_retries - 1:
                    print(f"Retrying delete... (attempt {attempt + 2}/{max_retries})")
                    time.sleep(2)
                    continue
                return False
        except Exception as e:
            print(f"Error deleting project: {e}")
            if attempt < max_retries - 1:
                print(f"Retrying delete... (attempt {attempt + 2}/{max_retries})")
                time.sleep(2)
                continue
            return False
    return False


def force_cleanup_ports(ip_address, username, key_path, ports):
    """Forcefully remove docker containers binding specific ports via SSH."""
    print(f"Force-cleaning ports {ports} on {ip_address}...")

    # Construct command to find and kill containers mapping these ports
    # We loop through each port to be safe
    commands = []

    # Check for docker ps filtering for published ports
    for port in ports:
        # Docker formatting: 0.0.0.0:9000->... or :::9000->...
        # We look for containers publishing this port
        cmd = f"docker ps -a --format '{{{{.ID}}}} {{{{.Ports}}}}' | grep ':{port}->' | awk '{{print $1}}' | xargs -r docker rm -f"
        commands.append(cmd)

    full_command = " && ".join(commands)

    ssh_cmd = [
        "ssh",
        "-i",
        key_path,
        "-o",
        "StrictHostKeyChecking=no",
        f"{username}@{ip_address}",
        full_command,
    ]

    try:
        subprocess.run(
            ssh_cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        print("Port cleanup commands executed successfully.")
        return True
    except subprocess.CalledProcessError as e:
        print(f"Warning: Port cleanup failed (may be harmless if empty): {e}")
        return False


def create_project(url, cookies, organization_id, name="Agentic Demos"):
    """Create a new project in Dokploy."""
    trpc_url = f"{url}/api/trpc/project.create?batch=1"
    payload = {
        "0": {
            "json": {
                "name": name,
                "description": "Automated Project",
                "projectId": "",
                "organizationId": organization_id,
            }
        }
    }
    print(f"Creating project: {name}...")
    try:
        response = requests.post(trpc_url, json=payload, cookies=cookies, timeout=30)
        data = response.json()
        print(f"DEBUG: Create project response structure: {list(data[0].keys())}")
        result = data[0].get("result", {})
        if "error" in result:
             print(f"Error creating project: {result['error']}")
             return None, None
             
        project_data = result["data"]["json"]["project"]
        env_data = result["data"]["json"]["environment"]
        print(f"DEBUG: Created Project ID: {project_data.get('projectId')}, Env ID: {env_data.get('environmentId')}")
        return project_data["projectId"], env_data["environmentId"]
    except Exception as e:
        print(f"Exception creating project: {e}")
        return None, None


def create_compose(url, cookies, project_id, environment_id, name, server_id):
    """Create a Compose application."""
    import re
    trpc_url = f"{url}/api/trpc/compose.create?batch=1"
    # Dokploy validates appName against ^[a-zA-Z0-9._-]+$, so strip EVERY other
    # character (not just spaces). A plain space->hyphen left parentheses/other
    # punctuation in, which 400'd names like "Identity Provider (IdP)".
    app_name = re.sub(r"[^a-zA-Z0-9._-]+", "-", name.lower()).strip("-") or "app"
    payload = {
        "0": {
            "json": {
                "name": name,
                "description": f"Compose deployment of {name}",
                "environmentId": environment_id,
                "serverId": server_id,
                "composeType": "docker-compose",
                "appName": app_name,
            }
        }
    }
    print(f"Creating compose application: {name}...")
    try:
        resp = request_with_retry("POST", trpc_url, json=payload, cookies=cookies)
        data = resp.json()
        return data[0]["result"]["data"]["json"]["composeId"]
    except Exception as e:
        print(f"Error creating compose: {e}")
        return None


def get_all_compose_ids(url, cookies, environment_id):
    """Fetch all compose apps for a given environment."""
    trpc_url = f"{url}/api/trpc/compose.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22environmentId%22%3A%22{environment_id}%22%7D%7D%7D"
    try:
        resp = requests.get(trpc_url, cookies=cookies, timeout=10).json()
        apps = resp[0]["result"]["data"]["json"]
        return [{"name": a["name"], "composeId": a["composeId"]} for a in apps]
    except Exception as e:
        print(f"Error fetching compose apps: {e}")
        return []


def get_compose_app_name(url, cookies, compose_id):
    """Fetch the full appName (with suffix) for a compose service."""
    trpc_url = f"{url}/api/trpc/compose.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22composeId%22%3A%22{compose_id}%22%7D%7D%7D"
    try:
        resp = requests.get(trpc_url, cookies=cookies, timeout=10).json()
        return resp[0]["result"]["data"]["json"]["appName"]
    except Exception as e:
        print(f"Error fetching app name: {e}")
        return None


def update_compose_git(
    url, cookies, compose_id, github_url, env_vars=None, ssh_key_id=None, branch="main", compose_command=None, compose_path="./docker-compose.yml"
):
    """Connect GitHub repo to Compose app."""
    trpc_url = f"{url}/api/trpc/compose.update?batch=1"

    json_payload = {
        "composeId": compose_id,
        "customGitUrl": github_url,
        "customGitBranch": branch,
        "sourceType": "git",
        "composePath": compose_path,
        "composeStatus": "idle",
        "watchPaths": [],
        "enableSubmodules": False,
        "randomize": True,
    }

    if compose_command:
        json_payload["command"] = compose_command
        print(f"Setting compose command: {compose_command}")

    if env_vars:
        json_payload["env"] = env_vars
        json_payload["envVars"] = env_vars
    
    if ssh_key_id:
        json_payload["customGitSSHKeyId"] = ssh_key_id

    meta_payload = {"values": {}}
    if ssh_key_id is None:
        meta_payload["values"]["customGitSSHKeyId"] = ["undefined"]

    payload = {
        "0": {
            "json": json_payload,
            "meta": meta_payload,
        }
    }
    print(f"Connecting GitHub (sourceType: git): {github_url} (branch: {branch})...")
    try:
        request_with_retry("POST", trpc_url, json=payload, cookies=cookies, timeout=30)
    except Exception as e:
        print(f"Error updating compose git: {e}")


def create_domain(url, cookies, compose_id, host, port, service_name):
    """Create a domain for a Compose service."""
    trpc_url = f"{url}/api/trpc/domain.create?batch=1"
    payload = {
        "0": {
            "json": {
                "host": host,
                "path": "/",
                "port": port,
                "https": True,
                "composeId": compose_id,
                "serviceName": service_name,
                "certificateType": "letsencrypt",
                "domainType": "compose",
            }
        }
    }
    print(f"Setting up domain: {host} (service: {service_name}, port: {port})...")
    try:
        request_with_retry("POST", trpc_url, json=payload, cookies=cookies, timeout=30)
    except Exception as e:
        print(f"Error creating domain: {e}")


def update_compose_file(url, cookies, compose_id, compose_content, source_type=None):
    """Update the docker-compose.yml content for a Compose application.

    Raises on a non-2xx (or tRPC-error) response. A silently-dropped push
    leaves the app on the wrong (repo) compose, so this is a fatal error —
    same as project/server setup failures elsewhere in this file — not a
    print-and-continue warning.
    """
    trpc_url = f"{url}/api/trpc/compose.update?batch=1"
    json_data = {
        "composeId": compose_id,
    }
    if compose_content is not None:
        json_data["composeFile"] = compose_content
    if source_type:
        json_data["sourceType"] = source_type

    payload = {
        "0": {
            "json": json_data
        }
    }
    print(f"Updating compose file for {compose_id} (sourceType={source_type})...")
    resp = request_with_retry("POST", trpc_url, json=payload, cookies=cookies, timeout=30)
    if not (200 <= resp.status_code < 300):
        raise RuntimeError(
            f"Failed to push compose file for {compose_id}: "
            f"HTTP {resp.status_code} - {resp.text[:300]}"
        )
    try:
        data = resp.json()
    except ValueError:
        data = None
    if isinstance(data, list) and data and isinstance(data[0], dict) and "error" in data[0]:
        raise RuntimeError(
            f"tRPC error pushing compose file for {compose_id}: {data[0]['error']}"
        )
    return resp


def update_compose_env(url, cookies, compose_id, env_content):
    """Update environment variables for a Compose application."""
    trpc_url = f"{url}/api/trpc/compose.update?batch=1"
    payload = {
        "0": {
            "json": {
                "composeId": compose_id,
                "envVars": env_content,
                "env": env_content
            }
        }
    }
    print(f"Updating environment variables for {compose_id}...")
    try:
        request_with_retry("POST", trpc_url, json=payload, cookies=cookies, timeout=30)
    except Exception as e:
        print(f"Error updating environment variables: {e}")


def detect_env_file(app_name):
    # 1. Try exact slugs
    slugs = [
        app_name.lower().replace(" ", "-"),
        app_name.lower().replace(" ", "_"),
        app_name.lower().replace("-", "_"),
        app_name.lower(),
    ]

    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))
    search_dirs = [
        ".",
        "envs",
        os.path.join(script_dir, "envs"),
        "automation",
        os.path.join("automation", "envs"),
    ]

    for directory in search_dirs:
        for slug in slugs:
            # Check for .env_<slug>
            path = os.path.join(directory, f".env_{slug}")
            if os.path.exists(path):
                return path

    # 2. Try keyword matching if no exact slug matches
    # For "CP Agentic MCP Playground", keywords might be ["agentic", "mcp"]
    keywords = [w.lower() for w in app_name.split() if len(w) > 3]
    for directory in search_dirs:
        try:
            # Sort for a deterministic pick regardless of listdir order.
            files = sorted(os.listdir(directory))
        except Exception:
            continue
        for f in files:
            # Only match rendered env files — never a *.example template, whose
            # placeholder creds would otherwise land on a public app.
            if not f.startswith(".env_") or f.endswith(".example"):
                continue
            # Check if any keyword is in the filename
            for kw in keywords:
                if kw in f.lower():
                    return os.path.join(directory, f)

    return None


def resolve_env_file(cfg):
    """Resolve an app's rendered .env path deterministically.

    An explicit "envFile" key in the app config (e.g. "ai-guardrails-demo")
    maps straight to automation/envs/.env_<envFile> — the rendered file that
    bootstrap_secrets.py produces from .env_<envFile>.example. This avoids the
    fuzzy slug/keyword guessing of detect_env_file(), which is only used as a
    fallback when no envFile is declared.
    """
    explicit = cfg.get("envFile")
    if explicit:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        candidates = [
            os.path.join(script_dir, "envs", f".env_{explicit}"),
            os.path.join("automation", "envs", f".env_{explicit}"),
            os.path.join("envs", f".env_{explicit}"),
            f".env_{explicit}",
        ]
        for path in candidates:
            if os.path.exists(path):
                return path
        print(
            f"Warning: envFile '{explicit}' declared for {cfg['name']} but "
            f".env_{explicit} was not found (looked in {candidates}); "
            f"falling back to name detection."
        )
    return detect_env_file(cfg["name"])


def deploy_compose(url, cookies, compose_id):
    """Trigger deployment for Compose app."""
    trpc_url = f"{url}/api/trpc/compose.deploy?batch=1"
    payload = {"0": {"json": {"composeId": compose_id, "title": "Automated Setup"}}}
    print(f"Triggering deployment for compose {compose_id}...")
    try:
        request_with_retry("POST", trpc_url, json=payload, cookies=cookies, timeout=60)
    except Exception as e:
        print(f"Error deploying compose: {e}")


def harden_server(ip_address, ssh_user, ssh_private_path=None, ssh_password=None):
    """
    Post-deploy security hardening:
    - UFW: allow only 22/80/443; deploy DOCKER-USER chain to block direct port access
    - fail2ban: configure SSH jail (ban after 5 failures for 1hr)
    - sshd: ensure PubkeyAuthentication is enabled (required for Dokploy's
      internal deployment SSH); password auth kept on for interactive use.
    """
    print("\n" + "=" * 60)
    print("HARDENING SERVER — applying firewall and SSH security...")
    print("=" * 60)

    # WAN interface the DOCKER-USER chain guards. Auto-detected by install.sh
    # (default-route iface); overridable via WAN_IFACE for laptop/remote runs.
    wan_iface = os.environ.get("WAN_IFACE", "eth0")

    after_rules = f"""#
# rules.input-after
#
*filter
:ufw-after-input - [0:0]
:ufw-after-output - [0:0]
:ufw-after-forward - [0:0]

-A ufw-after-input -p udp --dport 137 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 138 -j ufw-skip-to-policy-input
-A ufw-after-input -p tcp --dport 139 -j ufw-skip-to-policy-input
-A ufw-after-input -p tcp --dport 445 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 67 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 68 -j ufw-skip-to-policy-input
-A ufw-after-input -m addrtype --dst-type BROADCAST -j ufw-skip-to-policy-input

# DOCKER-USER: block all direct external port access; force traffic through Traefik on 80/443.
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i {wan_iface} -p tcp --dport 80 -j RETURN
-A DOCKER-USER -i {wan_iface} -p tcp --dport 443 -j RETURN
-A DOCKER-USER -i {wan_iface} -j DROP

COMMIT
"""

    fail2ban_jail = """[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
"""

    # Build a sequence of hardening commands
    cmds = [
        # UFW: reset to known state, allow only 22/80/443
        "ufw --force reset",
        "ufw default deny incoming",
        "ufw default allow outgoing",
        "ufw allow 22/tcp",
        "ufw allow 80/tcp",
        "ufw allow 443/tcp",
        # Write DOCKER-USER after.rules
        f"cat > /etc/ufw/after.rules << 'AFTEREOF'\n{after_rules}\nAFTEREOF",
        "ufw --force enable",
        # Write fail2ban jail
        f"cat > /etc/fail2ban/jail.local << 'JAILEOF'\n{fail2ban_jail}\nJAILEOF",
        "systemctl enable fail2ban",
        "systemctl restart fail2ban",
        # Keep pubkey auth ON — Dokploy uses its internal key to SSH into
        # the registered server for deployments. Password auth stays on
        # for interactive admin login.
        "sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config",
        "grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config",
        "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config",
        "systemctl reload ssh || systemctl reload sshd",
    ]

    try:
        if ssh_password:
            import paramiko
            for cmd in cmds:
                client = paramiko.SSHClient()
                client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                client.connect(ip_address, username=ssh_user, password=ssh_password, timeout=15)
                stdin, stdout, stderr = client.exec_command("sudo bash -c " + shlex.quote(cmd), timeout=30)
                stdout.read()
                client.close()
        else:
            for cmd in cmds:
                ssh_cmd = [
                    "ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path,
                    f"{ssh_user}@{ip_address}", "sudo bash -c " + shlex.quote(cmd)
                ]
                subprocess.run(ssh_cmd, check=False)

        print("Server hardening complete.")
        print("  UFW: only ports 22/80/443 open externally")
        print("  DOCKER-USER chain: all direct Docker port access blocked")
        print("  fail2ban: SSH brute-force protection active")
        print("  sshd: PubkeyAuthentication enabled (for Dokploy); password auth also on")
    except Exception as e:
        print(f"Warning: Hardening step encountered an error: {e}")
        print("Please run hardening manually — see docs/incident-report-2026-03-31.md")


def manual_git_clone_and_inject(ip_address, full_app_name, repo_url, ssh_private_path, ssh_user="adminuser"):
    """Manually clone the repo and inject customizations via SSH."""
    print(f"Manually cloning {repo_url} for {full_app_name}...")
    code_dir = f"/etc/dokploy/compose/{full_app_name}/code"

    commands = [
        f"sudo rm -rf {code_dir}",
        f"sudo mkdir -p {code_dir}",
        f"sudo git clone {repo_url} {code_dir}",
        f"sudo chown -R {ssh_user}:{ssh_user} {code_dir}"
    ]

    try:
        for cmd in commands:
            ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path, f"{ssh_user}@{ip_address}", cmd]
            subprocess.run(ssh_cmd, check=True)

        # Now inject
        inject_dev_hub_customizations(ip_address, full_app_name, ssh_private_path, ssh_user=ssh_user, wait=False)
        return True
    except Exception as e:
        print(f"Error during manual clone and inject: {e}")
        return False


def inject_dev_hub_customizations(ip_address, full_app_name, ssh_private_path, ssh_user="adminuser", wait=True):
    """Inject custom UI files into the Dev-Hub deployment."""
    print(f"Injecting Dev-Hub UI customizations for {full_app_name}...")

    directory = f"/etc/dokploy/compose/{full_app_name}/code/frontend/src/pages"

    if wait:
        print(f"Waiting for target directory to be created: {directory}")
        max_retries = 12
        for i in range(max_retries):
            check_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path, f"{ssh_user}@{ip_address}", f"test -d {directory} && echo 'exists'"]
            try:
                result = subprocess.run(check_cmd, capture_output=True, text=True)
                if "exists" in result.stdout:
                    print("Directory found!")
                    break
            except:
                pass
            print(f"Waiting... ({i+1}/{max_retries})")
            time.sleep(5)
        else:
            print("Timeout waiting for directory creation. Skipping injection.")
            return

    local_files = {
        "automation/LandingPage_new.tsx": f"/etc/dokploy/compose/{full_app_name}/code/frontend/src/pages/LandingPage.tsx",
        "automation/AppCard_new.tsx": f"/etc/dokploy/compose/{full_app_name}/code/frontend/src/components/AppCard.tsx",
        "automation/index_update.css": f"/tmp/index_update.css"
    }

    try:
        for local, remote in local_files.items():
            if os.path.exists(local):
                print(f"Uploading {local} to {remote}...")
                scp_cmd = ["scp", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path, local, f"{ssh_user}@{ip_address}:{remote}"]
                subprocess.run(scp_cmd, check=True)
        # Append CSS
        append_css_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path, f"{ssh_user}@{ip_address}",
            f"sudo bash -c 'cat /tmp/index_update.css >> /etc/dokploy/compose/{full_app_name}/code/frontend/src/index.css'"
        ]
        subprocess.run(append_css_cmd, check=True)
        print("UI customizations injected successfully.")
    except Exception as e:
        print(f"Warning: Failed to inject UI customizations: {e}")


def wait_for_server_ready(url, cookies, server_id, timeout=300):
    """Wait for server status to become active."""
    print(f"Waiting for server {server_id} to be active...")
    start_time = time.time()
    trpc_url = f"{url}/api/trpc/server.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22serverId%22%3A%22{server_id}%22%7D%7D%7D"
    while time.time() - start_time < timeout:
        try:
            resp = requests.get(trpc_url, cookies=cookies, timeout=10).json()
            status = resp[0]["result"]["data"]["json"]["serverStatus"]
            if status == "active":
                print("Server is active!")
                return True
            print(f"Server status: {status} (waiting...)")
        except Exception as e:
            print(f"Error checking server status: {e}")
        time.sleep(10)
    return False


def sanitize_compose_file(content, app_name, app_path=None):
    """Refined sanitization for Dokploy compatibility."""
    import re
    
    # 0. Expand Tildes and standardize relative paths BEFORE volume regex
    content = content.replace("~/.flowise", "./flowise_data")
    content = content.replace("~/.n8n", "./n8n_data")
    content = content.replace("~/.docker", "./docker_config")
    content = content.replace("~/", "./")

    # 1. Inject env_file: [".env"] into every service
    lines = content.splitlines()
    new_lines = []
    in_services = False
    
    for line in lines:
        stripped = line.strip()
        if stripped == "services:":
            in_services = True
            new_lines.append(line)
            continue

        # A new TOP-LEVEL section (column 0, e.g. "volumes:", "networks:")
        # ends the services block. Without this reset, in_services stayed True
        # and env_file got injected under every volume/network NAME (2-space
        # indented, ends with ":"), producing an invalid compose that Dokploy
        # rejects: 'volumes.<name> additional properties "env_file" not allowed'.
        if line and not line[0].isspace() and stripped.endswith(":") and stripped != "services:":
            in_services = False
            new_lines.append(line)
            continue

        if in_services and line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
            new_lines.append(line)
            # Add env_file right after service definition
            indent = "    "
            new_lines.append(f"{indent}env_file:")
            new_lines.append(f"{indent}  - .env")
            continue

        new_lines.append(line)
    
    content = "\n".join(new_lines)

    # 2. Fix OLLAMA_HOST warnings (escaped $$ for Dokploy inner parser)
    content = content.replace("@ $OLLAMA_HOST", "@ $${OLLAMA_HOST}")
    content = content.replace("@ $$OLLAMA_HOST", "@ $${OLLAMA_HOST}")
    content = content.replace('OLLAMA_HOST="$OLLAMA_HOST"', 'OLLAMA_HOST="$${OLLAMA_HOST}"')
    
    # 3. Handle Volumes and Build Contexts - Convert to Absolute
    if app_path:
        # Standardize relative mounts/contexts to absolute paths using regex
        # This targets anything starting with ./ after a space, hyphen, or colon
        content = re.sub(r'((?:^|\s+)-\s+("?))\./', rf'\1{app_path}/', content, flags=re.MULTILINE)
        content = re.sub(r'(:)\./', f':{app_path}/', content)
        content = re.sub(r'(context:\s+)\./', f'\\1{app_path}/', content)
        content = re.sub(r'(env_file:\s+)\./', f'\\1{app_path}/', content)

    if "AI Guardrails" in app_name:
        # Ollama joins dokploy-network (see cp-agentic-mcp-playground compose),
        # so AI Guardrails reaches it by name at http://ollama-cpu:11434 — no host-IP
        # hairpin, no host-published port. The old IP rewrite is intentionally
        # gone; .env_ai-guardrails-demo already sets OLLAMA_API_URL=http://ollama-cpu:11434.
        lines = content.splitlines()
        new_lines = []
        for line in lines:
            if ".:/app" in line:
                continue
            new_lines.append(line)
        content = "\n".join(new_lines)

    return content

def hard_inject_env_vars(content, env_file_path):
    """Replace ${VAR} and ${VAR:-default} with actual values or defaults.

    Preserves $${VAR} docker-compose escape sequences (runtime variables)
    and bare $VAR references inside shell command blocks.
    Only replaces ${VAR} (braced form), which is the docker-compose
    interpolation syntax for build-time substitution.
    """
    import re
    if not env_file_path or not os.path.exists(env_file_path):
        return content

    env_vars = {}
    try:
        with open(env_file_path, "r") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip()
    except Exception as e:
        print(f"Warning: Could not read env file for hard injection: {e}")
        return content

    # 0. Protect $${...} and $$VAR escape sequences with placeholders.
    #    These are docker-compose escapes meant for runtime resolution
    #    inside containers and must NOT be replaced at build time.
    _protected = {}
    _counter = [0]

    def _protect(match):
        key = f"__DBLDOLLAR_{_counter[0]}__"
        _protected[key] = match.group(0)
        _counter[0] += 1
        return key

    content = re.sub(r'\$\$\{[^}]+\}', _protect, content)
    content = re.sub(r'\$\$[A-Za-z_][A-Za-z0-9_]*', _protect, content)

    # 1. First pass: Handle ${VAR:-default}
    def resolve_default(match):
        var_name = match.group(1)
        default_val = match.group(2)
        return env_vars.get(var_name, default_val)

    content = re.sub(r'\$\{([^}:-]+):-([^}]*)\}', resolve_default, content)

    # 2. Second pass: Handle ${VAR} (braced form only)
    #    We intentionally do NOT replace bare $VAR because those are
    #    shell variable references inside command: blocks.
    for k in sorted(env_vars.keys(), key=len, reverse=True):
        v = env_vars[k]
        content = content.replace(f"${{{k}}}", v)

    # 3. Third pass: Clean up remaining unresolved ${VAR} patterns
    def cleanup_unresolved(match):
        print(f"DEBUG: Resolving empty variable {match.group(0)}")
        return ""

    content = re.sub(r'\$\{[^}]+\}', cleanup_unresolved, content)

    # 4. Restore protected double-dollar escape sequences
    for key, original in _protected.items():
        content = content.replace(key, original)

    return content

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Automate Dokploy setup with Compose and Domains"
    )
    parser.add_argument("--url", required=True, help="Dokploy URL")
    parser.add_argument("--email", required=True, help="Admin email")
    parser.add_argument("--password", required=True, help="Admin password")
    parser.add_argument("--domain", default=os.environ.get("ROOT_DOMAIN"), help="Root domain for apps (or set ROOT_DOMAIN env). Required — no hardcoded default.")
    parser.add_argument("--ip", help="VM Public IP (default: derived from URL)")
    parser.add_argument(
        "--config", default="dokploy_config.json", help="Path to apps config JSON"
    )
    parser.add_argument(
        "--ssh-private",
        default="~/.ssh/id_rsa",
        help="Path to private SSH key (default: ~/.ssh/id_rsa)",
    )
    parser.add_argument(
        "--ssh-public",
        default="~/.ssh/id_rsa.pub",
        help="Path to public SSH key (default: ~/.ssh/id_rsa.pub)",
    )
    parser.add_argument(
        "--project",
        default="Agentic Demos",
        help="Project name (default: Agentic Demos)",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete existing project before starting (Fresh Rebuild)",
    )
    parser.add_argument("--app", help="Filter: Only process this specific app name")
    parser.add_argument("--ssh-user", default="adminuser", help="SSH Username (default: adminuser)")
    parser.add_argument("--ssh-password", help="SSH Password (optional, for initial setup)")
    parser.add_argument("--skip-harden", action="store_true", help="Skip the built-in harden_server step (install.sh hardens the host itself).")
    parser.add_argument("--local-server", action="store_true", help="Deploy on the Dokploy host itself (serverId=null); skip remote server registration/SSH setup.")

    args = parser.parse_args()
    url = args.url.rstrip("/")
    ip_address = args.ip or url.split("//")[-1].split(":")[0]
    root_domain = args.domain
    if not root_domain:
        print("Error: a root domain is required. Pass --domain <domain> or set ROOT_DOMAIN.")
        sys.exit(1)

    # Update environment with domain
    os.environ["DOMAIN"] = root_domain

    def replace_domain(content):
        if content is None: return None
        if isinstance(content, str):
            return content.replace("{{DOMAIN}}", root_domain)
        if isinstance(content, list):
            return [replace_domain(i) for i in content]
        if isinstance(content, dict):
            return {k: replace_domain(v) for k, v in content.items()}
        return content

    # Helper to find local env files
    def find_env_file(app_name):
        slugs = [
            app_name.lower().replace(" ", "-"),
            app_name.lower().replace(" ", "_"),
            app_name.lower(),
            "agentic" if "agentic" in app_name.lower() else None,
            "dev-hub" if "dev hub" in app_name.lower() else None,
        ]
        slugs = [s for s in slugs if s]
        search_dirs = [".", "automation", "automation/envs", "envs"]
        for directory in search_dirs:
            for slug in slugs:
                path = os.path.join(directory, f".env_{slug}")
                if os.path.exists(path):
                    return path
        return None

    # Helper to copy env file to remote
    def copy_env_file_to_remote(local_path, remote_ip, app_slug):
        try:
            target_path = f"/etc/dokploy/compose/{app_slug}/code/.env"
            print(f"Ensuring {target_path} on {remote_ip}...")
            
            # Check if we're running locally on the target VM
            is_local = False
            try:
                import socket
                hostname = os.uname()[1] if hasattr(os, 'uname') else socket.gethostname()
                # Simple check: if ip is reachable on loopback or matches hostname/etc
                # But safer to just check if the directory exists locally
                if os.path.exists(f"/etc/dokploy/compose/{app_slug}"):
                    is_local = True
            except:
                pass

            if is_local:
                print(f"Detected local execution. Copying {local_path} to {target_path}...")
                subprocess.run(["sudo", "mkdir", "-p", os.path.dirname(target_path)], check=True)
                subprocess.run(["sudo", "cp", local_path, target_path], check=True)
                subprocess.run(["sudo", "chown", "root:root", target_path], check=True)
                subprocess.run(["sudo", "chmod", "644", target_path], check=True)
            else:
                # Ensure remote directory exists
                remote_dir = os.path.dirname(target_path)
                ssh_mkdir = [
                    "ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path,
                    f"{args.ssh_user}@{remote_ip}", f"sudo mkdir -p {remote_dir} && sudo chown {args.ssh_user}:{args.ssh_user} {remote_dir}"
                ]
                subprocess.run(ssh_mkdir, check=True)

                scp_cmd = [
                    "scp", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path,
                    local_path, f"{args.ssh_user}@{remote_ip}:{target_path}"
                ]
                subprocess.run(scp_cmd, check=True)
                # Fix permissions
                ssh_cmd = [
                    "ssh", "-o", "StrictHostKeyChecking=no", "-i", ssh_private_path,
                    f"{args.ssh_user}@{remote_ip}",
                    f"sudo chown root:root {target_path} && sudo chmod 644 {target_path}"
                ]
                subprocess.run(ssh_cmd, check=True)
            print("Env file copied successfully.")
        except Exception as e:
            print(f"Error copying env file: {e}")
    import os

    ssh_private_path = os.path.expanduser(args.ssh_private)
    ssh_public_path = os.path.expanduser(args.ssh_public)
    ssh_user = args.ssh_user

    if not args.ssh_password and (not os.path.exists(ssh_private_path) or not os.path.exists(ssh_public_path)):
        print(f"Error: SSH keys not found at {ssh_private_path} or {ssh_public_path}")
        print("Provide either valid SSH key files (--ssh-private / --ssh-public) or use --ssh-password.")
        sys.exit(1)

    # Load Config
    try:
        with open(args.config, "r") as f:
            app_configs = json.load(f)
    except Exception as e:
        print(f"Error loading config file {args.config}: {e}")
        sys.exit(1)

    if wait_for_dokploy(url):
        register_admin(url, args.email, args.password)
        cookies = login(url, args.email, args.password)
        if not cookies:
            sys.exit(1)

        # Organization
        trpc_url_org_all = f"{url}/api/trpc/organization.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%7D%7D"
        org_data = requests.get(trpc_url_org_all, cookies=cookies).json()
        try:
            org_id = org_data[0]["result"]["data"]["json"][0]["id"]
            print(f"Using Organization ID: {org_id}")
        except (IndexError, KeyError, TypeError):
            print(f"Error fetching Organization ID. Response: {org_data}")
            sys.exit(1)

        # Server Management
        server_id = None
        needs_setup = False

        if args.local_server:
            # Deploy on the Dokploy host itself: serverId stays null, so Dokploy
            # runs compose via its mounted docker socket. This avoids remote SSH,
            # which Dokploy's overlay-networked container cannot do against the
            # host's 127.0.0.1. This is the path install.sh uses on the box.
            print("Local-server mode: deploying on the Dokploy host (serverId=null).")
        else:
            trpc_url_srv_all = f"{url}/api/trpc/server.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%7D%7D"
            srv_data = requests.get(trpc_url_srv_all, cookies=cookies).json()
            servers = srv_data[0].get("result", {}).get("data", {}).get("json", [])

            # In clean mode, delete existing servers and start fresh to ensure SSH keys are valid
            if args.clean and servers:
                print("Clean mode: Deleting existing servers to reset SSH keys...")
                for srv in servers:
                    sid = srv.get("serverId")
                    if sid:
                        print(f"  Deleting server: {srv.get('name', sid)}...")
                        try:
                            trpc_url_srv_del = f"{url}/api/trpc/server.remove?batch=1"
                            del_payload = {"0": {"json": {"serverId": sid}}}
                            resp = requests.post(trpc_url_srv_del, json=del_payload, cookies=cookies, timeout=30)
                            if resp.status_code == 200:
                                print(f"    Server {sid} deleted.")
                            else:
                                print(f"    Warning: Server deletion returned {resp.status_code}")
                        except Exception as e:
                            print(f"    Warning: Could not delete server {sid}: {e}")
                servers = []  # Force re-creation
                time.sleep(2)

            if servers:
                existing_srv = servers[0]
                # Verify if the existing server is actually setup with root (to avoid permission errors)
                if existing_srv.get("username") == "root" and existing_srv.get("sshKeyId"):
                    server_id = existing_srv["serverId"]
                    print(
                        f"Using existing root server: {existing_srv['name']} ({server_id})"
                    )
                else:
                    print(
                        f"Existing server {existing_srv['name']} is not root or has no key. Forcing new setup..."
                    )
                    needs_setup = True
                    server_id = setup_ssh_and_server(url, cookies, ip_address, org_id, username=ssh_user)
            else:
                needs_setup = True
                server_id = setup_ssh_and_server(url, cookies, ip_address, org_id, username=ssh_user)

            if not server_id:
                print("Critical: No server available or server setup failed.")
                sys.exit(1)

            if needs_setup:
                wait_for_server_ready(url, cookies, server_id)

            print(f"Final Server ID for deployment: {server_id}")

        # Git SSH Key Registration
        git_ssh_key_id = None
        try:
            with open(ssh_private_path, "r") as f:
                user_private_key = f.read()
            with open(ssh_public_path, "r") as f:
                user_public_key = f.read()

            print("Registering User SSH Key in Dokploy for Git...")
            trpc_url_key = f"{url}/api/trpc/sshKey.create?batch=1"
            payload_git_key = {
                "0": {
                    "json": {
                        "name": "UserGitHubKey",
                        "description": "User's local SSH key for Git",
                        "privateKey": user_private_key,
                        "publicKey": user_public_key,
                        "organizationId": org_id,
                    }
                }
            }
            requests.post(
                trpc_url_key, json=payload_git_key, cookies=cookies, timeout=30
            )

            # Fetch the ID
            trpc_url_all_keys = f"{url}/api/trpc/sshKey.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%7D%7D"
            resp_all = requests.get(trpc_url_all_keys, cookies=cookies, timeout=30)
            keys_list = resp_all.json()[0]["result"]["data"]["json"]
            git_ssh_key_id = next(
                (k["sshKeyId"] for k in keys_list if k["name"] == "UserGitHubKey"), None
            )
            print(f"Git SSH Key ID: {git_ssh_key_id}")
        except Exception as e:
            print(f"Warning: Could not register user SSH key for Git: {e}")

        all_projects = get_all_project_ids(url, cookies)

        project_id = None
        env_id = None

        if args.clean and all_projects:
            print(
                f"Clean mode: Found {len(all_projects)} total projects. Deleting ALL to ensure fresh state..."
            )
            for pid, eids, pname in all_projects:
                print(f"Purging project: {pname} ({pid})...")
                for eid in eids:
                    print(f"  Cleaning environment: {eid}")
                    delete_all_services(url, cookies, eid)
                    time.sleep(1)  # Small delay between environment cleanups
                
                # Delete the project with verification
                success = delete_project(url, cookies, pid)
                if not success:
                    print(f"WARNING: Project {pname} may not have been deleted. Attempting force cleanup...")
                    # Try one more time after a delay
                    time.sleep(3)
                    delete_project(url, cookies, pid)
                
                time.sleep(2)  # Wait between project deletions

            # Verify all projects are deleted
            print("Verifying project deletion...")
            time.sleep(3)
            remaining = get_all_project_ids(url, cookies)
            if remaining:
                print(f"WARNING: {len(remaining)} projects still exist after cleanup: {[p[2] for p in remaining]}")
                print("Attempting second pass deletion...")
                for pid, eids, pname in remaining:
                    print(f"Force deleting: {pname}")
                    delete_project(url, cookies, pid)
                    time.sleep(2)

            # Aggressive cleanup via SSH
            print("Performing NUCLEAR Docker cleanup via SSH for known ports...")
            ports_to_clean = [
                3000, 80, 443,      # Dokploy/Traefik
                5678,               # n8n
                3020,               # Flowise
                7860,               # Langflow
                9000, 6380, 8082,   # AI Guardrails (Web, Redis, Redis-Commander)
                9090, 8085, 5433,   # Training Portal
                9482                # Swagger
            ]
            force_cleanup_ports(ip_address, ssh_user, ssh_private_path, ports_to_clean)

            print("Waiting for Dokploy to stabilize...")
            time.sleep(10)
            all_projects = []

        # Find or create our target project
        existing_target = [p for p in all_projects if p[2] == args.project]
        if existing_target:
            project_id, env_ids, _ = existing_target[0]
            print(f"Found existing project: {args.project} ({project_id}) with env_ids: {env_ids}")
            # Handle env_ids being a list from get_all_project_ids modification
            if isinstance(env_ids, list) and len(env_ids) > 0:
                env_id = env_ids[0]
            else:
                env_id = env_ids if env_ids else None
                
            if not env_id:
                print(f"Warning: env_id is null for project {args.project}. Fetching manually...")
                env_id = get_environment_id(url, cookies, project_id)
        else:
            project_id, env_id = create_project(url, cookies, org_id, name=args.project)

        if not project_id or not env_id:
            print(f"CRITICAL: Failed to establish project/environment context. project_id={project_id}, env_id={env_id}")
            sys.exit(1)

        if not args.app:
            print("Cleaning up existing deployments...")
            delete_all_services(url, cookies, env_id)

        # Fetch existing apps in the environment
        existing_apps = get_all_compose_ids(url, cookies, env_id)
        
        for cfg_raw in app_configs:
            cfg = replace_domain(cfg_raw)
            if args.app and args.app.lower() not in cfg["name"].lower():
                print(f"Skipping {cfg['name']} (filter: {args.app})")
                continue

            # Gracefully skip apps whose repo is a private SSH URL the box can't
            # clone without a GitHub deploy key (e.g. Script Builder). Creating
            # them just yields a red deploy error. Set ALLOW_SSH_REPOS=1 (after
            # registering a deploy key / making the repo public) to include them.
            _repo = cfg.get("repo", "") or ""
            if (_repo.startswith("git@") or _repo.startswith("ssh://")) \
                    and os.environ.get("ALLOW_SSH_REPOS", "") not in ("1", "true", "yes"):
                print(f"Skipping {cfg['name']}: private SSH repo ({_repo}) — no deploy key "
                      f"on this host. Make the repo public or add a deploy key + set "
                      f"ALLOW_SSH_REPOS=1 to include it.")
                continue

            # Check if exists
            target_app = next((a for a in existing_apps if a["name"] == cfg["name"]), None)
            
            if target_app:
                cid = target_app["composeId"]
                print(f"Using existing compose application: {cfg['name']} ({cid})")
            else:
                cid = create_compose(
                    url, cookies, project_id, env_id, cfg["name"], server_id
                )
            if cid:
                repo_url = cfg.get("repo")
                ssh_key_to_use = git_ssh_key_id

                if repo_url and repo_url.startswith("https://"):
                    print(
                        f"Detected HTTPS URL for {cfg['name']}, skipping SSH key attachment."
                    )
                    ssh_key_to_use = None

                # Resolve .env file early to combine with git update. Prefers
                # the explicit "envFile" config key; falls back to name detection.
                env_file = resolve_env_file(cfg)
                env_content = None
                if env_file:
                    print(f"Found environment file for {cfg['name']}: {env_file}")
                    try:
                        with open(env_file, "r") as f:
                            env_content = replace_domain(f.read())
                    except Exception as e:
                        print(f"Warning: Could not read env file {env_file}: {e}")
                # Ensure DOMAIN is available for ${DOMAIN} interpolation in the
                # deployed compose (pure-git apps read it from the planted .env;
                # CP Agentic's Traefik labels use ${DOMAIN}).
                if env_content is not None and "\nDOMAIN=" not in ("\n" + env_content):
                    env_content = env_content.rstrip("\n") + f"\nDOMAIN={args.domain}\n"
                # Get branch if specified
                branch = cfg.get("branch", "main")
                
                # Get compose command if specified (e.g., "--profile cpu")
                compose_command = cfg.get("composeCommand", None)

                # Update Git and Environment variables in one go via API.
                # No-repo apps (compose ships locally) skip the git step — their
                # compose file is pushed directly further down.
                if repo_url:
                    update_compose_git(
                        url,
                        cookies,
                        cid,
                        repo_url,
                        env_vars=env_content,
                        ssh_key_id=ssh_key_to_use,
                        branch=branch,
                        compose_command=compose_command,
                        compose_path=cfg.get("composePath", "./docker-compose.yml"),
                    )
                
                # belts and suspenders: manually inject via API env call too
                if env_content:
                    update_compose_env(url, cookies, cid, env_content)

                if "exposures" in cfg:
                    print(f"Setting up multiple domains for {cfg['name']}...")
                    for exp in cfg["exposures"]:
                        create_domain(
                            url,
                            cookies,
                            cid,
                            exp["domain"],
                            exp["port"],
                            exp["service"],
                        )
                elif "domain" in cfg:
                    create_domain(
                        url, cookies, cid, cfg["domain"], cfg["port"], cfg["service"]
                    )

                # Resolve the deployed app dir name once. Used both to push a
                # local-compose override (below) and to plant the rendered .env
                # into the code dir right before deploy.
                full_app_name = get_compose_app_name(url, cookies, cid)

                # TRIGGER DEPLOYMENT (ONCE)
                print(f"Triggering final deployment for {cfg['name']}...")

                # CP Agentic MCP Playground now deploys pure-git: its repo
                # docker-compose.yml uses ${DOMAIN} (env-interpolated) and builds
                # custom-mcp-n8n from ./docker/n8n in the fresh clone. No raw
                # push / no build-context loss (that was the sourceType=raw bug).

                # LOCAL-COMPOSE OVERRIDE: any app carrying a "localCompose" key
                # ships a Dokploy-adapted compose (its git-repo compose bundles a
                # Caddy that binds host :80 and collides with Traefik). Push that
                # file as a "raw" source for BOTH repo and no-repo apps ("raw" is
                # the valid Dokploy sourceType enum — "compose" is rejected, which
                # silently left these apps on the wrong repo compose). Routing works
                # either way: apps that carry their own Traefik labels use them;
                # app-only composes rely on the Dokploy domain entry (create_domain,
                # above). Playground/Dev-Hub carry NO localCompose key (they use
                # their own env-var compose paths handled separately), so they are
                # never double-applied here.
                local_compose_cfg = cfg.get("localCompose")
                if local_compose_cfg:
                    lc_path = local_compose_cfg
                    if not os.path.isabs(lc_path):
                        lc_path = os.path.join(os.path.dirname(__file__), "..", lc_path)
                    if os.path.exists(lc_path):
                        with open(lc_path, "r") as f:
                            lc_content = replace_domain(f.read())
                        if env_file:
                            lc_content = hard_inject_env_vars(lc_content, env_file)
                        app_path = f"/etc/dokploy/compose/{full_app_name}/code" if full_app_name else None
                        lc_content = sanitize_compose_file(lc_content, cfg["name"], app_path=app_path)
                        print(f"Pushing local compose override for {cfg['name']} as raw compose source: {lc_path}")
                        update_compose_file(url, cookies, cid, lc_content, source_type="raw")
                    else:
                        print(f"Warning: localCompose not found for {cfg['name']}: {lc_path}")

                # Dev Hub now deploys pure-git via composePath ./docker-compose.dokploy.yml
                # committed in the repo (build: ./frontend + ./backend from the clone).
                # The rendered .env is planted below, so no hardcoded placeholder secrets.

                # ROBUSTNESS: plant the rendered, domain-substituted .env into the
                # deployed code dir right before deploying, overwriting whatever
                # the repo shipped. Runs for EVERY app that resolved an env file
                # (not gated behind any name/branch), so no app comes up on stale
                # or placeholder creds. Uses env_content (domain-replaced) when
                # available so {{DOMAIN}} placeholders are resolved.
                if env_file and full_app_name:
                    print(f"Ensuring .env file for {full_app_name} on server {ip_address}...")
                    time.sleep(2)  # Wait for Dokploy to create directories
                    if env_content:
                        import tempfile
                        with tempfile.NamedTemporaryFile(mode='w', suffix='.env', delete=False) as tmp:
                            tmp.write(env_content)
                            tmp_path = tmp.name
                        try:
                            copy_env_file_to_remote(tmp_path, ip_address, full_app_name)
                        finally:
                            os.unlink(tmp_path)
                    else:
                        copy_env_file_to_remote(env_file, ip_address, full_app_name)

                deploy_compose(url, cookies, cid)

        # Post-deploy security hardening — runs on every fresh deploy, unless
        # install.sh already hardened the host and passed --skip-harden.
        if args.skip_harden:
            print("\nSkipping built-in harden_server (--skip-harden); host hardened by install.sh.")
        else:
            harden_server(
                ip_address,
                ssh_user=args.ssh_user,
                ssh_private_path=ssh_private_path if not args.ssh_password else None,
                ssh_password=args.ssh_password,
            )

        print("\n" + "=" * 60 + "\nDOKPLOY COMPOSE AUTOMATION COMPLETE!\n" + "=" * 60)
