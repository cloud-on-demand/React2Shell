# React2Shell lab

This is a **React2Shell (CVE-2025-55182) lab**. Blue Team provisions a deliberately
vulnerable Next.js challenge app on a disposable DigitalOcean Droplet. Red Team
uses a separate disposable Droplet as its operator workstation, connecting over
SSH and viewing the challenge page with Lynx. The current Red playbooks also
include a lab probe, command execution, flag capture, page defacement, revert,
and a guided walkthrough.

A single root Compose file runs Ansible Navigator for both teams. The shared
runner uses the selected team's colors; each team has its own inventory settings
and SSH material.

| Path | Contents |
| --- | --- |
| [`docker-compose.yaml`](docker-compose.yaml) | Shared Navigator runner |
| [`blue_team/playbooks/`](blue_team/playbooks/) | Challenge setup, status, exposure, teardown, and SSH check |
| [`red_team/playbooks/`](red_team/playbooks/) | Operator workstation SSH check, React2Shell probe, exploit, flag capture, page defacement, revert, and step-by-step build |
| [`red_team/scripts/`](red_team/scripts/) | Numbered HTTP check, text-page scripts, and the React2Shell helper |
| [`blue_team/react2shell_lab/`](blue_team/react2shell_lab/) | Challenge app and management script |
| [`inventory/`](inventory/) | Ansible host aliases, local demo inventory, and per-team SSH settings |

## Tooling

| Tool | Role in the lab |
| --- | --- |
| Docker Compose (`docker compose`) | Builds and runs the shared local automation container |
| Ansible Navigator and Ansible playbooks | Run Blue and Red workflows over SSH, with interactive steps |
| Disposable DigitalOcean Droplets | Separate Blue challenge and Red operator Linux VMs; create them separately and destroy them after training |
| React and Next.js | Power the deliberately vulnerable challenge application |
| Bash (`.sh` scripts) | Manage the challenge, check HTTP responses, view pages, and run the lab's React2Shell helper |
| Python | Implements the terminal walkthrough and prepares each team's temporary SSH inventory |
| Lynx and curl | View the challenge as text and send HTTP requests from Red |
| PowerShell (`playbook.ps1`) | Provides the optional team/playbook menu and recording controls |

The playbooks configure existing Droplets; they do not create or delete cloud VMs.
After removing the lab software, destroy the disposable Droplets separately in
DigitalOcean when the session is finished.

## Lab scope and prerequisites

This is an intentionally vulnerable training environment. Run it only on disposable
VMs you control or have explicit authorization to test. Limit HTTP access to the
Red VM or a private lab network using a cloud or host firewall. The `expose`
playbook changes the listener; it does not configure firewall rules or TLS.

- Workstation: Docker with Linux containers and Compose v2. No local Python,
  Ansible, or Node.js installation is required when using the runner.
- Optional Windows menu: PowerShell 7 and an interactive terminal with Unicode
  support. The SSH setup below also requires the OpenSSH client tools.
- Blue VM: Linux x86_64 or arm64 with systemd, Python 3, Bash, `curl`, `tar`, `xz`,
  `sha256sum`, `flock`, `openssl`, and `ip` (iproute2). Connect as root for lab
  management; the playbooks do not elevate Blue tasks with `become`.
- Red VM: Linux with Python 3, Bash, and a supported package manager. Package
  installation uses `become: true`; use root or an account with unattended sudo.
- Outbound network access is needed to build the runner, download the pinned
  Node.js runtime and npm packages on Blue, and install tools on Red.

The challenge uses plain HTTP, port `3000` by default. Use an `http://` target URL.
The supported challenge port range is `1024`–`65535`. Provisioning binds to loopback;
run `expose` only after setting an assigned IPv4 address and restricting access.

## Start the runner

Open PowerShell in the cloned repository root (the `react2shell` folder), then build the shared runner:

```powershell
docker compose build
```

## Blue Team playbooks

