# The remote build fleet

This project's clients build and verify inside Docker on `linux/amd64`. On an
Apple Silicon Mac that means emulation, and emulation lies: QEMU-backed engines
segfault or OOM heavy toolchains before any client code runs, producing failures
that have nothing to do with the code. A native x86-64 machine settles those
questions, and several machines let verification runs proceed in parallel — one
`verify-all` per host, since they share a backend.

So the project rents a small fleet on demand. **It is not running now.**

## Status: torn down (2026-08-08)

Five servers were deleted after a session took the roster from 57 to 83 verified
languages. They were costing **€1,233.60/month, about €41/day**, and nothing on
them was needed once every branch was pushed.

Note that **powering a Hetzner server off does not stop billing** — only
deletion does. If a future session leaves the fleet idle overnight, delete it.

What the servers held, none of it unique:

- One dedicated git clone per agent, `~/100cc-<agent>`, plus a bare `~/100cc.git`
  that agents pushed to and checked out from.
- Docker images and layer caches — the reason a rebuild is slower than a resume,
  and the only real cost of tearing down.
- Scratch spikes: `~/j-spike` (a proven J → TLS 1.3 → HTTP round trip via
  `15!:0`), `~/rkm-bare-rakudo` (the Raku memory bisection), `~/probe-bcpl`.
  Every finding from those is written up in `INFEASIBLE.md` or `LESSONS.md`; the
  scripts themselves are gone.

## Recreating it

Everything except the servers still exists locally: the API token at
`~/.config/hcloud/convex-fleet-token` (chmod 600), the SSH key
`~/.ssh/id_ed25519_hetzner_agent`, and the `hz1`–`hz5` host aliases in
`~/.ssh/config`. Only the `HostName` lines need updating with new IPs.

The fleet as it was:

| Alias | Name | Type | Cores | Notes |
| --- | --- | --- | --- | --- |
| hz1 | convex-build-1 | cpx51 | 16 | Heaviest builds and the most agents |
| hz2 | convex-build-2 | cpx51 | 16 | |
| hz3 | convex-build-3 | cpx51 | 16 | |
| hz4 | convex-build-4 | cpx41 | 8 | |
| hz5 | convex-build-5 | cpx41 | 8 | |

All `ubuntu-24.04`, all in Hetzner's Ashburn (`ash`) location, chosen for
proximity to the hosted Convex deployment so the hosted profile's TLS round
trips are not dominated by latency. The Hetzner account is capped at 5 servers;
raising that needs a support request.

```bash
export HCLOUD_TOKEN=$(cat ~/.config/hcloud/convex-fleet-token)
SSH_KEY_ID=116620845   # "convex-clients-agent"

create() {  # create <name> <type>
  curl -s -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\",\"server_type\":\"$2\",\"image\":\"ubuntu-24.04\",\"location\":\"ash\",\"ssh_keys\":[$SSH_KEY_ID],\"start_after_create\":true}" \
    https://api.hetzner.cloud/v1/servers |
    python3 -c 'import sys,json;s=json.load(sys.stdin)["server"];print(s["name"],s["public_net"]["ipv4"]["ip"])'
}

for n in 1 2 3; do create "convex-build-$n" cpx51; done
for n in 4 5;   do create "convex-build-$n" cpx41; done
```

Then update the five `HostName` lines in `~/.ssh/config`, and on each host:

```bash
ssh hzN 'apt-get update -qq && apt-get install -y -qq docker.io git rsync && systemctl enable --now docker'
ssh hzN 'git init --bare ~/100cc.git'
git push -f ssh://hzN/~/100cc.git main:refs/heads/main
rsync -a ~/.convex/ hzN:~/.convex/       # hosted-deployment credentials
```

Each agent then clones its own working copy from that host's bare repo. **One
clone per agent** — a shared checkout corrupted an in-flight build early in this
project, because `git checkout -B` in one agent's turn changed the tree Docker
was reading for another's.

## Deleting it again

```bash
HCLOUD_TOKEN=$(cat ~/.config/hcloud/convex-fleet-token) && \
for id in $(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers |
            python3 -c 'import sys,json;[print(s["id"]) for s in json.load(sys.stdin)["servers"]]'); do
  curl -s -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
    https://api.hetzner.cloud/v1/servers/$id >/dev/null && echo "deleted $id"
done
```

Push every branch you care about first. The clones on those hosts are the only
copy of anything an agent has not pushed.
