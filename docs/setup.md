# Self-hosted GitLab CI/CD on Proxmox: build log and runbook

A home-lab GitLab CE install with a Docker-executor runner and a separate deploy target, all on one Proxmox host. The pipeline (lint, build, test, scan, staging, manual prod) lives in [`.gitlab-ci.yml`](../.gitlab-ci.yml) and [`ci/`](../ci/).

Addresses below are examples on `192.168.50.0/24`. Substitute your own.

| Role | Type | Example IP | Resources |
|---|---|---|---|
| Proxmox host | VirtualBox guest on a desktop | 192.168.50.250 | 12 vCPU / 24 GB |
| `gitlab` (CT 201) | LXC | 192.168.50.251 | 4 vCPU / 8 GB / 50 GB |
| `runner` (CT 202) | LXC | 192.168.50.252 | 2 vCPU / 3 GB / 30 GB |
| `deploy` (CT 203) | LXC | 192.168.50.249 | 2 vCPU / 2 GB / 15 GB |

Gateway `192.168.50.1`, mask `/24`.

## Status
- [x] Proxmox host up, storage and bridge identified
- [x] Cloud-init VM template built (used for the first attempt, see section 3)
- [x] GitLab CE installed (LXC)
- [x] Registry enabled, runner registered, project created, first pipeline run
- [x] `build` job pushing to the registry
- [ ] Deploy target and staging/production deploys

## Design decision: VMs first, then LXC
I first built three VMs from a cloud-init template (section 3). The Proxmox host is itself a VirtualBox guest, so every VM was nested KVM. Under load VirtualBox crashed with guru meditations. I rebuilt all three nodes as unprivileged LXC containers (section 4). They share the Proxmox kernel, so no nested virtualization is needed and memory overhead is much lower. See the troubleshooting section for the full story.

## 1. Inspect the Proxmox host
```sh
pvesm status                 # storage names and free space
ip -br a | grep vmbr         # bridge and host IP
free -m; nproc
ls -l /dev/kvm               # confirms nested KVM works (only matters for VMs)
df -h /                      # root is small: keep big downloads off it
```
The `local` directory storage is the root volume (about 8 GB), so downloads go to RAM (`/dev/shm`) or to the thin pool. The thin pool (`lab-storage` here) holds disks but not files.

For long jobs over a flaky link, use tmux so a dropped SSH session doesn't kill the job:
```sh
apt install -y tmux && tmux new -s lab    # reattach later with: tmux attach -t lab
```

## 2. Networking
Static address for the Proxmox host in `/etc/network/interfaces`:
```
iface vmbr0 inet static
    address 192.168.50.250/24
    gateway 192.168.50.1
    bridge-ports nic0
    bridge-stp off
    bridge-fd 0
```
Proxmox requires the hostname to resolve to its own address. `/etc/hosts` must contain `192.168.50.250 proxmox.example.lab proxmox`. Verify:
```sh
hostname --ip-address
ifreload -a
systemctl restart pve-cluster pvedaemon pveproxy   # only if the web UI misbehaves
```
Before assigning guest addresses, check they are free and not in the router's DHCP pool:
```sh
for i in 249 251 252; do ping -c1 -W1 192.168.50.$i >/dev/null && echo "$i IN USE" || echo "$i free"; done
```

## 3. First attempt: cloud-init VM template (qm)
Kept for reference. It's a fast way to stamp out VMs, and the commands are reusable.

