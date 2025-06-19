mkdir -p /etc/nginx/conf.d /etc/nginx/modules && 
for encoded_file in /custom-nginx/*.b64; do
  if [ -f "$encoded_file" ]; then
    dest_file="/etc/nginx/$(basename "$encoded_file" .b64)"
    echo "Decoding: $(basename "$encoded_file") -> $(basename "$dest_file")"
    base64 -d "$encoded_file" > "$dest_file"
  fi
done &&

# Copy standard configuration files
for conf_file in /custom-nginx/*.conf; do
  if [ -f "$conf_file" ]; then
    cp "$conf_file" /etc/nginx/
  fi
done &&

# Copy configuration files in conf.d directory
for file in /custom-nginx/conf.d/*.conf; do
  if [ -f "$file" ]; then
    cp "$file" /etc/nginx/conf.d/
  fi
done &&

# Copy mime.types file
if [ -f "/custom-nginx/mime.types" ]; then
  cp "/custom-nginx/mime.types" /etc/nginx/mime.types
fi &&

# Copy modules if the directory exists and is not empty
if [ -d "/custom-nginx/modules" ] && [ "$(ls -A /custom-nginx/modules)" ]; then
  cp /custom-nginx/modules/* /etc/nginx/modules/ 2>/dev/null || true
fi &&

echo "Configuration is complete. Starting Nginx..." &&
nginx -g "daemon off;"