# Rspamd logging configuration
# /etc/rspamd/local.d/logging.inc

# Log to stderr (for container logging)
type = "console";
level = "info";

# Log format
log_format = "[%t] <%p> %m";
