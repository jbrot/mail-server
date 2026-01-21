# Rspamd proxy worker configuration
# /etc/rspamd/local.d/worker-proxy.inc

# Milter mode for OpenSMTPd filter
bind_socket = "0.0.0.0:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
