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

log "=== Deployment started for ${domain} ==="

# 1. Update system and install prerequisites
log "Updating system packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git apache2
log "System update complete."

# 2. Install Node.js & npm if missing
if ! command -v node >/dev/null 2>&1; then
  log "Node.js not found. Installing Node.js 20.x..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
  log "Node.js installed: $(node -v)"
else
  log "Node.js is already installed: $(node -v)"
fi

# 3. Clone or update the repository
log "Cloning or updating repository..."
mkdir -p "$workspace_dir"
cd "$workspace_dir"
if [ -d "atex" ]; then
  cd atex
  git pull origin main
else
  git clone "$repo_url" atex
  cd atex
fi

# 4. Enter project subdirectory
log "Entering project directory..."
# Adjust if your project root differs
target_dir="project"
if [ -d "$target_dir" ]; then
  cd "$target_dir"
else
  log "No 'project' folder; staying in repository root"
fi

# 5. Install dependencies and build
log "Installing npm dependencies..."
npm install
log "Building project..."
npm run build

# 6. Detect build output
echo "Detecting build directory..."
if [ -d "build" ]; then
  build_dir="build"
elif [ -d "dist" ]; then
  build_dir="dist"
else
  log "Build directory not found."
  exit 1
fi
log "Build directory: ${build_dir}"

# 7. Deploy to web root
log "Deploying to ${deploy_dir}..."
sudo mkdir -p "$deploy_dir"
sudo rm -rf "$deploy_dir"/*
sudo cp -r "$build_dir"/* "$deploy_dir/"
sudo chown -R www-data:www-data "$deploy_dir"
sudo chmod -R 755 "$deploy_dir"
log "Deployment complete."

# 8. Enable Apache modules
log "Enabling Apache modules: rewrite, headers..."
sudo a2enmod rewrite headers

# 9. Configure VirtualHost for HTTP
vhost_conf="/etc/apache2/sites-available/atexplastik.conf"
log "Writing VirtualHost to ${vhost_conf}..."
sudo tee "$vhost_conf" > /dev/null <<EOF
<VirtualHost *:80>
  ServerName ${domain}
  ServerAlias ${alias_domain}
  DocumentRoot ${deploy_dir}

  <Directory ${deploy_dir}>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  # Redirect HTTP to HTTPS at Cloudflare layer
  RewriteEngine On
  RewriteCond %{HTTP:X-Forwarded-Proto} !https
  RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

  ErrorLog \${APACHE_LOG_DIR}/atexplastik_error.log
  CustomLog \${APACHE_LOG_DIR}/atexplastik_access.log combined
</VirtualHost>
EOF

# 10. Enable site and reload Apache
log "Disabling default site..."
sudo a2dissite 000-default
log "Enabling atexplastik site..."
sudo a2ensite atexplastik
log "Reloading Apache..."
sudo systemctl reload apache2

# 11. Create .htaccess for SPA support and headers
htaccess="${deploy_dir}/.htaccess"
log "Creating .htaccess at ${htaccess}..."
sudo tee "$htaccess" > /dev/null <<HTACCESS
RewriteEngine On
RewriteBase /
RewriteRule ^index\.html$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteCond %{REQUEST_FILENAME} !-l
RewriteRule . /index.html [L]

# Security headers
Header set X-Content-Type-Options "nosniff"
Header set X-XSS-Protection "1; mode=block"
Header set X-Frame-Options "SAMEORIGIN"
Header set Strict-Transport-Security "max-age=31536000; includeSubDomains"

# CORS if needed
Header set Access-Control-Allow-Origin "https://${alias_domain}"

# Cache static assets
<FilesMatch "\.(ico|pdf|jpg|jpeg|png|gif|svg|js|css)$">
  Header set Cache-Control "max-age=31536000, public"
</FilesMatch>
HTACCESS

# 12. Final check
log "Apache status: $(sudo systemctl is-active apache2)"
log "=== Deployment finished ==="
echo "Done. Check logs at ${deploy_log}"
