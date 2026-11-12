#!/usr/bin/env bash
set -euo pipefail
umask 022

readonly lab_root=/opt/react2shell-lab
readonly app_dir="$lab_root/app"
readonly capture_dir="$lab_root/capture"
readonly marker="$lab_root/.pysible-lab"
readonly tag=pysible-react2shell-lab-v1
readonly service=react2shell-lab.service
readonly unit="/etc/systemd/system/$service"
readonly node_version=v22.23.4
readonly node_dir="$lab_root/node-$node_version"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

exists() {
  [[ -e "$1" || -L "$1" ]]
}

lock_lab() {
  (( EUID == 0 )) || fail 'Connect as root to change the lab.'
  exec 9</opt
  flock -n 9 || fail 'Another lab change is in progress.'
}

check_ownership() {
  if exists "$lab_root"; then
    [[ -d "$lab_root" && ! -L "$lab_root" && -f "$marker" && ! -L "$marker" &&
      $(<"$marker") == "$tag" ]] || fail "Refusing to manage an existing directory: $lab_root"
  elif exists "$unit"; then
    fail "The service exists without its lab directory: $unit"
  fi
  if exists "$unit"; then
    [[ -f "$unit" && ! -L "$unit" && $(head -n 1 "$unit") == "# $tag" ]] ||
      fail "Refusing to manage an existing service: $unit"
  fi
}

check_prerequisites() {
  (( EUID == 0 )) || fail 'Connect as root to install the lab.'
  for tool in curl tar xz sha256sum systemctl flock openssl; do
    command -v "$tool" >/dev/null || fail "Missing tool on the challenge host: $tool"
  done
  [[ -d /opt && ! -L /opt ]] || fail 'Expected a local /opt directory.'
  systemctl show --property=Version >/dev/null
  check_ownership
  if ! exists "$unit"; then
    [[ -z $(systemctl list-unit-files "$service" --no-legend) ]] ||
      fail "Another systemd unit already uses the name $service."
  fi
}

install_node() (
  local arch checksum archive work
  if [[ -x "$node_dir/bin/node" ]]; then
    return 0
  fi
  case "$(uname -m)" in
    x86_64)
      arch=x64
      checksum=1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce
      ;;
    aarch64)
      arch=arm64
      checksum=6287aa46b6c375d816e63ae66d024fbbfd70404825aabdfdf898a970871d2f4b
      ;;
    *) fail 'The bundled Node.js setup supports Linux x86_64 and arm64.' ;;
  esac
  archive="node-$node_version-linux-$arch.tar.xz"
  work=$(mktemp -d "$lab_root/.node.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  printf 'Installing Node.js %s inside the lab.\n' "$node_version"
  curl -fSsL --retry 3 --connect-timeout 10 -o "$work/$archive" "https://nodejs.org/dist/$node_version/$archive"
  printf '%s  %s\n' "$checksum" "$work/$archive" | sha256sum --check --status
  mkdir "$work/node"
  tar -xJf "$work/$archive" --no-same-owner --strip-components=1 -C "$work/node"
  mv -T -- "$work/node" "$node_dir"
)

install_capture_files() {
  local flag
  install -d -m 0755 "$capture_dir"
  if [[ ! -f "$capture_dir/flag.txt" ]]; then
    flag=$(openssl rand -hex 16)
    printf 'CTF{react2shell_%s}\n' "$flag" > "$capture_dir/flag.txt"
  fi
  printf 'You reached the capture files on the challenge host.\n' > "$capture_dir/message.txt"
  cat > "$capture_dir/show_message.sh" <<'MESSAGE_SCRIPT'
#!/bin/sh
set -eu
cat -- "$(dirname -- "$0")/message.txt"
MESSAGE_SCRIPT
  chmod 0644 "$capture_dir/flag.txt" "$capture_dir/message.txt"
  chmod 0755 "$capture_dir/show_message.sh"
}

http_ready() {
  local page
  page=$(curl --noproxy '*' -fs --retry 5 --retry-connrefused --retry-delay 1 --max-time 5 "$1") &&
    [[ $page == *'<h1>React2Shell Lab</h1>'* ]]
}

