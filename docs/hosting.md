# Hosting the server

The logger in your jobs and the app on your phone both need to reach the
server, so for everyday use it runs somewhere public, always on, with HTTPS.
This guide sets it up on each of the usual places:

- [Heroku](#heroku): the least work. This repository is ready for it.
- [Oracle Cloud](#oracle-cloud): free with no end date.
- [Azure](#azure): free while you're a student.
- [AWS](#aws) and [Google Cloud](#google-cloud).
- [Your own computer](#your-own-computer).

The server is the same everywhere: one small Python process (about 1 CPU and
1 GB of memory is plenty) with a database. To try Soliton first, run it on
your computer ([Getting started](getting-started.md#2-have-a-server)) or as
a job on Sherlock ([Sherlock guide](sherlock.md#a-server-on-sherlock-for-testing)).

## Which one

Prices and offers as of November 2026. They change, so check them before
you sign up.

| | Cost | Setup | Upkeep | Database | Catch |
|---|---|---|---|---|---|
| **Heroku** | ~$12 a month (a Basic dyno and the smallest Postgres); the GitHub Student Pack's $13 a month covers it for 24 months | ~15 minutes, no Linux | None: `git push`, or deploys on every push to GitHub | PostgreSQL | Restarts once a day (live views reconnect); the credit ends |
| **Oracle Cloud** | $0, Always Free | ~1 hour: a VM, Caddy, a domain | OS updates (automatic) | SQLite | A card at sign-up; idle free VMs can be reclaimed; free VMs are sometimes out of stock |
| **Azure** | $0 with Azure for Students: free VM hours, plus about $5–7 a month for the IP and disk from the $100 a year credit | ~1 hour, as Oracle | As Oracle | SQLite | Renew the offer every year; the free sizes have 1 GB of memory |
| **AWS** | ~$10–16 a month (t4g.micro or t4g.small, plus $3.65 for the IP), or new-account credits for 6 months | ~1 hour, as Oracle | As Oracle | SQLite | Not free for long |
| **Google Cloud** | $0 for one e2-micro VM (Always Free, in three US regions) | ~1 hour, as Oracle | As Oracle | SQLite | A small VM (1 GB, a fraction of a CPU); a card at sign-up |
| **Your own computer** | $0 | Firewall settings, a domain, Caddy | As a VM, and it must stay on | SQLite | Reachable only while it's awake and on that network |

**For a Stanford student:** Heroku with the student credit if you'd rather
not run a server, or Oracle if you want it free with no end date. Both work
with Sherlock jobs and the app. Stanford's own options are covered under
[Your own computer](#your-own-computer) (housing) and [AWS](#aws)
(Cardinal Cloud).

Whatever you pick:

- **Keep the token secret.** Every request carries it, so use HTTPS on
  anything reachable from the internet. All the setups below do.
- **Run one server process**, not several: live updates are pushed from
  memory, so a second process wouldn't see the first one's changes.
- **Back it up**, off the machine it runs on ([Backups](#backups)).

---

## Heroku

Heroku runs the server for you: you push the code, and it builds and starts
it, gives it an HTTPS address, restarts it if it crashes and keeps the
operating system patched. The repository has what Heroku needs:

- **`Procfile`**: how the server starts (`soliton-server --host 0.0.0.0`; it
  listens on the port Heroku gives it in `PORT`).
- **`pyproject.toml` and `uv.lock`**: Heroku installs the server and its
  PostgreSQL driver from them with uv (only the server: the app's files are
  left out by `.slugignore`).
- **`.python-version`**: the Python version (3.12).

Heroku's disk is wiped at every restart (at least once a day, and on every
deploy), so the runs live in Heroku Postgres, a database next to it. The
server finds it in `DATABASE_URL`, which Heroku sets.

### Costs

A **Basic dyno** (the server, always on, $7 a month) and **Essential-0
Postgres** (1 GB, $5 a month) come to $12 a month. With the
[GitHub Student Developer Pack](https://education.github.com/pack), Heroku
gives $13 a month for 24 months: claim it at
[heroku.com/github-students](https://www.heroku.com/github-students/). The
cheaper Eco dyno ($5) sleeps after 30 minutes without requests, so a job
starting at night would wait for it to wake up: use Basic.

### Set it up

1. **An account**: sign up at [heroku.com](https://www.heroku.com) and claim
   the student offer. Without it, add a card (Heroku may ask for one to
   verify the account either way).
2. **The Heroku CLI** ([install](https://devcenter.heroku.com/articles/heroku-cli),
   e.g. `brew install heroku/brew/heroku` on a Mac), then log in:

   ```bash
   heroku login
   ```

3. **The app, its database and its token**, from the root of this repository
   (`heroku create` also adds a `heroku` git remote):

   ```bash
   heroku create soliton-yourname
   heroku addons:create heroku-postgresql:essential-0
   heroku config:set SOLITON_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
   ```

   Set the token yourself: without it, the server would make one on its
   disk, and lose it at the next restart.

4. **Deploy**, then make the dyno Basic:

   ```bash
   git push heroku main
   heroku ps:type web=basic
   ```

5. **Its address and token**:

   ```bash
   heroku apps:info            # "Web URL": https://soliton-yourname-<letters>.herokuapp.com/
   heroku config:get SOLITON_TOKEN
   ```

6. **Connect**: in the app, **Settings → Server**, with that address and
   token. On each machine that runs jobs, `soliton setup --server <that address>`
   ([Getting started](getting-started.md#by-hand)); for clusters, give it a
   job token from the app (Settings → Advanced security) rather than the
   main one.

`heroku logs --tail` shows the server's output. Its startup line warns
"plain http on a shared network": that's expected on Heroku, where Heroku
itself handles HTTPS in front of it.

### Deploy on every push

In the Heroku dashboard, your app → **Deploy** → **GitHub**: connect the
repository, then **Enable Automatic Deploys** from `main`. **Wait for CI to
pass before deploy** holds back a push whose GitHub checks fail, so a broken
push doesn't replace a working server; it only helps once the repository
runs its tests on GitHub (today its only workflow builds releases). From
then on, every push to `main`
updates the server (a push that changes only the app redeploys it too, which
is harmless).

### Good to know

- **Daily restarts.** Heroku restarts the server about once a day. Nothing
  stored is lost; the app's live view reconnects. The logger saves
  everything locally before uploading, so a job that reports during the
  restart sends it afterwards (or `soliton sync` does).
- **Backups**: Heroku keeps its own backups of the database, and
  `heroku pg:backups:capture` then `heroku pg:backups:download` saves a copy
  on your computer. The app's backup button is for SQLite; it points to
  `pg_dump` here (see the [server README](../server/README.md#backups)).
- **One dyno.** Don't scale the web dyno above 1 (see above).
- **Moving from another server**: runs in an existing SQLite database don't
  move by themselves. Start fresh, or send runs again with `soliton sync` on
  their run folders.
- **Updating** without automatic deploys: `git pull`, then
  `git push heroku main`.

---

## A virtual machine (Oracle, Azure, AWS, Google Cloud)

On a VM you rent a whole Linux computer and run the server yourself: free
or cheap, and it keeps using SQLite on the VM's disk, so the app's backup
button works. Each provider differs only in how you create the VM; then the
[same steps](#on-the-vm-the-same-everywhere) set up the server.

What you need besides the VM:

- **A domain name**, for HTTPS: certificates are given for names, not bare
  IP addresses. The GitHub Student Pack has a free one for a year
  (Namecheap's `.me`, Name.com, `.tech`), or about $10–15 a year from any
  registrar. You'll add one DNS record pointing a name such as
  `soliton.example.dev` at the VM.
- **An SSH key** (`ssh-keygen -t ed25519` on your computer if you don't have
  one), to log in to the VM.

### Oracle Cloud

[Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
gives Arm VMs with up to 2 CPUs and 12 GB of memory in all, 200 GB of disk
and 10 TB a month of traffic out, with no end date.

1. **Sign up** at [cloud.oracle.com](https://cloud.oracle.com). A card is
   needed to verify you, not charged. Pick your **home region** carefully
   (e.g. US West (San Jose) for California): it can't be changed, and the
   free disks are only there.
2. **Create the VM**: Compute → Instances → Create instance.
   - Image: **Canonical Ubuntu 24.04**.
   - Shape: **Ampere → VM.Standard.A1.Flex**, 1 OCPU and 6 GB of memory
     (marked "Always Free-eligible").
   - Networking: a public subnet, with a public IPv4 address.
   - SSH keys: paste your public key (`~/.ssh/id_ed25519.pub`).

   "Out of host capacity" means no free Arm VMs are left there right now:
   try another availability domain, or again later.
3. **Open ports 80 and 443** in two places. In the console: the VM's subnet
   → its security list → Add ingress rules, source `0.0.0.0/0`, TCP,
   destination ports `80` and `443`. On the VM itself, Oracle's Ubuntu
   image has its own firewall that blocks everything but SSH (after logging
   in, below):

   ```bash
   sudo iptables -I INPUT -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
   sudo netfilter-persistent save
   ```

4. **Keep it from being reclaimed.** Oracle reclaims free VMs that stay
   idle (under 20% CPU, network and memory use) for 7 days, and a Soliton
   server is idle most of the time. Upgrading the account to **Pay As You
   Go** (Billing → Upgrade) avoids that, and the free resources stay free.
   Then add a budget with an alert at $1 (Billing → Budgets), so anything
   outside the free tier is noticed at once.

The username is `ubuntu`. Then: [On the VM](#on-the-vm-the-same-everywhere).

### Azure

[Azure for Students](https://azure.microsoft.com/en-us/free/students)
(no card; also in the GitHub Student Pack) gives $100 of credit a year,
renewed each year you're a student by signing up again, and 750 hours a
month of the B1s, B2pts v2 and B2ats v2 VM sizes. One VM all month is about
730 hours, so the VM itself is free; its public IP (~$3.65 a month) and disk
come out of the credit. Microsoft's pages differ on whether the free hours
last 12 months or longer.

1. **Activate Azure for Students** with your school email.
2. **Create the VM**: Virtual machines → Create.
   - Image: **Ubuntu Server 24.04 LTS** (the Arm64 one for B2pts v2).
   - Size: **B2pts v2** (Arm) or **B2ats v2**; if they're refused for
     quota, **B1s**.
   - Authentication: SSH public key. Inbound ports: SSH (22), HTTP (80),
     HTTPS (443).
   - Disk: check which disk type the free hours require when you create it
     (one Microsoft page names a 64 GB Premium SSD, P6).
   - Networking: a public IP, set to **Static** so it doesn't change.
3. **Add a budget alert** (Cost Management → Budgets). If the credit runs
   out before the year does, the subscription is cancelled and the VM
   stops, unless you switch to pay-as-you-go.

The username is the one you chose (default `azureuser`). Then:
[On the VM](#on-the-vm-the-same-everywhere).

### AWS

New AWS accounts get $100 of credit (and up to $100 more) for 6 months;
after that you pay. A **t4g.micro** (Arm, 2 CPUs, 1 GB) costs about $6 a
month and a **t4g.small** (2 GB) about $12, plus $3.65 a month for a public
IPv4 address and a little for the disk (us-east-1 prices).

**At Stanford:** cloud accounts used for Stanford work should go through
[Cardinal Cloud](https://uit.stanford.edu/cardinal-cloud) (AWS, Google
Cloud or Azure at Stanford's discounted rates, billed to a PTA, usually your
PI's). Ask your PI if the project should pay for it.

1. **Launch an instance** (EC2 → Launch instance): **Ubuntu Server 24.04,
   64-bit (Arm)**, type **t4g.micro** or **t4g.small**, your key pair, and a
   security group allowing SSH (22) from your IP and HTTP (80) and HTTPS
   (443) from anywhere. 20 GB of gp3 disk is plenty.
2. **Give it a fixed address**: Elastic IPs → Allocate → Associate it with
   the instance, so the address survives a stop and start.
3. **Set a budget alert** (Billing → Budgets).

The username is `ubuntu`. Then: [On the VM](#on-the-vm-the-same-everywhere).

### Google Cloud

Google's Always Free tier includes one **e2-micro** VM (a fraction of a CPU,
bursting higher, and 1 GB of memory) with 30 GB of standard disk, in
**us-west1, us-central1 or us-east1**. That's enough for the Soliton server.
New accounts also get about $300 of credit for 90 days. A card is needed.
Use a personal Google account: Stanford's Google Cloud goes through Cardinal
Cloud and is billed to a PTA.

1. **Create a project** with billing enabled, then Compute Engine → VM
   instances → Create instance.
   - Region **us-west1** (or us-central1, us-east1), machine type
     **e2-micro**.
   - Boot disk: **Ubuntu 24.04 LTS**, **Standard persistent disk**, 30 GB
     (other disk types aren't free).
   - Firewall: tick **Allow HTTP traffic** and **Allow HTTPS traffic**.
   - Security → Manage access: add your SSH public key (or use the
     console's SSH button).
2. **Make its address static**: VPC network → IP addresses → the VM's
   external address → Promote to static. Check on the billing page after a
   few days whether the address is charged.
3. **Set a budget alert** (Billing → Budgets & alerts).

Then: [On the VM](#on-the-vm-the-same-everywhere).

### On the VM: the same everywhere

Replace `soliton.example.dev` with your name, and `ubuntu` with the VM's
username if it differs.

1. **Point the domain at the VM**: at your registrar, add an **A record**
   for `soliton.example.dev` with the VM's public IP address.

2. **Log in**:

   ```bash
   ssh ubuntu@<the VM's IP address>
   ```

3. **Install the server** (uv, then the server from this repository):

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   source ~/.local/bin/env
   uv tool install "git+https://github.com/selimamar/soliton#subdirectory=server"
   ```

4. **Its token**, readable by you only:

   ```bash
   echo "SOLITON_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')" | sudo tee /etc/soliton.env >/dev/null
   sudo chmod 600 /etc/soliton.env
   sudo cat /etc/soliton.env      # the token, for the app
   ```

5. **Run it as a service**, so it starts with the VM and restarts if it
   stops. Create `/etc/systemd/system/soliton.service`
   (`sudo nano /etc/systemd/system/soliton.service`):

   ```ini
   [Unit]
   Description=Soliton server
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=ubuntu
   EnvironmentFile=/etc/soliton.env
   Environment=SOLITON_DATA_DIR=/home/ubuntu/soliton-data
   ExecStart=/home/ubuntu/.local/bin/soliton-server --host 127.0.0.1 --port 8000
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```

   then:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now soliton
   systemctl status soliton        # "active (running)"
   ```

   It listens on this machine only (`127.0.0.1`); Caddy, next, is what the
   outside reaches.

6. **HTTPS with [Caddy](https://caddyserver.com)**, which gets a free
   certificate from Let's Encrypt and renews it by itself:

   ```bash
   sudo apt update && sudo apt install -y caddy
   ```

   Replace the contents of `/etc/caddy/Caddyfile` with:

   ```
   soliton.example.dev {
       reverse_proxy 127.0.0.1:8000
   }
   ```

   then `sudo systemctl reload caddy`. Within a minute,
   `https://soliton.example.dev/api/health` answers in a browser. (If it
   doesn't: the DNS record may not have spread yet, or ports 80 and 443 are
   still closed; `journalctl -u caddy` says which.)

7. **Security updates**: Ubuntu's cloud images install them by themselves
   (`unattended-upgrades`). Reboot now and then for kernel updates
   (`sudo reboot`; the server comes back by itself), or let it reboot at
   night: set `Unattended-Upgrade::Automatic-Reboot "true";` in
   `/etc/apt/apt.conf.d/50unattended-upgrades`.

8. **Connect**: in the app, **Settings → Server**, with
   `https://soliton.example.dev` and the token. On each machine that runs
   jobs, `soliton setup --server https://soliton.example.dev`
   ([Getting started](getting-started.md#by-hand)); for clusters, give it a
   job token from the app (Settings → Advanced security).

**Updating the server:**

```bash
uv tool upgrade soliton-server && sudo systemctl restart soliton
```

**Daily backups**, kept for 30 days (`crontab -e`, then add):

```bash
0 3 * * * SOLITON_DATA_DIR=$HOME/soliton-data $HOME/.local/bin/soliton-server --backup $HOME/soliton-backups/
30 3 * * * find $HOME/soliton-backups -name 'soliton-*.db' -mtime +30 -delete
```

Copy them off the VM now and then (`scp` or `rsync` from your computer), or
use the app's Settings → Storage → **Download a backup**: if the provider
ever closes the account, a recent copy is all you need to start again
elsewhere ([Restoring](../server/README.md#backups)).

---

## Your own computer

**Only your computer**: `soliton-server` with no options listens on
`http://127.0.0.1:8000`, for jobs and the app on that computer
([Getting started](getting-started.md#2-have-a-server)). With
`--host 0.0.0.0`, phones and computers on the same home network reach it at
your computer's local address ([server README](../server/README.md#running-it-locally)).

**From anywhere** (Sherlock jobs, your phone on mobile data), the computer
has to be reachable from the internet, and the token needs HTTPS:

1. **Let connections in.** At home, forward ports 80 and 443 on your router
   to the computer. In **Stanford student housing**, change the computer's
   firewall profile in the [Residential Network Tool](https://rnt.stanford.edu/)
   ([what each allows](https://uit.stanford.edu/service/firewalls/residential)):
   **Limited Access** opens SSH, HTTP and HTTPS (22, 80, 443), which is what
   Caddy needs. Stanford asks that the computer be kept patched, with a
   software firewall on, and can cut off a connection that disturbs the
   network. (Whether Sherlock's nodes can reach a computer in housing is
   worth checking with a test before relying on it.)
2. **A domain and Caddy**, as on a VM: an A record pointing at your public
   address, and Caddy in front of `soliton-server` (`brew install caddy` on
   a Mac, the same Caddyfile). If your address changes now and then, update
   the record, or use a dynamic DNS service.
3. **Keep it on**: the computer must stay awake and connected (on a Mac,
   System Settings → Energy → prevent sleeping, or run the server under
   `caffeinate -s`).

This costs nothing, but it's the least dependable: the server is down
whenever the computer sleeps, moves or loses its network. It suits a desktop
that stays in one place; for a laptop, prefer a VM or Heroku.

---

## Backups

Wherever it runs, keep copies of the database off that machine:

- **SQLite** (VMs, your computer, the Sherlock test server): the app's
  Settings → Storage → **Download a backup**, or `soliton-server --backup`
  on a schedule (above).
- **PostgreSQL** (Heroku): the provider's backups, and `pg_dump` or
  `heroku pg:backups:download` for a copy of your own.

The [server README](../server/README.md#backups) covers restoring, and
moving a server to a new machine.
