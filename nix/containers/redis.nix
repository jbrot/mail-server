# Redis container for rspamd backend
# nix/containers/redis.nix

{ pkgs
, lib ? pkgs.lib
}:

let
  # Redis package
  redis = pkgs.redis;

  # Create a minimal passwd file
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    redis:x:1000:1000:Redis:/var/lib/redis:/bin/false
    nobody:x:65534:65534:Nobody:/var/empty:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    redis:x:1000:
    nobody:x:65534:
  '';

  # Redis configuration for rspamd
  redisConf = pkgs.writeText "redis.conf" ''
    # Redis configuration for rspamd backend

    # Bind to all interfaces (container networking)
    bind 0.0.0.0

    # Default port
    port 6379

    # Persistence directory
    dir /data/redis

    # AOF persistence (recommended for rspamd)
    appendonly yes
    appendfilename "appendonly.aof"
    appendfsync everysec

    # RDB snapshots (backup)
    save 900 1
    save 300 10
    save 60 10000
    dbfilename dump.rdb

    # Memory management
    maxmemory-policy volatile-lru

    # Logging
    loglevel notice
    logfile ""

    # Disable protected mode for container use
    protected-mode no

    # Run as redis user
    # (handled by entrypoint)
  '';

  # Entrypoint script
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

    # Create required directories
    mkdir -p /data/redis
    mkdir -p /var/lib/redis
    mkdir -p /var/run/redis

    # Set permissions
    chown -R redis:redis /data/redis
    chown -R redis:redis /var/lib/redis
    chown -R redis:redis /var/run/redis

    echo "Starting Redis..."
    exec ${redis}/bin/redis-server /etc/redis/redis.conf --user redis
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "redis";
  tag = "latest";

  contents = [
    redis
    entrypoint
    pkgs.coreutils
    pkgs.bash
  ];

  extraCommands = ''
    # Create directory structure
    mkdir -p data/redis
    mkdir -p var/lib/redis
    mkdir -p var/run/redis
    mkdir -p etc/redis
    mkdir -p tmp

    # Copy redis configuration
    cp ${redisConf} etc/redis/redis.conf

    # Copy passwd and group files
    cp ${passwdFile} etc/passwd
    cp ${groupFile} etc/group

    # Create nsswitch.conf
    echo "passwd: files" > etc/nsswitch.conf
    echo "group: files" >> etc/nsswitch.conf
    echo "hosts: files dns" >> etc/nsswitch.conf
  '';

  config = {
    Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
    ExposedPorts = {
      "6379/tcp" = {};
    };
    Volumes = {
      "/data/redis" = {};
    };
    Labels = {
      "org.opencontainers.image.title" = "Redis";
      "org.opencontainers.image.description" = "Minimal Redis container for rspamd backend built with Nix";
    };
  };
}
