
import os
import sys
import re

# Add automation to path to import functions
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.append(script_dir)

from dokploy_automate import sanitize_compose_file, hard_inject_env_vars, replace_domain

def troubleshoot():
    print("--- Troubleshooting Agentic Playground Compose Transformation ---")
    
    app_name = "CP Agentic MCP Playground"
    
    # Try multiple possible locations for the compose file
    possible_compose_paths = [
        os.path.join(script_dir, "..", "cp-agentic-mcp-playground", "docker-compose.yml"),
        os.path.expanduser("~/Desktop/cp-agentic-mcp-playground/docker-compose.yml"),
        "C:/Users/admin/Desktop/cp-agentic-mcp-playground/docker-compose.yml",
    ]
    local_compose = None
    for p in possible_compose_paths:
        if os.path.exists(p):
            local_compose = p
            break
    
    if not local_compose:
        print(f"ERROR: Local compose not found. Tried: {possible_compose_paths}")
        return
    
    print(f"Using compose file: {local_compose}")
    
    # Try multiple possible locations for the env file
    possible_env_paths = [
        os.path.join(script_dir, "envs", ".env_agentic"),
        os.path.join(script_dir, ".env_agentic"),
        "automation/envs/.env_agentic",
    ]
    env_file = None
    for p in possible_env_paths:
        if os.path.exists(p):
            env_file = p
            break
    
    app_path = "/etc/dokploy/compose/cp-agentic-mcp-playground-ataahy/code"

    with open(local_compose, "r") as f:
        orig_content = f.read()

    print(f"Original content length: {len(orig_content)}")
    
    # Simulate the transformation loop in dokploy_automate.py
    os.environ["DOMAIN"] = "ai.alshawwaf.ca"
    
    # 1. Replace {{DOMAIN}}
    content = replace_domain(orig_content)
    print("1. Replace {{DOMAIN}} - Done")
    
    # 2. Hard-inject environment variables
    if env_file:
        content = hard_inject_env_vars(content, env_file)
        print(f"2. Hard-inject (using {env_file}) - Done")
    else:
        print(f"WARNING: Env file not found. Tried: {possible_env_paths}")

    # 3. Sanitize (Volumes, env_file tags)
    compose_content = sanitize_compose_file(content, app_name, app_path=app_path)
    print(f"3. Sanitize (app_path={app_path}) - Done")
    
    # Save to a temporary file for inspection
    output_path = "transformed_compose.yml"
    with open(output_path, "w") as f:
        f.write(compose_content)
    
    print(f"\nTransformed compose saved to {output_path}")
    
    # Check for remaining $ tokens that might cause issues
    remaining_vars = re.findall(r'\$\{([^}]+)\}', compose_content)
    if remaining_vars:
        print(f"\nWARNING: Found {len(remaining_vars)} remaining variables: {list(set(remaining_vars))}")
    
    # Check for relative mounts
    if "./" in compose_content:
        # Check contexts of ./
        print("\nWARNING: Found './' in output. Checking context...")
        lines = compose_content.splitlines()
        for i, line in enumerate(lines):
            if "./" in line:
                print(f"Line {i+1}: {line.strip()}")

if __name__ == "__main__":
    troubleshoot()