Run these Docker commands from the project root. For a new challenge host, follow the [SSH setup below](#vm-ssh-setup).
Run the playbook for the operation you want:

```powershell
docker compose run --rm navigator run blue_team/playbooks/ssh_connect.yml --enable-prompts -- --step
docker compose run --rm navigator run blue_team/playbooks/status.yml --enable-prompts -- --step
docker compose run --rm navigator run blue_team/playbooks/provision.yml --enable-prompts -- --step
docker compose run --rm navigator run blue_team/playbooks/expose.yml --enable-prompts -- --step
docker compose run --rm navigator run blue_team/playbooks/deprovision.yml --enable-prompts -- --step
```

Provision starts the challenge on loopback. Set `REACT2SHELL_BIND_HOST` in
`inventory/blue_team/.env` to an IPv4 address assigned to the challenge host, public or private. Expose binds to that
address on the configured HTTP port, which defaults to `3000`. Deprovision removes the lab
service and files.

Status and the final provisioning step display the contents of `flag.txt`, `message.txt`, and
`show_message.sh` from the challenge host.

## Inventory

`inventory/teams.yml` defines `challenge_host` for Blue Team and `operator_workstation` for
Red Team. `inventory/local.ini` is the inventory for the container-only demo.

Copy `.env.example` to `.env` in `inventory/blue_team/` or `inventory/red_team/` for the VM you want to configure.
Set the host and login and place the private key and verified `known_hosts` file in that same team's
`.ssh/` directory. `SSH_KEY` is relative to the team's inventory folder. For example,
`SSH_KEY=.ssh/server_ed25519`.

Each team runner combines its group from `inventory/teams.yml` with its local settings and stages
its private key inside the container with Linux permissions. The root Git ignore rules cover
the populated `.env` and `.ssh` files.

## VM SSH setup

### Generate the login key

All commands below assume the `react2shell` lab root unless stated otherwise.
The examples below use Blue Team. For Red Team, use `inventory/red_team/` and the Red VM details.
Run this setup from the lab root in PowerShell if you need a new key.
Press Enter twice at the passphrase prompts for this lab key so the runner can use it unattended.

```powershell
ssh-keygen -t ed25519 -C "react2shell-blue" -f .\inventory\blue_team\.ssh\server_ed25519
Get-Content .\inventory\blue_team\.ssh\server_ed25519.pub
```

Add that public key when creating the DigitalOcean Droplet. On an existing VM, add it to
`~/.ssh/authorized_keys` for the Linux user that Ansible will use. The private key stays in
`inventory/blue_team/.ssh/`.

```powershell
if (!(Test-Path -LiteralPath .\inventory\blue_team\.env)) {
    Copy-Item .\inventory\blue_team\.env.example .\inventory\blue_team\.env
}
notepad .\inventory\blue_team\.env
```

Set `REMOTE_HOST`, `REMOTE_USER`, and `REMOTE_PORT` for the Droplet. Keep
`SSH_KEY=.ssh/server_ed25519` if you used the filename above.

### Verify and save the server's host key

The login key authorizes your user. The host key identifies the server. In the **DigitalOcean
Droplet Console**, read the server's Ed25519 fingerprint:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Back in PowerShell, use the host and port from `.env`. Paste only the `SHA256:...` value from the
Droplet Console when prompted. These commands save the scanned key only if its fingerprint matches.

```powershell
$blueHost = 'BLUE_VM_IP_OR_DNS'
$bluePort = 22
$expected = (Read-Host 'Paste the SHA256 fingerprint from the Droplet Console').Trim()

$hostKeys = @(ssh-keyscan -T 6 -p $bluePort -t ed25519 $blueHost)
if ($LASTEXITCODE -ne 0 -or $hostKeys.Count -eq 0) {
    throw 'The VM did not return an Ed25519 host key. Check the host and SSH port.'
}

$seen = @($hostKeys | ssh-keygen -lf - | ForEach-Object {
    if ($_ -match 'SHA256:[A-Za-z0-9+/]+') { $Matches[0] }
} | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0 -or $seen.Count -ne 1 -or $seen[0] -cne $expected) {
    throw 'The scanned host key did not match the Droplet Console fingerprint.'
}

$knownHosts = '.\inventory\blue_team\.ssh\known_hosts'
if (Test-Path -LiteralPath $knownHosts) {
    throw "A host key is already saved in $knownHosts."
}
$hostKeys | Set-Content -LiteralPath $knownHosts -Encoding ascii
```

### Test the connection

```powershell
docker compose run --rm navigator run blue_team/playbooks/ssh_connect.yml --enable-prompts -- --step
```

Press `y` and Enter. A successful run shows `Connected as <user> on <hostname>`.

## Red Team playbooks

From the project root, connect to the VM configured in `inventory/red_team/.env`:

```powershell
docker compose run --rm navigator run red_team/playbooks/ssh_connect.yml --enable-prompts -- --step
```

The Red Team walkthrough uses red accents. Use `playbook red` below for its recording menu.

To read the Blue Lab page as text from Red, set `TARGET_URL` in `inventory/red_team/.env`, such as
`TARGET_URL=http://BLUE_HOST_IP:3000/`, then run:

```powershell
playbook red lynx
```

The first step installs Lynx on the Red VM. The second fetches the page and prints its text in
the walkthrough's stdout section. You can also launch it directly from the project root:

```powershell
docker compose run --rm navigator run red_team/playbooks/lynx.yml --enable-prompts -- --step
```

### React2Shell exploit playbooks

The Blue challenge runs Next.js 15.5.6 with React 19.1.1, pinned deliberately to reproduce
CVE-2025-55182 in the React Server Components stack. See the
[React advisory](https://react.dev/blog/2025/12/03/critical-security-vulnerability-in-react-server-components)
and [Next.js advisory](https://github.com/vercel/next.js/security/advisories/GHSA-9qr9-h5gf-34mp).
These versions are lab fixtures and must not be reused for a production app. Point these playbooks only at the
challenge host in this lab. The [helper script](red_team/scripts/react2shell.sh) is piped to the Red
VM over SSH by each playbook, so the exploit details stay out of the recorded Bash preview. Set
`TARGET_URL` in `inventory/red_team/.env` just like for Lynx, then run the playbooks in order:

```powershell
docker compose run --rm navigator run red_team/playbooks/react2shell_check.yml --enable-prompts -- --step
docker compose run --rm navigator run red_team/playbooks/react2shell_rce.yml --enable-prompts -- --step
docker compose run --rm navigator run red_team/playbooks/react2shell_flag.yml --enable-prompts -- --step
```

The probe playbook does not request shell command execution on the challenge. It sends a Flight reference that only a
vulnerable decoder follows, so a vulnerable challenge answers HTTP 500 with the `E{"digest"` error
pattern and the playbook prints the vulnerable verdict. Other responses are reported as looking patched or not running RSC; an unexpected
500 without the digest is ambiguous. This is a lab heuristic, not proof that a
server is vulnerable or patched.

The RCE playbook sends the crafted multipart payload with a `Next-Action` header and runs `id` on
the challenge host through the deserialization bug. Command output comes back base64-encoded in
the `x-action-redirect` response header, and the playbook prints it in the step's stdout section.
Edit `react2shell_command` at the top of the playbook to run something else, or pass it on the
command line:

```powershell
docker compose run --rm navigator run red_team/playbooks/react2shell_rce.yml --extra-vars react2shell_command=whoami --enable-prompts -- --step
```

The flag playbook uses the same bug with a default command that reads `flag.txt` and runs
`show_message.sh` from `/opt/react2shell-lab/capture/`. The capture files are world-readable, so
the challenge service's sandboxed dynamic user can read them, and the systemd hardening on the
unit does not block the read.

The defacement pair changes the challenge page itself. The service mounts its filesystem
read-only, so the deface playbook runs a payload that hooks the running page handler in memory
and rewrites the page heading to a red `REACT2SHELL LAB - RED TEAM WAS HERE` banner on every
`GET /`. It captures the page with Lynx before and after the exploit, so the recording shows the
change landing; the red color shows in a browser, since Lynx renders text only. The revert
playbook sends the matching restore payload and captures the page again. Both steps survive
repeats: defacing twice reports the hook was already installed, and reverting twice reports
there is nothing to revert. The hook is memory-only, so restarting the challenge service also
clears it.

```powershell
docker compose run --rm navigator run red_team/playbooks/react2shell_deface.yml --enable-prompts -- --step
docker compose run --rm navigator run red_team/playbooks/react2shell_revert.yml --enable-prompts -- --step
```

The build playbook is the teaching version of the exploit, written for viewers who are new to
web exploitation. Thirteen steps walk the chain one test at a time, and each step's caption
explains every flag and every line of output in plain language: what a 200 or 500 status means,
what the `$ACTION_ID` form field arms, how Flight chunk references like `$1:a:a` work, a
field-by-field anatomy of the crafted chunk, the JavaScript one-liner the command becomes
(`code` mode), the untouched server response with the base64-carrying `x-action-redirect` header
(`raw` mode), the decoded `id` output showing the sandboxed dynamic user, where the code runs,
the capture-file permissions, the flag capture, and a closing check that the app is still
healthy. The `payload` and `code` modes of the helper script only print their output.
The `raw` mode sends the command payload to the target and prints the response;
it executes the supplied command just like the exploit mode.

```powershell
docker compose run --rm navigator run red_team/playbooks/react2shell_build.yml --enable-prompts -- --step
```

## Local recording demo

From the project root, the two demo playbooks run inside the container and display the Purple Box banner.
A named volume holds their sample files:

```powershell
docker compose run --rm navigator run blue_team/playbooks/demo/provision.yml --enable-prompts -- --step
docker compose run --rm navigator run blue_team/playbooks/demo/deprovision.yml --enable-prompts -- --step
```

The walkthrough uses blue accents for Blue Team, red for Red Team, and violet for the local demo.
Each step shows its number and a syntax-highlighted Bash preview. Compact colored shortcuts
show the Run, Skip, and Continue keys beside the input prompt. A spinner and scanner track live activity. Command results
show exit-code and duration badges, followed by spaced sections for standard output and errors.
The final recap includes the session time and exit code. The last demo teardown task runs Bash.

Press the key on the green Run, amber Skip, or team-colored Continue button, then Enter. Continue runs
the remaining tasks without pausing. Navigator uses terminal output mode for live prompts. Omit
`--enable-prompts -- --step` to try the full-screen task explorer.

## Playbook recording menu

The reusable [PowerShell helper](playbook.ps1) finds the nearest parent folder with a Compose
file and `blue_team/playbooks` or `red_team/playbooks`. You can use it from the project root,
either team folder, or a nested folder. Future projects can use the same layout.

Load the helper in your current PowerShell session:

```powershell
. ./playbook.ps1
```

To load it whenever PowerShell starts, add a dot-source command with the helper's absolute path to `$PROFILE`.
The helper discovers the project each time you invoke it.

```powershell
playbook
```

At the project root, choose Blue or Red, then choose a playbook by number or name.
Inside a team folder, the menu selects that team automatically.

| Command | Action |
| --- | --- |
| `playbook` | Choose a team and playbook |
| `playbook -Recording` | Hide typing suggestions and the full prompt path, then open the picker |
| `playbook list` | List playbooks for both teams, or the current team folder |
| `playbook blue` | Open the Blue Team playbook menu |
| `playbook red` | Open the Red Team playbook menu |
| `playbook blue status` | Run Blue Team status directly |
| `playbook red ssh_connect` | Run Red Team's SSH check directly |
| `playbook blue 5` | Run the fifth Blue Team playbook |
| `playbook -Project <path-to-react2shell>` | Select a project while working elsewhere |

The helper runs the root Compose file with explicit paths. Your working directory stays where you
started. `-Width` controls the recording width, and `-Service` selects the Compose service, which
defaults to `navigator`.

Use `-Speed` to control caption and command typing. `normal` keeps the usual pace, `fast` uses a
quarter of the delay, `slow` uses one and a half times the delay, and `instant` displays text immediately.

```powershell
playbook red ssh_connect -Speed instant
playbook red ssh_connect -Recording -Speed slow
```

For direct Docker commands, pass `-e WALKTHROUGH_SPEED=instant` before the `navigator` service name.

Use `-Recording` to hide PowerShell's history suggestions while typing and switch to a rounded
prompt showing only the current folder name. This applies to the current PowerShell session.

```powershell
playbook list -Recording
Clear-Host
playbook
```

To hide just the typing suggestions in the current session, run
`Set-PSReadLineOption -PredictionSource None`.

### Panel width

The walkthrough wraps text, Bash previews, and task output at 150 columns by default.
The recording menu uses 128 columns. Use `playbook blue status -Width 150` to change it, or set
`WALKTHROUGH_WIDTH` in a direct Docker command.
The panel adapts to narrower terminals, down to 24 columns.

```powershell
docker compose run --rm -e WALKTHROUGH_WIDTH=128 navigator run blue_team/playbooks/status.yml --enable-prompts -- --step
```

Run the Docker width example above from the project root.

In Windows Terminal, hold **Ctrl** and scroll up to enlarge the text and glyphs for the session.
Maximize the window if you need more columns after zooming.

### Temporary bottom spacing

Reserve four blank rows below the output in the current PowerShell session:

```powershell
$esc = [char]27
$bottom = [Math]::Max(2, [Console]::WindowHeight - 4)
[Console]::Write("$esc[1;${bottom}r$esc[${bottom};1H$esc[J")
```

Change `4` to adjust the gap. Restore the full scrolling area with:

```powershell
[Console]::Write("$esc[s$esc[r$esc[u")
```

Reapply the spacing after resizing the window. Full-screen applications may manage their own
scrolling region. These commands use the terminal's
[scrolling margins](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences#scrolling-margins).


## Cleanup and troubleshooting

Run Blue's `deprovision` playbook to stop and remove `react2shell-lab.service` and
all of `/opt/react2shell-lab`, including the generated flag, app, and bundled Node.js.
This deletes the challenge data. Re-provisioning an existing lab preserves its flag;
deprovisioning and provisioning again generates a new one. The service is started
but is not enabled to start automatically after a VM reboot.

`status` expects the original page heading, so a defaced page may fail that check.
Use the revert playbook or restart `react2shell-lab.service` on Blue before checking
again. Re-provisioning also restores the original app and loopback listener.

`docker compose down` manages the runner resources; it does not remove the lab
from the Blue VM. `docker compose down --volumes` also deletes the local demo volume.

If Docker cannot connect, start Docker Desktop and select Linux containers. If
SSH fails, check the team's `.env`, private key, verified `known_hosts`, firewall,
and login permissions. Do not disable host-key checking to bypass a mismatch.

## Public repository hygiene

Keep the `.env.example` files and `.ssh/.gitkeep` placeholders. The `.gitignore`
excludes populated environment files (including variants such as `.env.local`),
SSH material, logs, dependencies, and build output. The `.dockerignore` permits
only the Dockerfile in the build context; Compose mounts the lab read-only at
runtime, including local connection settings needed by the runner.

Before the first commit, run these from the `react2shell` repository root:

```powershell
git status --short --untracked-files=all
git add --dry-run .
git ls-files
```

Confirm that `.env`, private keys, `known_hosts`, logs, and recordings are absent.
Ignore rules do not untrack files or erase old commits. Rotate any previously
committed secret and remove it from history before publishing. Inspect terminal
recordings for host addresses, usernames, and captured flags.

The optional menu is included as `playbook.ps1` in this repository. Publish only
the `react2shell` folder; no parent workspace files are required. No project license
is currently included; choose one before offering the code for reuse.

## Sources and acknowledgements

The lab's payload and probe are based on the published **freeqaz/react2shell**
research and proofs of concept (PoCs). **Datadog Security Labs** and
**Trend Micro's analysis** provide technical background and exploitation context.
Credit belongs to the original researchers; this repository adapts the material
for a disposable training lab.

- **freeqaz/react2shell — research and PoCs:** [https://github.com/freeqaz/react2shell](https://github.com/freeqaz/react2shell)
- **freeqaz payload reference:** [https://github.com/freeqaz/react2shell/blob/master/PAYLOAD_REFERENCE.md](https://github.com/freeqaz/react2shell/blob/master/PAYLOAD_REFERENCE.md)
- **Datadog Security Labs — CVE-2025-55182 (React2Shell): Remote code execution in React Server Components and Next.js:** [https://securitylabs.datadoghq.com/articles/cve-2025-55182-react2shell-remote-code-execution-react-server-components/](https://securitylabs.datadoghq.com/articles/cve-2025-55182-react2shell-remote-code-execution-react-server-components/)
- **Trend Micro / TrendAI — CVE-2025-55182: React2Shell Analysis, Proof-of-Concept Chaos, and In-the-Wild Exploitation:** [https://www.trendaisecurity.com/en-us/resources-insights/trendai-security-blog/CVE-2025-55182-analysis-poc-itw](https://www.trendaisecurity.com/en-us/resources-insights/trendai-security-blog/CVE-2025-55182-analysis-poc-itw)
