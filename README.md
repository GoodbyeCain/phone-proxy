# PhoneProxy

Relay selected Mac traffic through a USB-attached iPhone, so Mac apps can reach
hosts that only the phone can see: carrier-scoped endpoints, cellular-only APIs,
or a private tailnet the phone has joined.

## Architecture

```
Mac app
  |  HTTP CONNECT / SOCKS5
  v
127.0.0.1:<LOCAL_PORT>
  |  usbmuxd / iproxy over USB
  v
iPhone:<DEVICE_PORT>
  |
  v
PhoneProxy.app dials the destination through the phone's network stack
(Wi-Fi / cellular / VPN)
```

- `PhoneProxy.app` is an HTTP CONNECT + SOCKS5 server (no authentication) that
  listens on the device and dials the requested destination itself.
- `iproxy` (usbmuxd) exposes that device port as a local TCP port over USB.
- The phone performs the dial, so name resolution and egress happen on the
  device. Use `socks5h://` (remote resolution) or HTTP CONNECT to keep the name
  on the phone; a plain `socks5://` client resolves on the Mac instead.
- The app is an ordinary TCP client from the system's point of view. It does not
  take the VPN slot, so a VPN client on the phone (Tailscale, for example) keeps
  running and its routes become reachable from the Mac.

## Requirements

- macOS with Xcode and a signing team
- `xcodegen` for project generation, `libusbmuxd` for `iproxy`

```bash
brew install xcodegen libusbmuxd
```

## Build and install

```bash
xcrun devicectl list devices                      # find the UDID
UDID=<device-udid>

xcodegen generate
xcodebuild -project PhoneProxy.xcodeproj -scheme PhoneProxy \
  -configuration Debug -destination "id=$UDID" \
  -derivedDataPath /tmp/pp-build \
  DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates build

xcrun devicectl device install app --device "$UDID" \
  /tmp/pp-build/Build/Products/Debug-iphoneos/PhoneProxy.app

xcrun devicectl device process launch --console --device "$UDID" com.saycain.phoneproxy
```

`--console` streams the app's log, which is also rendered on screen. Keep the app
in the foreground when it matters: it holds `UIBackgroundModes: audio` and keeps a
silent audio session alive (`AudioKeeper`) to survive backgrounding, but iOS
eventually suspends it.

## Tunnel

```bash
UDID=<device-udid> LOCAL_PORT=1088 ./scripts/tunnel.sh
```

- `UDID` device to attach to, `LOCAL_PORT` local port (default `1088`),
  `DEVICE_PORT` device port (default `1088`).
- The script re-dials whenever the USB link drops. Run it in a terminal that
  stays alive: `iproxy` dies with its parent shell.
- Run one tunnel per device. Give each device a distinct `LOCAL_PORT` so several
  phones can be selected between.
- `iproxy` has no bind option and listens on every interface (`*:<LOCAL_PORT>`),
  not on loopback only. While the tunnel runs, any host on the same network can
  reach it, so deny incoming connections for `iproxy` in the macOS firewall, or
  only run the tunnel on networks you trust.

## Verify

```bash
PORT=1088 TARGET=example.com ./scripts/verify.sh
```

The script prints the Mac's own egress IP, then the target through the phone over
HTTP CONNECT and SOCKS5, then the egress IP as seen from the phone. Manual check:

```bash
curl -x http://127.0.0.1:1088 -sS https://myip.ipip.net
curl -x socks5h://127.0.0.1:1088 -sS -o /dev/null -w '%{http_code}\n' https://example.com/
```

An HTTP `200 Connection Established` only proves the tunnel accepted the request;
it does not prove the phone could dial the destination. Verify against a host you
know the phone can reach, and compare the reported egress IP with the Mac's.

## Routing only selected domains

Exposing the tunnel to every app is rarely what you want. To send one domain
through the phone while everything else keeps its normal path, add an HTTP
outbound pointing at `127.0.0.1:<LOCAL_PORT>` and a matching rule in Clash Verge.
The full procedure, including the rule-mode and rule-order pitfalls, is in
`.agents/skills/clash-verge-phone-routing/SKILL.md`.

Outline:

1. Add an outbound `type: http`, `server: 127.0.0.1`, `port: <LOCAL_PORT>`.
2. Add a select group that contains that outbound.
3. Add `DOMAIN-SUFFIX,<domain>,<group>` above the subscription's own rules.

Rules only apply in rule mode; in direct or global mode the rule list is bypassed
and the domain resolves on the Mac, where phone-only names do not resolve.

## Device permissions

- Local network access must be granted on first launch.
- iOS 26 and later also gate outbound traffic behind a cellular-data permission
  (shown as wireless data in the Settings entry for the app). Until it is
  answered, app sockets fail with `ENODEV` / `ENETDOWN`.
- Reinstalling the app can reset both prompts, so expect them again after an
  install.

## Troubleshooting

- Connection accepted, then closed immediately: the app is suspended or was
  killed. Relaunch it and keep it in the foreground.
- `ENODEV` / `ENETDOWN` from the device: pending Local Network or cellular-data
  permission.
- A phone-only name fails fast (well under a second): the phone could not resolve
  it. Check that the resolving VPN client is active on the device and that the
  name is served by it; a name with no public record fails on any other device.
- Works on Wi-Fi but not on cellular: cellular-data permission is missing.
- Tunnel port not listening: `iproxy` exited with its shell. Restart
  `scripts/tunnel.sh` and confirm the UDID.

## Limitations

- Neither side authenticates or terminates TLS: the app listens on every
  interface of the device and `iproxy` listens on every interface of the Mac.
  Treat the tunnel as network-visible while it runs and gate it with a firewall.
- TCP only. HTTP CONNECT and SOCKS5 `CONNECT` are supported; SOCKS5 `UDP
  ASSOCIATE` is rejected.
- One connection per TCP session, no multiplexing; intended for personal use,
  not as a general-purpose proxy.
- The destination hostname is resolved by the phone, so per-host routing must be
  expressed on the Mac side (Clash rule) or by the phone's own routing table.
