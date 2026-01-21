# Rspamd general options
# /etc/rspamd/local.d/options.inc

# DNS settings
dns {
  nameserver = ["8.8.8.8", "1.1.1.1"];
  timeout = 5s;
  retransmits = 2;
}

# Local networks (trusted)
local_addrs = [
  "127.0.0.0/8",
  "::1",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16"
];
