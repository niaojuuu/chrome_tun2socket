#!/bin/bash
exec /usr/local/bin/tun2socks \
  --device "$TUN" \
  --proxy "$PROXY_EFFECTIVE" \
  --fwmark "$FWMARK" \
  --loglevel "${LOGLEVEL:-warn}"
