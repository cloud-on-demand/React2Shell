"""Present Ansible step mode in a recording-friendly terminal."""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from itertools import cycle
from pathlib import Path
from unicodedata import category, east_asian_width

import pexpect
import yaml
from pygments import highlight
from pygments.formatters import TerminalTrueColorFormatter
from pygments.lexer import inherit
from pygments.lexers.shell import BashLexer
from pygments.style import Style
from pygments.token import (
    Comment, Keyword, Name, Number, Operator, Punctuation, String, Text, Token, Whitespace,
)

from team_connection import team_inventory


NAVIGATOR = "ansible-navigator"
STEP_PROMPT = re.compile(r"Perform task: TASK: ([^\r\n]+?) \(N\)o/\(y\)es/\(c\)ontinue: ")
TASK_HEADER = re.compile(r"^TASK \[(.+)\] \*+$")
PLAY_HEADER = re.compile(r"^PLAY \[(Blue Team|Red Team|Purple Box) \| (.+)\] \*+$")
RUNNER_EVENT = re.compile(r"\x1b\[K(?:[A-Za-z0-9+/=]+\x1b\[\d+D)+\x1b\[K")
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
DISPLAY_TOKENS = re.compile(f"{ANSI.pattern}|.", re.DOTALL)
DEFAULT_WIDTH = 150
TYPING_SPEEDS = {"normal": 1, "fast": 0.25, "slow": 1.5, "instant": 0}
RECAP_ROW = re.compile(r"^(\S+)\s+:\s+(ok=\d+ .+)$")
RESULT_STYLES = {
    "ok": ("✔", "ok"),
    "changed": ("↻", "changed"),
    "skipping": ("↷", "muted"),
    "fatal": ("✖", "error"),
    "failed": ("✖", "error"),
    "unreachable": ("✖", "error"),
}
RECAP_TONES = {"ok": "ok", "changed": "changed", "failed": "error", "unreachable": "error"}
RESULT_FIELDS = {
    "path": "path",
    "dest": "path",
    "state": "state",
    "mode": "mode",
    "size": "size (bytes)",
    "rc": "exit code",
    "msg": "message",
    "stdout": "stdout",
    "stderr": "stderr",
    "censored": "details",
}
PALETTE = {
    "border": (59, 130, 246),
    "heading": (96, 165, 250),
    "caption": (125, 211, 252),
    "text": (226, 232, 240),
    "muted": (148, 163, 184),
    "button_text": (15, 23, 42),
    "gutter": (30, 41, 59),
    "code_background": (10, 17, 29),
    "ok": (52, 211, 153),
    "changed": (251, 191, 36),
    "error": (248, 113, 113),
}
TEAM_ACCENTS = {
    "Red Team": {"border": (239, 68, 68), "heading": (248, 113, 113), "caption": (252, 211, 77)},
    "Purple Box": {"border": (139, 92, 246), "heading": (167, 139, 250), "caption": (196, 181, 253)},
}
TEAM_CONTEXT = {
    "Blue Team": "CHALLENGE HOST  ·  SSH",
    "Red Team": "OPERATOR WORKSTATION  ·  SSH",
    "Purple Box": "LOCAL DEMO  ·  CONTAINER",
}


class BashPreviewLexer(BashLexer):
    tokens = {
        "data": [
            (r"(?:[0-9]+)?(?:[<>]&[0-9-]+|>>|<>|>|<)|\|&", Operator),
            (r"!(?=\s|$)", Operator),
            (r"--?[A-Za-z][\w-]*(?=$|[\s=;|&<>])", Name.Attribute),
            (r"""(?:https?://|(?:~|\.{1,2})?/|[\w.-]+/)[^\s'"\x60$\\<>&|;(){}\[\]]*""", Name.Namespace),
            (r"#[^\n]*(?=\n|$)", Comment.Single),
            (r"""[^=\s\[\]{}()$"'\x60\\<>&|;]+(?=>)""", Text),
            inherit,
        ],
    }
    command_boundaries = {
        "&&", "||", "|", "|&", ";", "&", "(", "$(", "!",
        "if", "then", "elif", "else", "while", "until", "do",
    }

    def get_tokens_unprocessed(self, text, stack=("root",)):
        expects_command = True
        for offset, token, value in super().get_tokens_unprocessed(text, stack):
            if expects_command and token is Text and re.fullmatch(r"[\w.+-]+", value):
                token = Name.Function
            if token in Whitespace or token in Comment:
                expects_command = expects_command or "\n" in value
            else:
                expects_command = (
                    token in (Keyword, Operator, Punctuation) and value in self.command_boundaries
                )
            yield offset, token, value