Download the Ubuntu 24.04 cloud image into RAM, import it, and turn it into a template:
```sh
cd /dev/shm
wget -4 -c --timeout=20 --tries=0 \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-2404-tmpl --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --agent enabled=1
qm importdisk 9000 noble-server-cloudimg-amd64.img lab-storage
qm config 9000 | grep unused            # confirm the imported disk name
qm set 9000 --scsi0 lab-storage:vm-9000-disk-0 --boot order=scsi0 \
  --ide2 lab-storage:cloudinit --serial0 socket --vga serial0
qm set 9000 --ciuser labadmin --sshkey ~/.ssh/authorized_keys
qm set 9000 --protection 1
qm template 9000
rm /dev/shm/noble-server-cloudimg-amd64.img
```
Clone, size and start a VM (repeat per node):
```sh
qm clone 9000 101 --name gitlab --full --storage lab-storage
qm set 101 --cores 4 --memory 8192 \
  --ipconfig0 ip=192.168.50.251/24,gw=192.168.50.1 --nameserver 192.168.50.1
qm resize 101 scsi0 50G
qm start 101
```
Useful extras:
```sh
qm terminal 101                    # serial console (exit with Ctrl+O)
qm set 101 --cipassword '<temp>'   # console login fallback
qm set 101 --protection 0          # clones inherit protection=1 from the template
qm stop 101 && qm destroy 101 --purge
```

## 4. Current layout: unprivileged LXC containers (pct)
Fetch an LXC template (about 150 MB, lands on `local`):
```sh
pveam update
pveam available --section system | grep ubuntu-24.04
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```
Create the three containers. `nesting=1,keyctl=1` is what lets Docker run inside an unprivileged LXC.
```sh
pct create 201 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname gitlab --cores 4 --memory 8192 --swap 1024 \
  --rootfs lab-storage:50 --unprivileged 1 --features nesting=1,keyctl=1 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.251/24,gw=192.168.50.1 \
  --nameserver 192.168.50.1 --ssh-public-keys ~/.ssh/authorized_keys --onboot 1

pct create 202 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname runner --cores 2 --memory 3072 --swap 512 \
  --rootfs lab-storage:30 --unprivileged 1 --features nesting=1,keyctl=1 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.252/24,gw=192.168.50.1 \
  --nameserver 192.168.50.1 --ssh-public-keys ~/.ssh/authorized_keys --onboot 1

pct create 203 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname deploy --cores 2 --memory 2048 --swap 512 \
  --rootfs lab-storage:15 --unprivileged 1 --features nesting=1,keyctl=1 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.50.249/24,gw=192.168.50.1 \
  --nameserver 192.168.50.1 --ssh-public-keys ~/.ssh/authorized_keys --onboot 1

pct start 201 && pct start 202 && pct start 203
pct list
```
Name resolution on each container (the Mac's `/etc/hosts` doesn't apply inside them):
```sh
cat >> /etc/hosts <<'EOF'
192.168.50.251 gitlab.lab
192.168.50.252 runner.lab
192.168.50.249 deploy.lab
EOF
```
Docker on `runner` and `deploy`:
```sh
apt update && apt install -y curl
curl -fsSL https://get.docker.com | sh
docker run --rm hello-world
```

## 5. GitLab CE (on `gitlab`)
```sh
apt update && apt install -y curl tmux perl openssh-server ca-certificates tzdata
tmux new -s gl
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
EXTERNAL_URL="http://gitlab.lab" apt install -y gitlab-ce
```
Unprivileged containers can't change kernel parameters. If `reconfigure` fails with sysctl "permission denied", add this to `/etc/gitlab/gitlab.rb` and reconfigure again:
```ruby
package['modify_kernel_parameters'] = false
```
Enable the container registry (also in `gitlab.rb`), then apply:
```ruby
registry_external_url 'http://gitlab.lab:5050'
```
```sh
gitlab-ctl reconfigure
gitlab-ctl status
cat /etc/gitlab/initial_root_password    # deleted after 24 hours
```
Sign in as `root` at `http://gitlab.lab` and change the password.

## 6. Runner (on `runner`)
Create an instance runner in the UI (Admin > CI/CD > Runners): tag `docker`, untagged jobs off. Then:
```sh
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
apt install -y gitlab-runner
gitlab-runner register --url http://gitlab.lab --token <TOKEN> \
  --executor docker --docker-image alpine:3.20 \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock
```
Mounting the Docker socket lets `docker build` run inside jobs without privileged dind. Jobs share the host's daemon, which is acceptable for a single-user lab. Raise `concurrent` in `/etc/gitlab-runner/config.toml` to practice concurrency, and mark the runner protected to limit it to protected branches.

