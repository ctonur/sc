#!/usr/bin/env bash
set -euo pipefail
set -x

# Log file configuration
deploy_log="/var/log/deploy_atex.log"
echo "" | sudo tee -a "$deploy_log"
exec > >(sudo tee -a "$deploy_log") 2>&1

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Configuration
deploy_dir="/var/www/atexplastik"
repo_url="https://github.com/ctonur/atex.git"
workspace_dir="/home/osandikci/workspace"
domain="atexplastik.com"
alias_domain="www.atexplastik.com"

domain_rule="http://${domain}"

log "=== Deployment started for ${domain} ==="

# 1. Update system and install packages
log "Updating system packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git apache2 ufw
log "System update complete."

# 2. Install Node.js (20.x) if missing
if ! command -v node >/dev/null 2>&1; then
  log "Node.js not found. Installing Node.js 20.x..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
  log "Node.js installed: $(node -v)"
else
  log "Node.js is already installed: $(node -v)"
fi

# 3. Open HTTP port on UFW
log "Configuring UFW to allow HTTP..."
sudo ufw allow 80/tcp
sudo ufw --force enable

# 4. Clone or update repository
log "Cloning or updating repository..."
mkdir -p "$workspace_dir"
if [ ! -d "$workspace_dir/atex" ]; then
  git clone "$repo_url" "$workspace_dir/atex"
else
  cd "$workspace_dir/atex" && git pull origin main
fi

# 5. Install dependencies & build
log "Building project..."
cd "$workspace_dir/atex/project"
npm install
npm run build

# 6. Deploy build output
log "Deploying build to web root..."
sudo mkdir -p "$deploy_dir"
sudo rm -rf "$deploy_dir"/*
if [ -d "dist" ]; then
  sudo cp -r dist/* "$deploy_dir/"
elif [ -d "build" ]; then
  sudo cp -r build/* "$deploy_dir/"
else
  log "Error: build output not found."
  exit 1
fi
sudo chown -R www-data:www-data "$deploy_dir"
sudo chmod -R 755 "$deploy_dir"
log "Deployment to ${deploy_dir} complete."

# 7. Configure Apache (HTTP only)
log "Enabling required Apache modules..."
sudo a2enmod rewrite headers

vhost_file="/etc/apache2/sites-available/atexplastik.conf"
log "Writing HTTP VirtualHost configuration..."
sudo tee "$vhost_file" > /dev/null <<EOF
<VirtualHost *:80>
  ServerName ${domain}
  ServerAlias ${alias_domain}
  DocumentRoot ${deploy_dir}

  <Directory ${deploy_dir}>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  # No redirect: Cloudflare Flexible will handle HTTPS

  ErrorLog \${APACHE_LOG_DIR}/atexplastik_error.log
  CustomLog \${APACHE_LOG_DIR}/atexplastik_access.log combined
</VirtualHost>
EOF

log "Disabling default Apache site..."
sudo a2dissite 000-default.conf || true
log "Enabling atexplastik site..."
sudo a2ensite atexplastik.conf

# 8. Reload Apache
log "Reloading Apache..."
sudo systemctl reload apache2

# 9. Provide user instructions
echo "Deployment complete!"
echo "Cloudflare Spectrum in Flexible mode will serve HTTPS."
echo "Test with:"
echo "  curl -I ${domain_rule}"
