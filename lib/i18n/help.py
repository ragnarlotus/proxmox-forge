#!/usr/bin/env python3
"""Present supported Forge commands in the configured UI language."""

from translate import tr

COMMANDS = (
    ("validate-config", "validate"),
    ("show-config", "show"),
    ("status [--json]", "status"),
    ("history [RUN_ID] [--json]", "history"),
    ("host update", "host"),
    ("lxc list-targets", "list"),
    ("lxc update TARGET [TARGET...]", "lxc"),
    ("lxc update all", "lxc_all"),
    ("update all", "all"),
    ("update scheduled", "scheduled"),
    ("self-update [BRANCH]", "self"),
    ("back", "back"),
    ("help", "help"),
)

print(tr("cli.help.title"))
print()
print(tr("cli.help.commands"))
for command, key in COMMANDS:
    print(f"  {command:<29} {tr('cli.help.' + key)}")
