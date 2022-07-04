FROM vshn/nginx:1.21.1.2

# Copy scripts
COPY scripts/cleanup.sh /usr/share/nginx/html/cleanup
COPY scripts/lieutenant.sh /usr/share/nginx/html/lieutenant
COPY scripts/commodore.sh /usr/share/nginx/html/commodore
COPY scripts/requirements.sh /usr/share/nginx/html/requirements
COPY scripts/steward.sh /usr/share/nginx/html/steward

# Copy modified Nginx configuration
COPY deployment/nginx.conf /etc/nginx/conf.d/default.conf
