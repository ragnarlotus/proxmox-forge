#!/usr/bin/env python3
"""Compact, terminal-only presentation of Forge update output.

The update workflow still owns execution, exit codes, backups and full target/run
logs. This process only consumes its stdout/stderr and never writes to those logs.
"""

import os
import re
import select
import shutil
import sys
import time
from urllib.parse import unquote

STAGES = {
    "requirements": "Comprobando requisitos",
    "backup": "Creando copia de seguridad",
    "snapshot": "Creando snapshot",
    "resource_apply": "Preparando recursos",
    "os_update": "Actualizando sistema operativo",
    "held_packages": "Revisando paquetes retenidos",
    "application_update": "Actualizando aplicación",
    "custom_scripts": "Ejecutando scripts personalizados",
    "resource_restore": "Restaurando recursos",
    "health": "Verificando servicios",
    "fstrim": "Optimizando almacenamiento",
    "recovery": "Restaurando desde copia de seguridad",
    "startup": "Iniciando contenedor",
    "shutdown": "Restaurando estado inicial",
}

CONTROL = re.compile(r"\x1b(?:\][^\x07]*(?:\x07|\x1b\\\\)|\[[0-?]*[ -/]*[@-~]|[@-_])")
RESULT = re.compile(r"^result_target ")
LXC_ID = re.compile(r"^type=lxc vmid=([0-9]+) name=([A-Za-z0-9_.-]+) ")


def fields(line):
    result = {}
    for token in line.split():
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value
    return result


def safe_text(value, limit=240):
    value = CONTROL.sub("", value)
    value = "".join(c if c.isprintable() else " " for c in value)
    value = " ".join(value.split())
    return value[:limit]


