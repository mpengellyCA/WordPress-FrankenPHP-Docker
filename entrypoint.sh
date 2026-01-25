#!/bin/bash
set -e

# Create wp-config.php on every boot (from env)
if [ -n "$WORDPRESS_DB_NAME" ]; then
    echo "Creating wp-config.php..."
    
    # Download wp-config-sample.php if needed
    if [ ! -f /var/www/html/wp-config-sample.php ]; then
        echo "wp-config-sample.php not found, WordPress may not be properly installed"
        exit 1
    fi
    
    # Copy sample config
    cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
    
    # Set database configuration
    sed -i "s/database_name_here/${WORDPRESS_DB_NAME}/g" /var/www/html/wp-config.php
    sed -i "s/username_here/${WORDPRESS_DB_USER}/g" /var/www/html/wp-config.php
    sed -i "s/password_here/${WORDPRESS_DB_PASSWORD}/g" /var/www/html/wp-config.php
    sed -i "s/localhost/${WORDPRESS_DB_HOST}:${WORDPRESS_DB_PORT:-3306}/g" /var/www/html/wp-config.php
    
    # Set authentication keys and salts if provided
    if [ -n "$WORDPRESS_AUTH_KEY" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_AUTH_KEY}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_SECURE_AUTH_KEY" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_SECURE_AUTH_KEY}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_LOGGED_IN_KEY" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_LOGGED_IN_KEY}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_NONCE_KEY" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_NONCE_KEY}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_AUTH_SALT" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_AUTH_SALT}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_SECURE_AUTH_SALT" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_SECURE_AUTH_SALT}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_LOGGED_IN_SALT" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_LOGGED_IN_SALT}/g" /var/www/html/wp-config.php
    fi
    if [ -n "$WORDPRESS_NONCE_SALT" ]; then
        sed -i "s/put your unique phrase here/${WORDPRESS_NONCE_SALT}/g" /var/www/html/wp-config.php
    fi
    
    # Set table prefix if provided
    if [ -n "$WORDPRESS_TABLE_PREFIX" ]; then
        sed -i "s/\$table_prefix = 'wp_';/\$table_prefix = '${WORDPRESS_TABLE_PREFIX}';/g" /var/www/html/wp-config.php
    fi
    
    # Set WordPress URL if provided
    if [ -n "$WORDPRESS_URL" ]; then
        echo "define('WP_HOME','${WORDPRESS_URL}');" >> /var/www/html/wp-config.php
        echo "define('WP_SITEURL','${WORDPRESS_URL}');" >> /var/www/html/wp-config.php
    fi
    
    # Set file permissions
    chown www-data:www-data /var/www/html/wp-config.php
    chmod 644 /var/www/html/wp-config.php
    
    echo "wp-config.php created successfully"
fi

# Wait for database to be ready
if [ -n "$WORDPRESS_DB_HOST" ]; then
    echo "Waiting for database connection..."
    until php -r "new PDO('mysql:host=${WORDPRESS_DB_HOST};port=${WORDPRESS_DB_PORT:-3306}', '${WORDPRESS_DB_USER}', '${WORDPRESS_DB_PASSWORD}');" 2>/dev/null; do
        echo "Database is unavailable - sleeping"
        sleep 2
    done
    echo "Database is ready!"
fi

# Ensure WordPress correctly detects HTTPS when behind a reverse proxy (e.g., Cloudflare Tunnel).
# This prevents wp-admin redirect loops when the origin connection is HTTP but the client connection is HTTPS.
if [ -f /var/www/html/wp-config.php ]; then
    if ! grep -q "WP_PROXY_HTTPS_FIX" /var/www/html/wp-config.php; then
        echo "Injecting reverse-proxy HTTPS fix into wp-config.php..."
        tmpfile="$(mktemp)"
        awk '
            BEGIN { inserted=0 }
            # Insert before the canonical "stop editing" marker if present
            /\/\* That\x27s all, stop editing! Happy publishing\. \*\// && inserted==0 {
                print ""
                print "// WP_PROXY_HTTPS_FIX: reverse proxy / Cloudflare Tunnel HTTPS detection"
                print "if ("
                print "    (!empty($_SERVER[\"HTTP_X_FORWARDED_PROTO\"]) && $_SERVER[\"HTTP_X_FORWARDED_PROTO\"] === \"https\") ||"
                print "    (!empty($_SERVER[\"HTTP_CF_VISITOR\"]) && strpos($_SERVER[\"HTTP_CF_VISITOR\"], \"\\\"https\\\"\") !== false)"
                print ") {"
                print "    $_SERVER[\"HTTPS\"] = \"on\";"
                print "    $_SERVER[\"SERVER_PORT\"] = 443;"
                print "}"
                print ""
                print "if (!defined(\"FORCE_SSL_ADMIN\")) define(\"FORCE_SSL_ADMIN\", true);"
                print ""
                inserted=1
            }
            { print }
            END {
                if (inserted==0) {
                    print ""
                    print "// WP_PROXY_HTTPS_FIX: reverse proxy / Cloudflare Tunnel HTTPS detection"
                    print "if ("
                    print "    (!empty($_SERVER[\"HTTP_X_FORWARDED_PROTO\"]) && $_SERVER[\"HTTP_X_FORWARDED_PROTO\"] === \"https\") ||"
                    print "    (!empty($_SERVER[\"HTTP_CF_VISITOR\"]) && strpos($_SERVER[\"HTTP_CF_VISITOR\"], \"\\\"https\\\"\") !== false)"
                    print ") {"
                    print "    $_SERVER[\"HTTPS\"] = \"on\";"
                    print "    $_SERVER[\"SERVER_PORT\"] = 443;"
                    print "}"
                    print ""
                    print "if (!defined(\"FORCE_SSL_ADMIN\")) define(\"FORCE_SSL_ADMIN\", true);"
                    print ""
                }
            }
        ' /var/www/html/wp-config.php > "$tmpfile"
        cat "$tmpfile" > /var/www/html/wp-config.php
        rm -f "$tmpfile"
    fi
fi

# Set proper permissions
chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# Execute the main command
exec "$@"