The registry runs on plain HTTP, so on `runner` and `deploy` allow it in `/etc/docker/daemon.json`:
```json
{"insecure-registries": ["gitlab.lab:5050"]}
```
```sh
systemctl restart docker
docker login gitlab.lab:5050
```
TLS for the registry is a stretch goal.

## 7. Deploy target and project
- On `deploy`: Docker installed; create a user in the `docker` group and add the CI public key to its `authorized_keys`.
- In the project (Settings > CI/CD > Variables): `SSH_PRIVATE_KEY` (type File, protected), `STAGING_HOST`, `DEPLOY_USER`.
- Settings > CI/CD > Protected environments: protect `production`, deployers limited to Maintainers.

## 8. Things to try
- Open a merge request: one pipeline runs, deploys are skipped.
- Change only the README: `lint` is skipped (`rules:changes`).
- Break a test and look at the JUnit tab and the coverage badge.
- Roll back by re-running an older `deploy-staging` job from the Environments page.
- Move `ci/jobs.yml` to its own project and switch to `include: project:`.

## Troubleshooting log
| Symptom | Cause | Fix |
|---|---|---|
| SSH sessions time out; "host identification changed"; downloads stall at 97% | Another device on the LAN had the same IP as Proxmox | Moved Proxmox to a free address; fixed `/etc/network/interfaces` and `/etc/hosts`; reserve addresses in the router |
| Same symptoms, repeatedly, after a fix | Consistent with a second duplicate-address conflict; a guest answered ping but refused port 22 | Checked ARP MACs against `qm config`; picked a different, verified-free address |
| VirtualBox guru meditation crashes | Nested KVM guests under load inside a VirtualBox guest | Replaced the VMs with LXC containers |
| `qm clone ... unable to find configuration file for VM 9000` | Template build never completed; the session had dropped | Rebuilt the template in tmux; verify with `qm list` |
| `qm destroy` refused | Clone inherited `protection: 1` from the template | `qm set <id> --protection 0` |
| Interface name commands failed | NIC is renamed to `nic0` at boot | Use `nic0` in `ethtool`/`ip` commands |
| Root volume nearly full | `local` is the 8 GB root filesystem | Download into `/dev/shm`, delete after import |
| Host RAM too small for the guests | Proxmox had 12 GB | Raised VirtualBox base memory to 24 GB |
| Job fails: `Could not resolve host: gitlab.lab` | Job containers don't use the runner host's `/etc/hosts` | `extra_hosts = ["gitlab.lab:<ip>"]` under `[runners.docker]` (real DNS is the better fix) |
| `docker login`: "server gave HTTP response to HTTPS client" | Plain-HTTP registry; the job's Docker needs the registry marked insecure, and the socket mount was missing because `register --docker-volumes` isn't saved with `glrt-` tokens | `insecure-registries` in `daemon.json` plus the Docker socket in `volumes` in `config.toml` |
| `docker push`: "blob unknown to registry" | The runner's Docker uses the containerd image store, which attaches provenance attestation manifests the GitLab registry rejected. Registry storage, disk and plain pushes were fine | `docker build --provenance=false` (confirmed: build job passed) |
| SSH key CI variable rejected ("whitespace") | Masking can't apply to multi-line values; also 8-character minimum for masked values | Type File, Visibility Visible |
| Runner shows offline and jobs sit "pending" after a container restart | Proxmox regenerates `/etc/hosts` in LXCs on start, dropping the `gitlab.lab` entry | `touch /etc/.pve-ignore.hosts` in each container, then re-add the host lines (real DNS is the better fix) |
| Cloud-init VM refused SSH (port 22) | Not resolved; likely an address conflict (see above) | Rebuilt on another address, then moved to LXC |

Settings that mattered for Proxmox inside VirtualBox: Bridged Adapter on the wired NIC, Promiscuous Mode "Allow All", virtio-net.
