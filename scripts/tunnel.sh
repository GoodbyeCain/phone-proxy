#!/usr/bin/env bash
# Forwards a local TCP port to the same port on a USB-attached iPhone.
# The port is served by PhoneProxy.app running on the device.
# Find a device UDID with: xcrun devicectl list devices
set -uo pipefail

UDID="${UDID:?set UDID to the target device, e.g. UDID=\$(xcrun devicectl list devices)}"
LOCAL_PORT="${LOCAL_PORT:-${PORT:-1088}}"
DEVICE_PORT="${DEVICE_PORT:-1088}"

while true; do
    echo "[tunnel] iproxy 127.0.0.1:${LOCAL_PORT} -> ${UDID}:${DEVICE_PORT}"
    iproxy -u "${UDID}" "${LOCAL_PORT}:${DEVICE_PORT}"
    echo "[tunnel] iproxy exited, retrying in 2s"
    sleep 2
done