listener() {
  local start
  start=$(sed -n '/^ExecStart=/p' "$unit")
  [[ $start =~ --hostname[[:space:]]+([0-9.]+)[[:space:]]+--port[[:space:]]+([0-9]+)$ ]] ||
    fail 'Could not read the configured address.'
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

provision() (
  local port=$1 source_dir build_dir
  [[ $port =~ ^[1-9][0-9]{3,4}$ ]] && (( port >= 1024 && port <= 65535 )) ||
    fail 'Use a TCP port from 1024 to 65535.'
  lock_lab
  check_prerequisites
  source_dir=$(dirname -- "${BASH_SOURCE[0]}")/app
  [[ -f "$source_dir/package-lock.json" ]] || fail 'The app bundle is missing its npm lockfile.'
  if ! exists "$lab_root"; then
    mkdir -m 0755 "$lab_root"
    printf '%s\n' "$tag" > "$marker"
  fi

  install_node
  build_dir=$(mktemp -d "$lab_root/.build.XXXXXX")
  trap 'rm -rf -- "$build_dir"' EXIT
  cp -a "$source_dir/." "$build_dir/"
  (
    cd "$build_dir"
    export PATH="$node_dir/bin:$PATH" NEXT_TELEMETRY_DISABLED=1
    export npm_config_cache="$lab_root/npm-cache" NODE_OPTIONS=--max-old-space-size=512
    npm ci --ignore-scripts --no-audit --no-fund
    npm run build
  )
  chmod -R go-w "$build_dir"
  chmod 0755 "$build_dir"
  install_capture_files
  if exists "$unit"; then
    systemctl stop "$service"
  fi
  rm -rf --one-file-system -- "$app_dir"
  mv -T -- "$build_dir" "$app_dir"

  cat > "$unit" <<SERVICE_UNIT
# $tag
[Unit]
Description=React2Shell CTF challenge
After=network.target

[Service]
WorkingDirectory=$app_dir
ExecStart=$node_dir/bin/node $app_dir/node_modules/next/dist/bin/next start --hostname 127.0.0.1 --port $port
Environment=NEXT_TELEMETRY_DISABLED=1
DynamicUser=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
NoNewPrivileges=yes
CapabilityBoundingSet=
SERVICE_UNIT
  systemctl daemon-reload
  systemctl start "$service"
  http_ready "http://127.0.0.1:$port/" ||
    fail 'The challenge did not respond. Check the lab service journal.'
  printf 'Challenge ready on Blue at http://127.0.0.1:%s/.\n' "$port"
)

status() {
  local address host port check_host file
  check_ownership
  if ! exists "$lab_root"; then
    printf 'React2Shell lab is not provisioned.\n'
    return
  fi
  printf 'Lab directory: %s\n' "$lab_root"
  if [[ ! -f "$app_dir/.next/BUILD_ID" || ! -f "$unit" ]]; then
    printf 'Provisioning is incomplete. Run the provision playbook.\n'
    return
  fi
  address=$(listener)
  read -r host port <<< "$address"
  check_host=$host
  [[ $host != 0.0.0.0 ]] || check_host=127.0.0.1
  printf 'Configured listener: %s:%s\nService: ' "$host" "$port"
  systemctl is-active "$service"
  http_ready "http://$check_host:$port/" || fail 'The expected page did not respond.'
  printf 'HTTP check: challenge page responded.\n'
  [[ -s "$capture_dir/flag.txt" && -s "$capture_dir/message.txt" && -x "$capture_dir/show_message.sh" ]] ||
    fail 'A capture file is missing.'
  for file in flag.txt message.txt show_message.sh; do
    [[ -f "$capture_dir/$file" && ! -L "$capture_dir/$file" ]] ||
      fail "Expected a regular capture file: $file"
  done
  printf 'Capture files are ready in %s.\n' "$capture_dir"
  for file in flag.txt message.txt show_message.sh; do
    printf '\n%s\n' "$file"
    sed 's/^/  /' -- "$capture_dir/$file"
  done
}

expose() {
  local host=$1 address old_host port old_unit new_unit url
  [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $host != 0.0.0.0 ]] ||
    fail 'Set REACT2SHELL_BIND_HOST to a specific IPv4 address assigned to the challenge host.'
  ip -o -4 address show | awk -v host="$host" '{ split($4, a, "/"); if (a[1] == host) found = 1 } END { exit !found }' ||
    fail 'REACT2SHELL_BIND_HOST must be an IP assigned to the Blue VM. Use its own public or private IP.'
  lock_lab
  check_ownership
  [[ -f "$app_dir/.next/BUILD_ID" && -f "$unit" ]] || fail 'Provision the challenge first.'
  address=$(listener)
  read -r old_host port <<< "$address"
  url="http://$host:$port/"
  if [[ $old_host == "$host" ]] && systemctl is-active --quiet "$service" && http_ready "$url"; then
    printf 'Challenge is already listening on %s:%s.\n' "$host" "$port"
    return
  fi
  old_unit=$(<"$unit")
  new_unit=${old_unit/"--hostname $old_host --port $port"/"--hostname $host --port $port"}
  printf '%s\n' "$new_unit" > "$unit"
  if systemctl daemon-reload && systemctl restart "$service" && http_ready "$url"; then
    printf 'Challenge is now listening on %s:%s.\n' "$host" "$port"
  else
    printf '%s\n' "$old_unit" > "$unit"
    systemctl daemon-reload
    systemctl restart "$service"
    fail 'Could not expose the challenge. Restored its previous bind address.'
  fi
}

deprovision() {
  lock_lab
  check_ownership
  if ! exists "$lab_root"; then
    printf 'React2Shell lab is already removed.\n'
    return
  fi
  if exists "$unit"; then
    systemctl stop "$service"
    rm -f -- "$unit"
  fi
  systemctl daemon-reload
  rm -rf --one-file-system -- "$lab_root"
  printf 'Removed the challenge service and all lab files.\n'
}

case "${1:-}" in
  check)
    check_prerequisites
    printf 'Challenge host prerequisites are ready.\n'
    ;;
  provision) provision "${2:-3000}" ;;
  status) status ;;
  expose) expose "${2:?Provide the challenge host IPv4 address}" ;;
  deprovision) deprovision ;;
  *) fail 'Expected check, provision, status, expose, or deprovision.' ;;
esac
