"""Prepare a private, single-team SSH inventory for a Navigator run."""

import json
from contextlib import contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml


INVENTORY_DIR = Path("inventory")


def read_settings(path):
    if not path.is_file():
        raise ValueError(f"Create {path} from {path.with_name('.env.example')}.")
    settings = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip().removeprefix("export ")
        name, separator, value = line.partition("=")
        if separator and not name.startswith("#"):
            value = value.strip()
            if len(value) >= 2 and value[0] in ("'", '"') and value[-1] == value[0]:
                value = value[1:-1]
            settings[name.strip()] = value
    return settings


@contextmanager
def team_inventory(team):
    team_dir = INVENTORY_DIR / team
    settings_path = team_dir / ".env"
    settings = read_settings(settings_path)
    host = settings.get("REMOTE_HOST")
    user = settings.get("REMOTE_USER")
    if not host or not user:
        raise ValueError(f"Set REMOTE_HOST and REMOTE_USER in {settings_path}.")
    if settings.get("AUTH_METHOD", "key") != "key":
        raise ValueError(f"Use key authentication in {settings_path}.")
    port = settings.get("REMOTE_PORT") or "22"
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError(f"Set a valid REMOTE_PORT in {settings_path}.")

    team_ssh = team_dir / ".ssh"
    source_key = (team_dir / (settings.get("SSH_KEY") or ".ssh/server_ed25519")).resolve()
    if not source_key.is_relative_to(team_ssh.resolve()) or not source_key.is_file():
        raise ValueError(f"Set SSH_KEY in {settings_path} to a key under {team_ssh}.")
    trusted_hosts = team_ssh / "known_hosts"
    if not trusted_hosts.is_file():
        raise ValueError(f"Add the verified SSH host key to {trusted_hosts}.")

    group = yaml.safe_load((INVENTORY_DIR / "teams.yml").read_text(encoding="utf-8"))[team]
    host_alias, = group["hosts"]

    with TemporaryDirectory(prefix="react2shell-ssh-") as directory:
        private_key = Path(directory) / "identity"
        private_key.touch(mode=0o600)
        private_key.write_bytes(source_key.read_bytes())
        variables = {
            "ansible_host": host,
            "ansible_user": user,
            "ansible_port": int(port),
            "ansible_python_interpreter": "auto_silent",
            "ansible_ssh_private_key_file": str(private_key),
            "ansible_ssh_common_args": (
                "-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
                f"-o UserKnownHostsFile={trusted_hosts.resolve()} -o GlobalKnownHostsFile=/dev/null"
            ),
            "react2shell_port": settings.get("REACT2SHELL_PORT") or "3000",
        }
        if bind_host := settings.get("REACT2SHELL_BIND_HOST"):
            variables["react2shell_bind_host"] = bind_host
        if target_url := settings.get("TARGET_URL"):
            variables["target_url"] = target_url
        inventory = Path(directory) / "inventory.json"
        group["hosts"][host_alias] = {**(group["hosts"][host_alias] or {}), **variables}
        inventory.write_text(json.dumps({team: group}), encoding="utf-8")
        yield inventory
