# Rspamd controller worker configuration
# /etc/rspamd/local.d/worker-controller.inc

# Web UI and management interface
bind_socket = "0.0.0.0:11334";

# Password for web UI (generate with: rspamadm pw)
# Replace with actual hashed password
password = "$2$changeme";

# Enable write access (for learning spam/ham)
enable_password = "$2$changeme";
