#!/usr/bin/env bash
# ==========================================================
# Automated Docker Deployment Script
# Author: <Chuks Agupugo>
# Description:
# Automates setup, deployment, and configuration of a Dockerized
# application on a remote Linux server with Nginx reverse proxy.
# ==========================================================

set -euo pipefail

# ====== Global Variables ======
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "❌ An unexpected error occurred. Check $LOG_FILE for details."' ERR

# ====== Step 1: Collect Parameters ======
echo "🧩 Collecting Deployment Parameters..."
read -p "Enter Git Repository URL: " GIT_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter Branch name [main]: " BRANCH
BRANCH=${BRANCH:-main}
read -p "Enter SSH Username: " SSH_USER
read -p "Enter Server IP Address: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY
read -p "Enter Application Port (internal container port): " APP_PORT

if [[ -z "$GIT_URL" || -z "$PAT" || -z "$SERVER_IP" ]]; then
  echo "❌ Missing required inputs. Exiting."
  exit 1
fi

# ====== Step 2: Clone or Update Repository ======
REPO_NAME=$(basename "$GIT_URL" .git)

if [ -d "$REPO_NAME" ]; then
  echo "📦 Repository already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git pull
else
  echo "📥 Cloning repository..."
  git clone https://$PAT@${GIT_URL#https://}
  cd "$REPO_NAME"
fi

git checkout "$BRANCH"

# ====== Step 3: Validate Docker Configuration ======
if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
  echo "❌ No Dockerfile or docker-compose.yml found in project."
  exit 2
fi
echo "✅ Docker configuration verified."

# ====== Step 4: Verify SSH Connection ======
echo "🔍 Verifying SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo connected" >/dev/null 2>&1; then
  echo "❌ Unable to connect to $SERVER_IP via SSH."
  exit 3
fi
echo "✅ SSH connection successful."

# ====== Optional Cleanup Flag ======
if [[ "${1:-}" == "--cleanup" ]]; then
  echo "🧹 Running cleanup on remote server..."
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash -s <<'EOF'
    docker stop $(docker ps -q) || true
    docker system prune -af
    sudo rm -rf ~/app
EOF
  echo "✅ Cleanup complete."
  exit 0
fi

# ====== Step 5: Prepare Remote Environment ======
echo "🧰 Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash -s <<'EOF'
set -e
echo "Updating system packages..."
sudo apt update -y

echo "Installing Docker..."
if ! command -v docker &>/dev/null; then
  sudo apt install -y docker.io
fi

echo "Installing Docker Compose..."
if ! command -v docker-compose &>/dev/null; then
  sudo apt install -y docker-compose
fi

echo "Installing Nginx..."
if ! command -v nginx &>/dev/null; then
  sudo apt install -y nginx
fi

sudo usermod -aG docker $USER
sudo systemctl enable docker --now
EOF

echo "✅ Remote environment prepared."

# ====== Step 6: Transfer Project Files ======
echo "📂 Transferring project files to remote server..."
rsync -az -e "ssh -i $SSH_KEY" ./ "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app/"

# ====== Step 7: Build and Deploy Containers ======
echo "🚀 Building and deploying application on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash -s <<EOF
set -e
cd ~/app
if [ -f docker-compose.yml ]; then
  docker-compose down || true
  docker-compose up -d --build
else
  docker stop app_container || true
  docker rm app_container || true
  docker build -t myapp .
  docker run -d --name app_container -p $APP_PORT:$APP_PORT myapp
fi
EOF
echo "✅ Application deployed."

# ====== Step 8: Configure Nginx Reverse Proxy ======
echo "🌐 Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash -s <<EOF
sudo bash -c 'cat > /etc/nginx/sites-available/app.conf <<NGINX
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX'

sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF
echo "✅ Nginx configured."

# ====== Step 9: Validate Deployment ======
echo "🔎 Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash -s <<EOF
docker ps
sudo systemctl is-active --quiet nginx && echo "Nginx is active."
curl -I http://localhost || echo "❌ Application not reachable locally."
EOF

echo "✅ Deployment validation complete."

# ====== Step 10: Completion Message ======
echo "🎉 Deployment complete! Check log file: $LOG_FILE"
echo "Access your application via: http://$SERVER_IP"

exit 0
