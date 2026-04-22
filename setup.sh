#!/bin/bash
# Shot 1: VPS Environment Setup for smallsizedpuppy.SB
# Run on Ubuntu 22.04 LTS as root or with sudo

set -e  # exit on error
set -o pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== smallsizedpuppy.SB VPS Setup ===${NC}"

# 1. Update system and install base packages
echo -e "${YELLOW}Updating system and installing base packages...${NC}"
apt update && apt upgrade -y
apt install -y \
    python3 python3-pip python3-venv \
    git docker.io docker-compose \
    sqlite3 curl wget jq \
    nginx certbot python3-certbot-nginx \
    ufw fail2ban

# 2. Install Node.js 20.x (for n8n)
echo -e "${YELLOW}Installing Node.js 20.x...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# 3. Install PM2 (process manager) for n8n and other Node services
echo -e "${YELLOW}Installing PM2...${NC}"
npm install -g pm2

# 4. Create project directory and set permissions
echo -e "${YELLOW}Creating /home/ubuntu/smallsizedpuppy/...${NC}"
mkdir -p /home/ubuntu/smallsizedpuppy/{logs,data,scripts}
cd /home/ubuntu/smallsizedpuppy

# 5. Set up Python virtual environment
echo -e "${YELLOW}Creating Python virtual environment...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install requests beautifulsoup4 discord.py openai schedule
deactivate

# 6. Clone and set up Facebook Marketplace RSS proxy
echo -e "${YELLOW}Setting up Facebook Marketplace RSS proxy...${NC}"
git clone https://github.com/regek/facebook-marketplace-rss.git fb-proxy || true
cd fb-proxy
# Create virtual env for fb-proxy
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate
cd ..

# 7. Create database and seen listings table
echo -e "${YELLOW}Initializing SQLite database...${NC}"
cat > init_db.py << 'EOF'
import sqlite3
conn = sqlite3.connect('/home/ubuntu/smallsizedpuppy/data/listings.db')
conn.execute('''
    CREATE TABLE IF NOT EXISTS seen_listings (
        id TEXT PRIMARY KEY,
        url TEXT UNIQUE,
        title TEXT,
        first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_notified TIMESTAMP,
        approved INTEGER DEFAULT 0
    )
''')
conn.execute('''
    CREATE TABLE IF NOT EXISTS conversations (
        thread_id TEXT PRIMARY KEY,
        listing_url TEXT,
        seller_contact TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
''')
conn.commit()
conn.close()
print("Database initialized at /home/ubuntu/smallsizedpuppy/data/listings.db")
EOF
python3 init_db.py

# 8. Create scraper script (for listing details and images)
echo -e "${YELLOW}Creating scraper.py...${NC}"
cat > scraper.py << 'EOF'
#!/usr/bin/env python3
import requests, json, sys, argparse
from bs4 import BeautifulSoup
def scrape(url):
    headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
    r = requests.get(url, headers=headers, timeout=10)
    soup = BeautifulSoup(r.text, 'html.parser')
    title = soup.find('title').get_text(strip=True) if soup.find('title') else ''
    desc = ''
    for sel in ['#postingbody', '.description', '[data-testid="listing-description"]']:
        elem = soup.select_one(sel)
        if elem: desc = elem.get_text(strip=True); break
    images = [img.get('src') for img in soup.find_all('img') if img.get('src', '').startswith('http')][:5]
    print(json.dumps({'url': url, 'title': title, 'description': desc, 'images': images}))
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--url', required=True)
    args = p.parse_args(); scrape(args.url)
EOF
chmod +x scraper.py

# 9. Create Discord bot listener script (for !approve commands)
echo -e "${YELLOW}Creating discord_bot.py...${NC}"
cat > discord_bot.py << 'EOF'
import discord, requests, json, os, asyncio
DISCORD_TOKEN = os.getenv('DISCORD_BOT_TOKEN', 'YOUR_DISCORD_BOT_TOKEN')
N8N_WEBHOOK_URL = os.getenv('N8N_APPROVAL_WEBHOOK', 'https://your-n8n.com/webhook/discord-approval')
class Bot(discord.Client):
    async def on_ready(self): print(f'Logged in as {self.user}')
    async def on_message(self, message):
        if message.author == self.user: return
        if message.content.startswith('!approve'):
            parts = message.content.split()
            if len(parts) > 1:
                url = parts[1]
                payload = {'action': 'APPROVE', 'url': url, 'user_id': str(message.author.id)}
                try:
                    resp = requests.post(N8N_WEBHOOK_URL, json=payload, timeout=5)
                    await message.channel.send(f"✅ Approved! Message sent to seller for {url}")
                except Exception as e:
                    await message.channel.send(f"❌ Error: {e}")
