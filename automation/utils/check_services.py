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
    try:
        response = requests.post(login_url, json=payload, timeout=30)
        if response.status_code == 200:
            return response.cookies
        return None
    except:
        return None

def get_project_services(url, cookies, project_id):
    trpc_url = f"{url}/api/trpc/project.one?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22projectId%22%3A%22{project_id}%22%7D%7D%7D"
    try:
        response = requests.get(trpc_url, cookies=cookies, timeout=30)
        data = response.json()
        compose_apps = data[0]["result"]["data"]["json"]["compose"]
        return compose_apps
    except:
        return []

cookies = login(URL, EMAIL, PASSWORD)
if cookies:
    # 1. Get all projects
    trpc_projects_url = f"{URL}/api/trpc/project.all?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%7D%7D%7D"
    resp = requests.get(trpc_projects_url, cookies=cookies, timeout=30)
    projects = resp.json()[0]["result"]["data"]["json"]
    
    for p in projects:
        if "Agentic" in p["name"]:
            print(f"Checking Project: {p['name']} ({p['projectId']})")
            composes = get_project_services(URL, cookies, p['projectId'])
            print(f"Found {len(composes)} compose apps:")
            for c in composes:
                print(f" - {c['name']} ({c['composeId']}) status: {c['composeStatus']}")
        else:
            print(f"Skipping Project: {p['name']} ({p['projectId']})")
