FROM vshn/nginx:1.21.1.2

# Copy scripts
COPY *.sh /usr/share/nginx/html/

# Copy modified Nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf
