FROM vshn/nginx:1.21.1.2

# Copy scripts
COPY scripts/*.sh /usr/share/nginx/html/

# Copy modified Nginx configuration
COPY deployment/nginx.conf /etc/nginx/conf.d/default.conf
