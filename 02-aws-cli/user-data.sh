#!/bin/bash
# Every command is logged. If something goes wrong, SSH in and run:
#   sudo cat /var/log/user-data.log
set -xe
exec > /var/log/user-data.log 2>&1

# System update and dependencies
dnf update -y
dnf install -y git nodejs npm

# Add 1 GB swap so `next build` does not get OOM-killed on t3.micro
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Keep the app alive across reboots and crashes
npm install -g pm2@latest

# Clone the repo
git clone https://github.com/Manu-world/ops-playbook-hub.git /home/ec2-user/app
cd /home/ec2-user/app

# --- Optional: MongoDB Atlas ---
# Uncomment and set your connection string to share data across all instances.
# Without this, each instance stores its own data locally (fine for the tutorial).
# echo 'MONGODB_URI="mongodb+srv://USER:PASS@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority"' > .env.local

# Install, build, start
npm install
npm run build
pm2 start npm --name "next-app" -- start

# Survive reboots
pm2 startup
pm2 save
