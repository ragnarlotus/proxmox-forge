#!/usr/bin/env python3
"""Translate presentation labels; never mutate structured results or diagnostics.

The versioned English catalogue is authoritative. Unknown keys and missing
translations fall back to English. The validated Forge configuration supplies
FORGE_LANGUAGE; external stage stdout/stderr is intentionally not translated.
"""

import json
import os
import sys
from functools import lru_cache
from pathlib import Path

SUPPORTED = ("en", "es")
CATALOGUE_DIR = Path(__file__).resolve().parent


@lru_cache(maxsize=2)
def load(language):
    if language not in SUPPORTED:
        language = "en"
    path = CATALOGUE_DIR / f"{language}.json"
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not all(
        isinstance(k, str) and isinstance(v, str)
        for k, v in data.items()
    ):
        raise ValueError(f"invalid Forge translation catalogue: {path}")
    return data


def language():
    selected = os.environ.get("FORGE_LANGUAGE", "en")
    return selected if selected in SUPPORTED else "en"


def tr(key, lang=None, **kwargs):
    chosen = lang if lang in SUPPORTED else language()
    template = load(chosen).get(key) or load("en").get(key, key)
    return template.format(**kwargs)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: translate.py KEY [ARG=VALUE ...]")
    key = sys.argv[1]
    options = {}
    for argument in sys.argv[2:]:
        name, sep, value = argument.partition("=")
        if not sep or not name.isidentifier():
            raise SystemExit("translation arguments must be NAME=VALUE")
        options[name] = value
    print(tr(key, **options))


if __name__ == "__main__":
    main()
