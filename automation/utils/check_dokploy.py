import os
import requests
import json
import sys

URL = os.environ.get("DOKPLOY_URL", "http://localhost:3000")
EMAIL = os.environ.get("DOKPLOY_EMAIL", "admin@example.com")
PASSWORD = os.environ.get("DOKPLOY_PASSWORD", "")

def login(url, email, password):
    login_url = f"{url}/api/auth/sign-in/email"
    payload = {"email": email, "password": password}
    print(f"Logging in as {email}...")
    try:
        response = requests.post(login_url, json=payload, timeout=30)
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

def get_all_projects(url, cookies):
    trpc_url = f"{url}/api/trpc/project.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%7D%7D%7D"
    try:
        response = requests.get(trpc_url, cookies=cookies, timeout=30)
        data = response.json()
        projects = data[0]["result"]["data"]["json"]
        return projects
    except Exception as e:
        print(f"Error listing projects: {e}")
        return []

cookies = login(URL, EMAIL, PASSWORD)
if cookies:
    projects = get_all_projects(URL, cookies)
    print(f"Found {len(projects)} projects:")
    for p in projects:
        print(f" - {p['name']} ({p['projectId']})")