intents = discord.Intents.default()
intents.message_content = True
client = Bot(intents=intents)
client.run(DISCORD_TOKEN)
EOF

# 10. Create changedetection.io docker-compose for real-time Craigslist monitoring
echo -e "${YELLOW}Creating docker-compose for changedetection.io...${NC}"
cat > docker-compose.yml << 'EOF'
version: '3'
services:
  changedetection:
    image: ghcr.io/dgtlmoon/changedetection.io:latest
    ports:
      - "127.0.0.1:5000:5000"
    volumes:
      - /home/ubuntu/smallsizedpuppy/data/changedetection:/datastore
    restart: unless-stopped
EOF
docker-compose up -d

# 11. Install n8n using PM2 (self-hosted, queue mode with Redis)
echo -e "${YELLOW}Installing n8n via PM2...${NC}"
# Install Redis via Docker
docker run -d --name redis -p 127.0.0.1:6379:6379 --restart unless-stopped redis:alpine
npm install -g n8n
# Create n8n config
mkdir -p /home/ubuntu/.n8n
cat > /home/ubuntu/.n8n/.env << 'EOF'
N8N_PORT=5678
N8N_HOST=localhost
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=127.0.0.1
QUEUE_BULL_REDIS_PORT=6379
WEBHOOK_URL=https://your-domain.com
EOF
# Start n8n with PM2
pm2 start n8n --name n8n -- --config /home/ubuntu/.n8n/.env
pm2 save
pm2 startup

# 12. Setup nginx reverse proxy (optional but recommended for HTTPS)
echo -e "${YELLOW}Configuring nginx (optional) — edit manually if needed${NC}"
cat > /etc/nginx/sites-available/smallsizedpuppy << 'EOF'
server {
    listen 80;
    server_name your-domain.com;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location /webhook/ {
        proxy_pass http://127.0.0.1:5678;
    }
}
EOF
# Enable site if domain is set (manual step)
# ln -s /etc/nginx/sites-available/smallsizedpuppy /etc/nginx/sites-enabled/
# certbot --nginx -d your-domain.com

# 13. Firewall rules
echo -e "${YELLOW}Configuring UFW...${NC}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 14. Create environment variable template file
echo -e "${YELLOW}Creating .env.template...${NC}"
cat > /home/ubuntu/smallsizedpuppy/.env.template << 'EOF'
# Required tokens - obtain as follows:
# DISCORD_BOT_TOKEN: https://discord.com/developers/applications -> New App -> Bot -> Copy Token. Enable Message Content Intent.
# N8N_APPROVAL_WEBHOOK: After importing n8n workflow, use the webhook URL from the "discord-approval" node (e.g., https://your-n8n.com/webhook/discord-approval)
# OPENAI_API_KEY: https://platform.openai.com/api-keys
# MAILFENCE_SMTP_PASS: Mailfence Settings -> SMTP -> App password
# FB_PAGE_ACCESS_TOKEN: Meta Developer Portal -> App -> Messenger -> Generate token for your Page

export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export N8N_APPROVAL_WEBHOOK="https://your-n8n.com/webhook/discord-approval"
export OPENAI_API_KEY="sk-..."
export MAILFENCE_SMTP_PASS="..."
export FB_PAGE_ACCESS_TOKEN="EAA..."
EOF

# 15. Create startup script to load env and run discord bot
echo -e "${YELLOW}Creating run_discord_bot.sh...${NC}"
cat > /home/ubuntu/smallsizedpuppy/run_discord_bot.sh << 'EOF'
#!/bin/bash
source /home/ubuntu/smallsizedpuppy/.env.template
source /home/ubuntu/smallsizedpuppy/venv/bin/activate
python3 /home/ubuntu/smallsizedpuppy/discord_bot.py
EOF
chmod +x /home/ubuntu/smallsizedpuppy/run_discord_bot.sh

# 16. PM2 for discord bot as well
pm2 start /home/ubuntu/smallsizedpuppy/run_discord_bot.sh --name discord-bot
pm2 save

echo -e "${GREEN}=== Setup complete! ===${NC}"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Edit /home/ubuntu/smallsizedpuppy/.env.template and fill in all tokens."
echo "2. Run: source /home/ubuntu/smallsizedpuppy/.env.template"
echo "3. Run: pm2 restart n8n discord-bot"
echo "4. Import the n8n workflow JSON (Shot 2) into n8n at http://$(curl -s ifconfig.me):5678"
echo "5. Configure your Facebook RSS proxy to point to http://localhost:5000/feed?query=small+lap+dog+free"
echo "6. Set up changedetection.io webhook to n8n's Craigslist webhook endpoint"
echo "7. For real-time, also configure Facebook webhook in Meta Developer Portal to point to /fb-marketplace-webhook"
echo ""
echo -e "${GREEN}Ready for Shot 2.${NC}"
