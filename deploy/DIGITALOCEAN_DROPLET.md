# Deploy the server on a DigitalOcean Droplet

Follow these steps to run the combined server (token + obstacle) on a Droplet so the app can use it over the internet.

## 1. Create a Droplet

1. Go to [DigitalOcean](https://cloud.digitalocean.com) → **Droplets** → **Create Droplet**.
2. Choose **Ubuntu 22.04 LTS**.
3. Pick a plan (Basic $6/mo is enough to start).
4. Add your SSH key (or create a root password).
5. Create the Droplet and note its **IP address**.

## 2. SSH into the Droplet

```bash
ssh root@YOUR_DROPLET_IP
```

## 3. Install Python and clone your project

```bash
apt update && apt install -y python3 python3-pip python3-venv git
```

Then either:

**A) Clone from Git (if your repo is on GitHub/GitLab):**

```bash
cd /opt
git clone https://github.com/YOUR_USER/YOUR_REPO.git nav-app
cd nav-app
```

**B) Or copy files manually:** upload `server.py`, `requirements-server.txt`, and optionally `.env.local` (or create `.env` in step 5) into a folder, e.g. `/opt/nav-app`.

## 4. Install dependencies and test run

```bash
cd /opt/nav-app   # or your project path
python3 -m venv venv
source venv/bin/activate
pip install -r requirements-server.txt
```

Create the env file (replace with your real values):

```bash
cat > .env << 'EOF'
PORT=8080
LIVEKIT_URL=wss://your-livekit-url
LIVEKIT_API_KEY=your_livekit_api_key
LIVEKIT_API_SECRET=your_livekit_api_secret
GOOGLE_API_KEY=your_google_api_key
EOF
chmod 600 .env
```

Run the server manually to confirm it starts:

```bash
export PORT=8080
python server.py
```

You should see: `Server http://0.0.0.0:8080  GET /token  POST /obstacle-frame`.  
Press Ctrl+C to stop. Then run it under systemd (next step).

## 5. Run the server with systemd (keeps it running)

Create a systemd service:

```bash
sudo nano /etc/systemd/system/nav-server.service
```

Paste this (adjust `WorkingDirectory` if your path is different):

```ini
[Unit]
Description=Nav token + obstacle server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/nav-app
Environment=PORT=8080
EnvironmentFile=/opt/nav-app/.env
ExecStart=/opt/nav-app/venv/bin/python server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

If you didn’t use a venv:

```ini
ExecStart=/usr/bin/python3 server.py
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable nav-server
sudo systemctl start nav-server
sudo systemctl status nav-server
```

## 6. Open port 8080

On the Droplet:

```bash
ufw allow 8080
ufw allow 22
ufw enable
```

In DigitalOcean: **Networking** → **Firewall** → create a rule allowing **Inbound TCP 8080** (and 22 for SSH) if you use a cloud firewall.

## 7. (Optional) HTTPS with Nginx and Let’s Encrypt

For production you want HTTPS. Install Nginx and Certbot:

```bash
apt install -y nginx certbot python3-certbot-nginx
certbot --nginx -d your-domain.com
```

Then add a reverse proxy so Nginx forwards to your server. Create:

```bash
nano /etc/nginx/sites-available/nav-server
```

Add (replace `your-domain.com` and upstream port if different):

```nginx
server {
    listen 80;
    server_name your-domain.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable and reload:

```bash
ln -s /etc/nginx/sites-available/nav-server /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Then run certbot:

```bash
certbot --nginx -d your-domain.com
```

Your server URL will be `https://your-domain.com` (use `https://your-domain.com/token` in the app).

## 8. Use the server in the app

- **If you skipped HTTPS:** In the app set server URL to `http://YOUR_DROPLET_IP:8080/token`.
- **If you set up HTTPS:** Set server URL to `https://your-domain.com/token`.

Obstacle is automatic: the app will call `https://your-domain.com/obstacle-frame` (same host).

## 9. Run the LiveKit agent (voice)

The **agent** (voice assistant) still needs to run somewhere that connects to LiveKit:

- On the **same Droplet**: clone the repo, install full deps (`uv sync` or `pip install` from pyproject), set all env vars (Deepgram, ElevenLabs, LiveKit, etc.), and run `uv run python agent.py dev` in a second systemd service or in `tmux`.
- Or run the agent on your own machine or another server; it only needs to connect to LiveKit and use the same LiveKit project.

## Quick checklist

- [ ] Droplet created, SSH works
- [ ] Project (at least `server.py`, `requirements-server.txt`) on the Droplet
- [ ] `.env` with `PORT`, `LIVEKIT_*`, `GOOGLE_API_KEY`
- [ ] `pip install -r requirements-server.txt` and `python server.py` works
- [ ] `nav-server.service` enabled and started
- [ ] Port 8080 open (and 80/443 if using Nginx)
- [ ] App points to `http://YOUR_IP:8080/token` or `https://your-domain.com/token`
