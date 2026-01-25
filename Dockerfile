FROM dunglas/frankenphp:latest

# Set working directory
WORKDIR /var/www/html

# Install dependencies for WordPress
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Download latest WordPress
RUN wget -q https://wordpress.org/latest.tar.gz && \
    tar -xzf latest.tar.gz --strip-components=1 && \
    rm latest.tar.gz

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html

# Expose port 80 (internal, cloudflared will proxy)
EXPOSE 80

# Use entrypoint script
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--public", "/var/www/html"]