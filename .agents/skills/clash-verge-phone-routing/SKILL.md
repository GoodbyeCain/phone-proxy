---
name: clash-verge-phone-routing
description: Route selected domains out through a phone-attached proxy by editing Clash Verge profile enhancement layers, and diagnose hosts that fail only in rule mode. Use when asked to send a domain, host, or app traffic through a USB-attached iPhone, or when a host works in direct mode but is blocked under rules.
---

# Clash Verge Phone Routing

Send chosen domains through a proxy that lives on a phone (see this repository's
`README.md` and `scripts/tunnel.sh`: iPhone app plus an `iproxy` tunnel exposing
`127.0.0.1:<LOCAL_PORT>`), while everything else keeps its normal path.

## Model

- Clash Verge's runtime config `clash-verge.yaml` is a build artifact. Editing it
  works until the next profile activation, then the edit is regenerated away.
  Change the source, not the artifact.
- The source is the profile's enhancement layers in
  `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/`,
  wired up per profile in `profiles.yaml` (`option.merge` / `option.script` /
  `option.rules` / `option.proxies` / `option.groups`).
- Each enhancement file takes `prepend`, `append`, and `delete`. `prepend` wins
  every conflict, and rules are first-match-wins, so a prepended rule shadows all
  subscription rules below it.
- Rules are evaluated only in rule mode. In direct or global mode the rule list is
  bypassed entirely, and names resolve on the Mac instead of the phone.

## Before Editing

1. Back up the profile directory: `cp -R profiles profiles.bak.$(date +%s)`.
2. Confirm the tunnel is listening: `lsof -nP -iTCP:<LOCAL_PORT> -sTCP:LISTEN`.
3. Map profile to layers by reading `profiles.yaml`: `current:` selects the
   profile, and that profile's `option` block names each layer file.
4. Use one outbound name per device (`PHONE-A`, `PHONE-B`) and a distinct
   `LOCAL_PORT` per device, so a group can select between phones.

## Procedure

### 1. Outbound (proxies layer)

```yaml
append:
  - name: PHONE-A
    type: http
    server: 127.0.0.1
    port: 1088
```

`type: http` is preferred: the CONNECT request carries the hostname, so the phone
resolves the name and its DNS/routing applies. Keep the name stable; rules and
groups reference it.

### 2. Selection group (groups layer)

```yaml
prepend:
  - name: PHONE
    type: select
    proxies:
      - PHONE-A
      - PHONE-B
      - DIRECT
```

The first entry is the default until something is selected and persisted.

### 3. Rule (rules layer)

```yaml
prepend:
  - DOMAIN-SUFFIX,example.internal,PHONE
```

Forms: `DOMAIN` for one host, `DOMAIN-SUFFIX` for a domain and its subdomains,
`DOMAIN-KEYWORD` only when no narrower form fits. Prefer the narrowest form; the
rule must sit above every subscription rule that could also match the host.
The policy field must reproduce the group or outbound name exactly, emoji
included; a typo makes the rule unresolvable and the core rejects the config.

## Apply

The running core keeps its loaded rule set in memory. Editing files does nothing
until the profile is activated from the GUI or the core reloads, so reload and
verify explicitly:

```bash
SOCK="${SOCK:-/tmp/verge/verge-mihomo.sock}"
AUTH="Authorization: Bearer <secret from clash-verge.yaml>"
CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"

curl -s --unix-socket "$SOCK" -H "$AUTH" http://localhost/configs   # current mode/ports

curl -s --unix-socket "$SOCK" -X PUT "http://localhost/configs?force=true" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"path\":\"$CFG\"}" -w 'reload=%{http_code}\n'

curl -s --unix-socket "$SOCK" -X PATCH http://localhost/configs \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"mode":"rule"}' -w 'mode=%{http_code}\n'
```

A reload is a whole-config reload, not a rule-only reload: it re-applies the
file's `mode:` (often `global`), `allow-lan`, and DNS settings, so re-set the mode
afterwards and confirm what you left behind with `GET /configs`.

## Verify

```bash
# the host now matches your rule, at index 0..n of the loaded set
curl -s --unix-socket "$SOCK" -H "$AUTH" http://localhost/rules |
  python3 -c 'import json,sys; r=json.load(sys.stdin)["rules"]; [print(x["index"],x["type"],x["payload"],"->",x["proxy"]) for x in r[:3]]'

# which member the group resolves to
curl -s --unix-socket "$SOCK" -H "$AUTH" "http://localhost/proxies" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["proxies"]["PHONE"]["now"])'

# functional test through the Mac mixed port, and prove the egress changed
curl -x http://127.0.0.1:7897 -sS -o /dev/null -w '%{http_code}\n' https://example.internal/
curl -x http://127.0.0.1:7897 -sS https://myip.ipip.net    # must differ from the Mac's own IP
```

The core log line is the ground truth for rule evaluation:
`match Domain(host) using PHONE[PHONE-A]`. `GET /rules` also exposes
`extra.hitCount` per rule, which shows whether traffic actually landed there.

Also spot-check that unrelated hosts still behave as before, so a rule was added
rather than a reject path removed.

## Pitfall: A Subscription Rule Hijacks The Host

Symptom: the host is fine in direct mode and fails in rule mode with
`SSL_ERROR_SYSCALL`, `code=000`, or an immediate reset.

Cause: the subscription's ad-block section contains a suffix rule for a parent
domain, such as `DOMAIN-SUFFIX,shouji.360.cn,🛑 全球拦截`, and the target
`aiapi.shouji.360.cn` is a subdomain of it. The block is a REJECT, so the failure
looks like a network fault, not a policy decision.

Diagnose before changing anything:

```bash
CFG="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
rg -n "shouji\.360\.cn" "$CFG"      # find candidate rules inside the artifact
```

Then confirm which rule the core actually matched (log line, or `hitCount` in
`GET /rules`) instead of assuming the first candidate you found.

Fix, narrowest first:

- Prepend a more specific rule for the host (`DOMAIN,host,DIRECT` or the phone
  group). First match wins, so the rest of the list is untouched. This survives
  subscription updates because the enhancement layer is re-applied on activation.
- Use `delete: ["DOMAIN-SUFFIX,parent,🛑 全球拦截"]` only when the whole suffix
  should be reachable. Wider blast radius: it unblocks every host under it.

Do not delete the reject behavior itself; `🛑 全球拦截` serves the rest of the ad
list.

Choose the target by intent: a hard whitelist uses the literal policy `DIRECT`, so
it cannot be repointed by a group selection later. A group target is better when
the user should be able to switch the path.

## Notes

- `profile.store-selected: true` persists group selections in the core's
  `cache.db` (`-d` directory), so a fresh instance defaults to the first group
  member and a long-lived one keeps the user's pick.
- Names reachable only from the phone usually have no public DNS record. With
  fake-ip enabled, the Mac's `dig` answers fake addresses, so a local `dig` proves
  nothing; test end-to-end through the proxy port instead.
- The Mac resolves and reaches phone-only names only while the rule is active. In
  direct mode such a host fails on the Mac no matter what the files say.