class BashTheme(Style):
    styles = {
        Token: "#E2E8F0",
        Comment: "italic #94A3B8",
        Keyword: "#C4B5FD",
        Name.Builtin: "bold #7DD3FC",
        Name.Function: "bold #7DD3FC",
        Name.Attribute: "#FDBA74",
        Name.Namespace: "#93C5FD",
        Name.Variable: "#F0ABFC",
        Number: "#F9A8D4",
        Operator: "#FBBF24",
        Punctuation: "#FBBF24",
        String: "#A7F3D0",
        String.Interpol: "#F0ABFC",
    }


def type_line(prefix, text, delay, suffix=""):
    print(prefix, end="", flush=True)
    for match in DISPLAY_TOKENS.finditer(text):
        token = match[0]
        print(token, end="", flush=True)
        if not token.startswith("\x1b"):
            time.sleep(delay)
    print(suffix)


def token_width(token):
    if token.startswith("\x1b") or category(token) in ("Cc", "Cf", "Mn", "Me"):
        return 0
    return 2 if east_asian_width(token) in ("W", "F") else 1


def display_width(text):
    return sum(map(token_width, DISPLAY_TOKENS.findall(text)))


def wrap_display(text, width):
    tokens = DISPLAY_TOKENS.findall(text.replace("\t", "    "))
    if not tokens:
        yield ""
        return
    sizes = list(map(token_width, tokens))
    start = 0
    style = ""
    while start < len(tokens):
        end = start
        columns = 0
        last_space = start
        seen_word = False
        while end < len(tokens) and columns + sizes[end] <= width:
            columns += sizes[end]
            if sizes[end]:
                if tokens[end] == " " and seen_word:
                    last_space = end + 1
                elif tokens[end] != " ":
                    seen_word = True
            end += 1
        if end < len(tokens) and last_space > start:
            end = last_space
        line = style + "".join(tokens[start:end])
        for token in tokens[start:end]:
            if token in ("\x1b[0m", "\x1b[00m", "\x1b[m"):
                style = ""
            elif token.startswith("\x1b[") and token.endswith("m"):
                style += token
        yield line + ("\x1b[0m" if style else "")
        start = end


