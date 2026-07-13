from db.database import SessionLocal
from db import models
from passlib.context import CryptContext
import os

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password):
    return pwd_context.hash(password)

def seed():
    db = SessionLocal()
    try:
        # 0. Basic Configuration
        DOMAIN = os.getenv("DOMAIN", "example.com")
        
        # 1. Seed Superadmin
        admin_email = os.getenv("SUPERADMIN_EMAIL", f"admin@{DOMAIN}")
        admin_password = os.getenv("SUPERADMIN_PASSWORD", "ChangeThisPassword123!")
        
        user = db.query(models.User).filter(models.User.email == admin_email).first()
        if not user:
            print(f"Seeding superadmin user: {admin_email}")
            new_user = models.User(
                email=admin_email,
                hashed_password=get_password_hash(admin_password),
                is_admin=True
            )
            db.add(new_user)
            db.commit()
            print("Superadmin seeded successfully.")
        else:
            print("Superadmin already exists.")
            
        # 2. Clear existing applications
        print("Clearing existing applications...")
        db.query(models.Application).delete()
        db.commit()

        # 3. Seed expanded applications with project groupings
        print("Seeding applications with groupings...")
        apps = [
            models.Application(
                name="AI Guardrails Demo",
                description="AI security guardrails",
                url=f"https://guardrails.{DOMAIN}",
                github_url="https://github.com/alshawwaf/ai-guardrails-demo",
                category="AI Security",
                icon="/logos/guardrails.png",
                is_live=True
            ),
            models.Application(
                name="Training Portal",
                description="AI development training platform",
                url=f"https://training.{DOMAIN}",
                github_url="https://github.com/alshawwaf/training-portal",
                category="Training",
                icon="/logos/training.png",
                is_live=True
            ),
            models.Application(
                name="Docs to Swagger",
                description="Convert API docs to OpenAPI",
                url=f"https://swagger.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-docs-to-swagger",
                category="Developer Tools",
                icon="/logos/swagger.png",
                is_live=True
            ),
            models.Application(
                name="n8n Workflow",
                description="AI workflow automation platform",
                url=f"https://workflow.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-agentic-mcp-playground",
                category="Automation",
                icon="/logos/n8n.png",
                is_live=True
            ),
            models.Application(
                name="Open WebUI",
                description="Chat interface for AI models",
                url=f"https://chat.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-agentic-mcp-playground",
                category="AI Chat",
                icon="/logos/openwebui.png",
                is_live=True
            ),
            models.Application(
                name="Flowise",
                description="Visual LLM flow builder",
                url=f"https://flowise.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-agentic-mcp-playground",
                category="AI Development",
                icon="/logos/flowise.png",
                is_live=True
            ),
            models.Application(
                name="Langflow",
                description="Visual AI pipeline designer",
                url=f"https://langflow.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-agentic-mcp-playground",
                category="AI Development",
                icon="/logos/langflow.png",
                is_live=True
            ),
            models.Application(
                name="Demo Server",
                description="Threat prevention demo — test IPS, malware emulation, and network security controls",
                url=f"https://threat.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp_demo_server",
                category="Security Demo",
                icon="/logos/wazuh.png",
                is_live=True
            ),
            models.Application(
                name="Identity Provider (IdP)",
                description="Full Identity Provider simulator — SAML SSO, SCIM provisioning, security POCs",
                url=f"https://idp.{DOMAIN}",
                github_url="https://github.com/alshawwaf/SAML_IDP_Simulator",
                category="Security Demo",
                icon="/logos/authentik.png",
                is_live=True
            ),
            models.Application(
                name="Script Builder",
                description="Firewall deployment script generator",
                url=f"https://scriptbuilder.{DOMAIN}",
                github_url="https://github.com/alshawwaf/cp-script-builder",
                category="Developer Tools",
                icon="/logos/codeserver.png",
                is_live=True
            ),
            models.Application(
                name="OpenClaw",
                description="Personal AI assistant gateway",
                url=f"https://claw.{DOMAIN}",
                github_url="https://github.com/openclaw",
                category="Agentic AI",
                icon="/logos/openclaw.png",
                is_live=True
            ),
        ]
        db.add_all(apps)
        db.commit()
        print("Grouped applications seeded successfully.")
            
    finally:
        db.close()

if __name__ == "__main__":
    seed()