def duration_text(seconds):
    seconds = max(0, int(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours} h {minutes} m {seconds} s"
    if minutes:
        return f"{minutes} m {seconds} s"
    return f"{seconds} s"


class Progress:
    def __init__(self, mode, target):
        self.tty = sys.stdout.isatty()
        self.color = self.tty and "NO_COLOR" not in os.environ
        self.mode = mode
        self.target = target
        self.total = 1 if mode != "bulk" else None
        self.started = {}
        self.completed = {}
        self.names = {"HOST": "Host Proxmox"}
        self.current = None
        self.stage = "Comprobaciones previas"
        self.notices = []
        self.global_status = None
        self.rendered_lines = 0
        self.last_output = 0
        self.last_snapshot = None
        self.run_id = os.environ.get("FORGE_RUN_ID", "")
        if mode == "host":
            self.begin("HOST")
        elif mode == "lxc":
            self.names[target] = f"LXC {safe_text(target, 40)}"
            self.begin(target)
        self.render(force=True)

    def name(self, key):
        if key == "HOST":
            return self.names[key]
        name = self.names.get(key)
        return f"{key} · {name}" if name else f"LXC {key}"

    def begin(self, key):
        if key in self.completed:
            return
        self.started.setdefault(key, time.monotonic())
        self.current = key
        self.stage = "Comprobando requisitos"

    def finish(self, key, status, exit_code=None):
        if key in self.completed:
            previous = self.completed[key]
            if previous[0] != status:
                self.completed[key] = (status, previous[1], exit_code)
            return
        elapsed = time.monotonic() - self.started.get(key, time.monotonic())
        self.completed[key] = (status, round(elapsed), exit_code)
        if self.current == key:
            self.current = None
            self.stage = "Preparando siguiente objetivo"

    def parse(self, raw):
        line = safe_text(raw.decode("utf-8", "replace"), 2000)
        if not line:
            return
        changed = False

        if line.startswith("update_all=start "):
            info = fields(line)
            if info.get("lxc_targets", "").isdigit():
                self.total = int(info["lxc_targets"]) + (info.get("update_host") == "true")
            self.stage = "Iniciando actualizaciones"
            changed = True
        elif line == "update_all_stage=start stage=host":
            self.begin("HOST")
            changed = True
        elif line.startswith("update_all_target=start "):
            key = fields(line).get("vmid")
            if key and key.isdigit():
                self.begin(key)
                changed = True
        elif line.startswith("update_all_stage=") and "stage=host" in line:
            if line.startswith("update_all_stage=success "):
                self.finish("HOST", "OK")
                changed = True
            elif line.startswith("update_all_stage=failed "):
                self.finish("HOST", "ERROR", fields(line).get("exit_code"))
                changed = True
        elif line.startswith("update_all_target="):
            key = fields(line).get("vmid")
            if key and key.isdigit():
                if line.startswith("update_all_target=success "):
                    self.finish(key, "OK")
                    changed = True
                elif line.startswith("update_all_target=failed "):
                    self.finish(key, "ERROR", fields(line).get("exit_code"))
                    changed = True
        elif line.startswith("stage=start name="):
            stage = fields(line).get("name", "")
            self.stage = STAGES.get(stage, safe_text(stage.replace("_", " ").capitalize(), 55))
            changed = True
        elif line.startswith("custom_script=start "):
            name = fields(line).get("script", "")
            self.stage = "Ejecutando " + safe_text(os.path.basename(name), 45)
            changed = True
        elif line.startswith("result_global "):
            self.global_status = fields(line).get("status")
            changed = True
        elif RESULT.match(line):
            info = fields(line)
            key = "HOST" if info.get("type") == "host" else info.get("vmid", "")
            if info.get("name") and key:
                self.names[key] = ("Host Proxmox" if key == "HOST"
                                   else safe_text(info["name"].replace("_", " "), 38))
            if info.get("attempted") == "true" and info.get("status") in ("OK", "ERROR"):
                self.finish(key, info["status"], info.get("exit_code"))
                changed = True
            if info.get("status") == "ERROR" and info.get("result_detail"):
                detail = safe_text(unquote(info["result_detail"]), 180)
                self.notice(f"{self.name(key)}: {detail}")
                changed = True
        else:
            match = LXC_ID.match(line)
            if match:
                key, name = match.groups()
                self.names[key] = safe_text(name.replace("_", " ").replace("-", " "), 38)
                changed = True
            elif line.startswith("update=success ") or line.startswith("update=failed "):
                if self.mode != "bulk":
                    info = fields(line)
                    key = "HOST" if info.get("type") == "host" else info.get("vmid", self.target)
                    self.finish(key, "OK" if line.startswith("update=success ") else "ERROR",
                                info.get("exit_code"))
                    changed = True
            elif line.startswith(("WARNING:", "ERROR:", "NOTICE:", "FATAL:")):
                self.notice(line)
                changed = True
            elif line.startswith("reboot_required=yes "):
                if "type=host" in line:
                    self.notice("Host Proxmox: reinicio necesario para activar el kernel nuevo")
                    changed = True

        if changed:
            self.render(force=True)

    def notice(self, message):
        message = safe_text(message, 180)
        if message and message not in self.notices:
            self.notices.append(message)
            self.notices = self.notices[-6:]

    def colored(self, text, color):
        if self.color:
            return f"\x1b[{color}m{text}\x1b[0m"
        return text

    def rows(self):
        cols, height = shutil.get_terminal_size((90, 24))
        width = max(48, cols - 1)
        finished = len(self.completed)
        total = self.total or 0
        percent = int(finished * 100 / total) if total else 0
        bar_width = max(10, min(26, width - 48))
        filled = int(bar_width * percent / 100)
        bar = "█" * filled + "░" * (bar_width - filled)
        if self.total is None:
            progress = "Preparando objetivos"
        else:
            progress = f"{finished}/{total} completados · {percent}%"
        lines = [
            self.colored("Forge — Actualización del sistema", "1;36"),
            f"{progress}   [{bar}]",
            "",
        ]
        capacity = max(2, min(14, height - 9))
        completed = list(self.completed.items())
        if len(completed) > capacity:
            lines.append(f"  … {len(completed) - capacity} objetivos anteriores")
        for key, (status, duration, code) in completed[-capacity:]:
            marker = self.colored("✓", "32") if status == "OK" else self.colored("✗", "31")
            title = safe_text(self.name(key), max(12, width - 24))
            seconds = duration_text(duration)
            suffix = f" (exit {code})" if code and status == "ERROR" else ""
            lines.append(f"  {marker} {title} — {seconds}{suffix}")
        if self.current is not None:
            elapsed = duration_text(time.monotonic() - self.started[self.current])
            title = safe_text(self.name(self.current), max(12, width - 24))
            lines += ["", f"  {self.colored('→', '36')} {title} — {self.stage} · {elapsed}"]
        elif self.global_status:
            color = "32" if self.global_status == "SUCCESS" else "31"
            lines += ["", self.colored("Resultado: " + self.global_status, color)]
        else:
            lines += ["", self.stage]
        if self.notices:
            lines += ["", "Avisos:"]
            lines.extend("  ! " + m[:max(10, width - 5)] for m in self.notices[-2:])
        return lines, width

    def render(self, force=False):
        now = time.monotonic()
        if not force and now - self.last_output < 0.9:
            return
        lines, width = self.rows()
        if not self.tty:
            snapshot = (self.current, self.stage, len(self.completed), self.global_status,
                        tuple(self.notices))
            if snapshot == self.last_snapshot:
                return
            if self.current is not None:
                text = f"Forge: {self.name(self.current)} — {self.stage}"
            elif self.completed:
                key = next(reversed(self.completed))
                status, duration, _ = self.completed[key]
                text = f"Forge: {self.name(key)} {status} ({duration_text(duration)})"
            else:
                text = "Forge: comprobaciones previas"
            if self.global_status:
                text = f"Forge: resultado {self.global_status}"
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
            self.last_snapshot = snapshot
            return

        if self.rendered_lines:
            sys.stdout.write(f"\x1b[{self.rendered_lines}A\r\x1b[0J")
        for row in lines:
            # Clip before colour rendering; own escape sequences are not user input.
            plain_length = len(CONTROL.sub("", row))
            if plain_length > width:
                row = row[:width - 1] + "…"
            sys.stdout.write("\x1b[2K" + row + "\n")
        sys.stdout.flush()
        self.rendered_lines = len(lines)
        self.last_output = now

    def close(self):
        if self.current is not None:
            self.stage = "Sin resultado final; consultar registro"
        self.render(force=True)
        if self.tty:
            sys.stdout.write("\n")
        if self.run_id:
            sys.stdout.write(f"Detalles: forge history {safe_text(self.run_id, 80)}\n")
        sys.stdout.flush()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("bulk", "host", "lxc"):
        raise SystemExit("usage: progress.py bulk|host|lxc TARGET")
    dashboard = Progress(sys.argv[1], sys.argv[2])
    pending = bytearray()
    while True:
        readable, _, _ = select.select([sys.stdin.fileno()], [], [], 1.0)
        if not readable:
            dashboard.render()
            continue
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            break
        for byte in chunk:
            if byte in (10, 13):
                if pending:
                    dashboard.parse(bytes(pending))
                    pending.clear()
            elif len(pending) < 65536:
                pending.append(byte)
    if pending:
        dashboard.parse(bytes(pending))
    dashboard.close()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, OSError) as exc:
        print(f"ERROR: Forge progress presenter failed: {exc}", file=sys.stderr)
        sys.exit(1)