class Walkthrough:
    def __init__(self, tasks):
        self.tasks = {task["name"]: task for task in tasks}
        self.number = 0
        self.approved = None
        self.panel_open = False
        self.task_started = None
        self.palette = PALETTE
        self.use_color = not os.environ.get("NO_COLOR")
        speed = TYPING_SPEEDS.get(os.environ.get("WALKTHROUGH_SPEED", "normal").lower(), 1)
        self.caption_delay = 0.065 * speed
        self.command_delay = 0.045 * speed
        try:
            max_width = int(os.environ.get("WALKTHROUGH_WIDTH", DEFAULT_WIDTH))
        except ValueError:
            max_width = DEFAULT_WIDTH
        self.width = max(24, min(max_width, shutil.get_terminal_size((DEFAULT_WIDTH, 24)).columns))

    def paint(self, text, tone, background=None, *, bold=False):
        if not self.use_color:
            return text
        red, green, blue = self.palette[tone]
        style = f"{'1;' if bold else ''}38;2;{red};{green};{blue}"
        if background:
            red, green, blue = self.palette[background]
            style += f";48;2;{red};{green};{blue}"
        return f"\x1b[{style}m{text}\x1b[0m"

    def divider(self, corner, label="", tone="heading"):
        title = f"─ {label} " if label else ""
        if display_width(title) > self.width - 4:
            self.divider(corner)
            self.row(label, tone)
            return
        edge = self.paint(f"  {corner}", "border")
        rule = self.paint("─" * (self.width - 3 - display_width(title)), "border")
        print(edge + self.paint(title, tone, bold=True) + rule)

    def row(self, text, tone="text", *, lead="", continuation=None, delay=0):
        border = self.paint("  │ ", "border")
        if continuation is None:
            continuation = " " * display_width(lead)
        available = self.width - 4 - max(display_width(lead), display_width(continuation))
        for index, line in enumerate(wrap_display(self.paint(text, tone), available)):
            prefix = border + (continuation if index else lead)
            if delay:
                type_line(prefix, line, delay)
            else:
                print(prefix + line)

    def close_panel(self):
        self.task_started = None
        if self.panel_open:
            self.divider("╰")
            self.panel_open = False

    def show_play(self, team, title):
        self.palette = {**PALETTE, **TEAM_ACCENTS.get(team, {})}
        print()
        self.divider("╭", "REACT2SHELL / WALKTHROUGH")
        badge = self.paint(f" ◆ {team.upper()} ", "button_text", "heading", bold=True)
        context = self.paint(TEAM_CONTEXT[team], "muted")
        self.row(f"{badge}  {context}")
        self.row(title, "heading")
        self.divider("╰")

    def show_step(self, name):
        self.close_panel()
        self.number += 1
        total = max(self.number, len(self.tasks))
        print()
        self.divider("╭", f"STEP {self.number:02} / {total:02}")
        self.panel_open = True
        self.row(self.paint(name, "text", bold=True))
        task = self.tasks.get(name, {})
        caption = task.get("vars", {}).get("walkthrough_caption")
        if caption:
            self.row(caption, lead=self.paint(" ▶ ", "caption"), delay=self.caption_delay)
        self.show_operation(task)

    def show_operation(self, task):
        if task.get("no_log"):
            return
        for module in ("ansible.builtin.command", "ansible.builtin.shell"):
            if options := task.get(module):
                if isinstance(options, str):
                    command = options
                elif "argv" in options:
                    command = shlex.join(map(str, options["argv"]))
                else:
                    command = options.get("cmd", "")
                label = "BASH" if module == "ansible.builtin.shell" else "COMMAND"
                self.show_code(command, label)
                return
        for module in ("ansible.builtin.file", "ansible.builtin.copy", "ansible.builtin.package"):
            if options := task.get(module):
                self.divider("├", "ANSIBLE MODULE")
                self.row(module, "caption")
                parameters = [
                    f"{key}={shlex.quote(str(options[key]))}"
                    for key in ("name", "path", "dest", "state", "mode")
                    if key in options
                ]
                if "content" in options:
                    parameters.append("content=<inline>")
                self.row("        " + "  ".join(parameters))
                return

    def command_row(self, text, *, lead="", continuation=None, delay=0):
        inner_width = self.width - 7
        if continuation is None:
            continuation = " " * display_width(lead)
        available = inner_width - 2 - max(display_width(lead), display_width(continuation))
        background = ""
        if self.use_color:
            red, green, blue = self.palette["code_background"]
            background = f"\x1b[48;2;{red};{green};{blue}m"
        frame = self.paint("  │ ", "border") + " "
        edge = self.paint("│", "caption")
        for index, line in enumerate(wrap_display(text, available)):
            gutter = continuation if index else lead
            body = self.paint(gutter + line, "text")
            # Restore the code background after syntax tokens reset their styles.
            body = re.sub(r"\x1b\[(?:0|00)?m", lambda match: match[0] + background, body)
            padding = " " * (inner_width - 2 - display_width(gutter + line))
            prefix = frame + edge + background + " "
            suffix = padding + " " + ("\x1b[0m" if self.use_color else "") + edge
            if delay:
                type_line(prefix, body, delay, suffix)
            else:
                print(prefix + body + suffix)

    def show_code(self, command, label):
        self.row("")
        frame = self.paint("  │ ", "border") + " "
        rule = "─" * (self.width - 7)
        print(frame + self.paint("╭" + rule + "╮", "caption"))
        badge = self.paint(f" {label} ", "button_text", "caption", bold=True)
        self.command_row(badge + self.paint("  PREVIEW", "text", bold=True))
        self.command_row("")
        if self.use_color:
            command = highlight(command, BashPreviewLexer(ensurenl=False, stripnl=False),
                                TerminalTrueColorFormatter(style=BashTheme))
        for index, line in enumerate(command.rstrip().splitlines(), start=1):
            gutter = self.paint(f" {index:02} ", "muted", "gutter")
            mark = self.paint("$ " if index == 1 else "  ", "caption")
            self.command_row(line, lead=gutter + " " + mark, continuation="     ↳ ", delay=self.command_delay)
        print(frame + self.paint("╰" + rule + "╯", "caption"))
        self.row("")

    def approve(self, name):
        self.show_step(name)
        self.divider("├", "APPROVAL", "changed")
        shortcuts = []
        for key, label, tone in (("y", "Run", "ok"), ("n", "Skip", "changed"), ("c", "Continue", "heading")):
            shortcuts.append(self.paint(key, tone, bold=True) + " " + self.paint(label, "text"))
        choices = self.paint("  ·  ", "muted").join(shortcuts)
        arrow = self.paint("  ❯ ", "caption")
        if display_width(choices + arrow) + 12 > self.width:
            self.row(choices)
            choices = ""
        prompt = self.paint("  │ ", "border") + choices + arrow
        answer = input(prompt).strip().lower()
        if answer in ("y", "yes", "c", "continue"):
            self.approved = name
            if answer.startswith("c"):
                self.row("▶ Running the remaining steps", "caption")
            return answer[0]
        self.row("↷ Skipped by operator", "muted")
        self.close_panel()
        return "n"

    def show_output(self, raw):
        line = ANSI.sub("", RUNNER_EVENT.sub("", raw)).rstrip()
        if not line or line == "Using /lab/ansible.cfg as config file":
            return
        if play := PLAY_HEADER.fullmatch(line):
            self.show_play(play[1], play[2])
        elif task := TASK_HEADER.fullmatch(line):
            if task[1] != self.approved:
                self.show_step(task[1])
            self.approved = None
            self.divider("├", "OUTPUT")
            self.task_started = time.monotonic()
        elif line.startswith("PLAY RECAP "):
            self.close_panel()
            print()
            self.divider("╭", "PLAY RECAP")
            self.panel_open = True
        elif self.panel_open:
            self.show_result(line)
        else:
            for part in wrap_display(line, self.width):
                print(part)

    def show_result(self, line):
        if recap := RECAP_ROW.fullmatch(line):
            self.row(recap[1], "heading")
            styled = []
            for metric in recap[2].split():
                key, _, count = metric.partition("=")
                tone = "muted" if count == "0" else RECAP_TONES.get(key, "text")
                styled.append(self.paint(metric, tone))
            self.row(" ".join(styled), lead="  ")
            return
        summary, separator, details = line.partition(" => ")
        status = summary.split(":", 1)[0]
        if status not in RESULT_STYLES:
            self.row(line, "error" if line.startswith("[ERROR]") else "text")
            return
        icon, tone = RESULT_STYLES[status]
        elapsed = None
        if self.task_started is not None:
            elapsed = time.monotonic() - self.task_started
            self.task_started = None
        timing = self.paint(f"  ·  {elapsed:.2f}s", "muted") if elapsed is not None else ""
        if not separator:
            self.row(f"{icon} {line}" + timing, tone)
            return
        try:
            result = json.loads(details)
        except json.JSONDecodeError:
            self.row(f"{icon} {line}" + timing, tone)
            return
        if not isinstance(result, dict):
            self.row(f"{icon} {line}" + timing, tone)
            return

        badge = self.paint(f" {icon} {status.upper()} ", "button_text", tone, bold=True)
        target = self.paint(summary.partition(":")[2].lstrip(), "text", bold=True)
        self.row(f"{badge}  {target}")
        metrics = []
        if result.get("rc") is not None:
            exit_tone = "ok" if result["rc"] == 0 else "error"
            metrics.append(self.paint(f" EXIT {result['rc']} ", "button_text", exit_tone, bold=True))
        if elapsed is not None:
            metrics.append(self.paint(f" TIME {elapsed:.2f}s ", "caption", "gutter", bold=True))
        if metrics:
            self.row("  ".join(metrics))
        for field, label in RESULT_FIELDS.items():
            if field == "rc":
                continue
            value = result.get(field)
            if value in (None, ""):
                continue
            lines = ANSI.sub("", str(value)).splitlines()
            if field in ("stdout", "stderr"):
                tone = "error" if field == "stderr" else "caption"
                self.row("")
                self.row(self.paint(f" {label.upper()} ", "button_text", tone, bold=True))
                for detail in lines:
                    self.row(detail, lead=self.paint("  ▌ ", tone),
                             continuation=self.paint("  ▌ ", tone) + "↳ ")
                self.row("")
                continue
            if len(lines) == 1:
                self.row(f"  {label}: {lines[0]}")
            else:
                self.row(f"  {label}:")
                for detail in lines:
                    self.row(detail, lead="    ")

    def run(self, arguments):
        run_started = time.monotonic()
        if not any(arg == "--verbose" or re.fullmatch(r"-v+", arg) for arg in arguments):
            arguments = [*arguments, "-v"]
        env = dict(os.environ, ANSIBLE_CALLBACK_RESULT_FORMAT="json", ANSIBLE_CALLBACK_FORMAT_PRETTY="false")
        child = pexpect.spawn(NAVIGATOR, arguments, env=env, encoding="utf-8", echo=False, timeout=None)
        # Ansible 2.21 repeats its prompt as a banner after reading the answer.
        answered = None
        events = [STEP_PROMPT, r"\r?\n", pexpect.EOF, pexpect.TIMEOUT]
        frames = cycle("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        scanner = cycle((*range(7), *range(7, 0, -1)))
        spinner_visible = False
        clear_line = "\r\x1b[2K"
        try:
            while True:
                animate = self.task_started is not None and self.use_color and sys.stdout.isatty()
                timeout = 0.12 if animate else None
                event = child.expect(events, timeout=timeout)
                if event == 3:
                    elapsed = time.monotonic() - self.task_started
                    position = next(scanner)
                    track = self.paint("░" * position, "muted") + self.paint("█", "heading")
                    track += self.paint("░" * (7 - position), "muted")
                    activity = self.paint(f"  │ {next(frames)} Running…", "caption")
                    timer = self.paint(f"{elapsed:.1f}s", "muted")
                    if display_width(activity + track + timer) + 4 <= self.width:
                        activity += f"  {track}"
                    activity += f"  {timer}"
                    print(clear_line + activity, end="", flush=True)
                    spinner_visible = True
                    continue
                if spinner_visible:
                    print(clear_line, end="", flush=True)
                    spinner_visible = False
                self.show_output(child.before)
                if event == 2:
                    break
                if event == 0:
                    name = child.match[1]
                    if name == answered:
                        child.expect(r"\r?\n")
                        answered = None
                    else:
                        child.sendline(self.approve(name))
                        answered = name
        except (EOFError, KeyboardInterrupt):
            child.sendintr()
            return 130
        finally:
            if spinner_visible:
                print(clear_line, end="", flush=True)
            self.close_panel()
            child.close()
        exit_code = child.exitstatus if child.exitstatus is not None else 128 + child.signalstatus
        label, tone = ("✔ RUN COMPLETE", "ok") if exit_code == 0 else ("✖ RUN FAILED", "error")
        badge = self.paint(f" {label} ", "button_text", tone, bold=True)
        duration = self.paint(f"Session {time.monotonic() - run_started:.1f}s  ·  Exit {exit_code}", "muted")
        print()
        for line in wrap_display(f"{badge}  {duration}", self.width - 2):
            print(f"  {line}")
        print()
        return exit_code


def run_team_playbook(arguments, playbook):
    if "--enable-prompts" in arguments and "--step" in arguments and sys.stdin.isatty():
        play, = yaml.safe_load(playbook.read_text(encoding="utf-8"))
        return Walkthrough(play["tasks"]).run(arguments)
    return subprocess.run([NAVIGATOR, *arguments]).returncode


def main(arguments):
    if len(arguments) >= 2 and arguments[0] == "run":
        playbook = Path(arguments[1])
        team = os.environ.get("LAB_TEAM")
        if team in ("blue_team", "red_team") and playbook.parts[:1] == ("playbooks",):
            playbook = Path(team) / playbook
            arguments = [arguments[0], str(playbook), *arguments[2:]]
        parts = playbook.parts
        if len(parts) >= 3 and parts[0] in ("blue_team", "red_team") and parts[1] == "playbooks":
            if len(parts) == 4 and parts[2] == "demo":
                return run_team_playbook(arguments, playbook)
            if len(parts) == 3:
                try:
                    with team_inventory(parts[0]) as inventory:
                        args = [*arguments[:2], "-i", str(inventory), *arguments[2:]]
                        return run_team_playbook(args, playbook)
                except ValueError as error:
                    print(error, file=sys.stderr)
                    return 2
    os.execvp(NAVIGATOR, [NAVIGATOR, *arguments])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
