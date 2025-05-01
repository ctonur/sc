#!/usr/bin/env bash
set -euo pipefail
set -x

# Log file configuration
deploy_log="/var/log/deploy_atex.log"
# Ensure log file exists, create if not
echo "" | sudo tee -a "$deploy_log"
# Redirect stdout/stderr to log with sudo permissions
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
mkdir -p "$workspace_dir"
cd "$workspace_dir"
if [ -d "atex" ]; then
  log "Repository exists, pulling latest changes..."
  cd atex && git pull origin main
else
  log "Cloning repository from ${repo_url}..."
  git clone "$repo_url"
  cd atex
fi

# Enter project subdirectory where package.json resides
if [ -d "project" ]; then
  cd project
  log "Entered project directory: $(pwd)"
else
  log "Error: 'project' directory not found in repository root."
  exit 1
fi

# 4. Install dependencies and build
log "Installing npm dependencies..."
npm install
log "Running npm build..."
npm run build
log "Build completed."

# 5. Determine build directory
if [ -d "build" ]; then
  build_dir="build"
elif [ -d "dist" ]; then
  build_dir="dist"
else
  log "Error: build output directory not found (expected 'build/' or 'dist/')"
  exit 1
fi
log "Using build directory: ${build_dir}"

# 6. Deploy to Apache web root
log "Deploying build files to ${deploy_dir}..."
sudo mkdir -p "$deploy_dir"
sudo rm -rf "$deploy_dir"/*
sudo cp -r "$build_dir"/* "$deploy_dir/"
sudo chown -R www-data:www-data "$deploy_dir"
sudo chmod -R 755 "$deploy_dir"
log "Deployment to web root complete."

# 7. Enable Apache modules
log "Enabling Apache modules: rewrite, headers..."
sudo a2enmod rewrite headers

# 8. Create Apache VirtualHost for HTTP (Cloudflare SSL handled externally)
vhost_conf="/etc/apache2/sites-available/atexplastik.conf"
log "Writing Apache VirtualHost config to ${vhost_conf}..."
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

    ErrorLog \${APACHE_LOG_DIR}/atexplastik_error.log
    CustomLog \${APACHE_LOG_DIR}/atexplastik_access.log combined
</VirtualHost>
EOF

# 9. Enable site and reload Apache
log "Enabling site and reloading Apache..."
sudo a2ensite atexplastik
sudo systemctl reload apache2

# 10. Create .htaccess with rewrite, Cloudflare HTTPS redirect, headers, CORS, cache
htaccess_file="${deploy_dir}/.htaccess"
log "Creating .htaccess at ${htaccess_file}..."
sudo tee "$htaccess_file" > /dev/null <<HTACCESS
RewriteEngine On
RewriteBase /
RewriteRule ^index\\.html$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteCond %{REQUEST_FILENAME} !-l
RewriteRule . /index.html [L]

# Force HTTPS via Cloudflare X-Forwarded-Proto header
RewriteCond %{HTTP:X-Forwarded-Proto} !https
RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

# Security headers
Header set X-Content-Type-Options "nosniff"
Header set X-XSS-Protection "1; mode=block"
Header set X-Frame-Options "SAMEORIGIN"
Header set Strict-Transport-Security "max-age=31536000; includeSubDomains"

# CORS for specific domain
Header set Access-Control-Allow-Origin "https://${alias_domain}"

# Cache static assets
<FilesMatch "\\.(ico|pdf|jpg|jpeg|png|gif|svg|js|css)$">
    Header set Cache-Control "max-age=31536000, public"
</FilesMatch>
HTACCESS
log ".htaccess created."

# 11. Final reload and status
log "Reloading Apache for final settings..."
sudo systemctl reload apache2
log "Apache status: $(sudo systemctl is-active apache2)"

log "=== Deployment finished for ${domain} ==="
echo "Deployment complete! Check logs at ${deploy_log}"
