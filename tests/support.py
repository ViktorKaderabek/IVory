"""Shared setup for the simulators: the bot package as one namespace, `S`.

Puts core/ on the import path. The simulators read and patch the bot as `S.name`, as they did
when it was a single module. Reading `S.name` returns the object from core/ivory, and assigning
`S.name = value` replaces it in every module that has it. A patched setting or function
(MEMORY_FILE, log, ocr, grid_scan, ...) therefore takes effect everywhere.
"""
import importlib
import pkgutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core"))

import ivory  # noqa: E402  (needs the path above)

MODULES = [importlib.import_module(f"ivory.{m.name}") for m in pkgutil.iter_modules(ivory.__path__)]


class _Namespace:
    def __getattr__(self, name):
        for mod in MODULES:
            if name in vars(mod):
                return vars(mod)[name]
        raise AttributeError(name)

    def __setattr__(self, name, value):
        mods = [mod for mod in MODULES if name in vars(mod)]
        if not mods:
            raise AttributeError(name)
        for mod in mods:
            setattr(mod, name, value)


S = _Namespace()
