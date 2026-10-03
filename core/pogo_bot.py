#!/usr/bin/env python3
"""
IVory bot entry point. The bot drives Pokémon GO on an iPhone through Appium / WebDriverAgent;
the code lives in the ivory package (core/ivory/) and this file only calls runner.main().

Setup (once per run):
  opens the tag list in the game and checks that every tag from the settings exists. Missing
  tags are created (Add New Tag -> name -> color -> confirm).

Part 1 – duplicates:
  1) gets to the storage from anywhere in the game (Poké Ball -> POKÉMON), types SEARCH_QUERY
     into the Search field and sorts by number
  2) goes through the storage top to bottom and recognizes groups of the same Pokémon BY THE SPRITE
  3) measures the IVs of each one from the appraisal (attack/defense/HP)
  4) keeps the best one and gives the others the TAG_NAME tag (multi-select -> TAG)

Part 2 – the whole storage (no search):
  puts every Pokémon into one of the IV_TAGS tags by its IVs (detail screen -> ≡ -> TAG).
  Pokémon that already have the TAG_NAME tag or exactly one IV tag are skipped.

Whenever anything goes wrong (another screen, a popup, a dropped connection, a frozen game),
the bot works out where it is, returns to the storage and carries on where it left off. It never
taps TRANSFER / EVOLVE / POWER UP (every tap is checked for that).

Settings are read from ~/.pogo/config.json (edited by the app); anything missing there falls
back to the defaults in core/ivory/config.py.

  python pogo_bot.py                  # both parts
  python pogo_bot.py --no-iv          # duplicates only
  python pogo_bot.py --only-iv        # only the whole storage into IV tags
  python pogo_bot.py --fresh          # don't use IVs from memory, measure again
  python pogo_bot.py --steps duplicates,iv,pvp,rename   # chosen steps (what the app uses)

PvP league tags and renaming run only when chosen with --steps.

Normally started through scripts/run.sh (sets up Appium and Python) or from the app.
With POGO_EVENTS=1 it also sends the app machine-readable events ("@@{json}" lines);
with POGO_LIVE=1 it saves the latest screenshot to ~/.pogo/live.jpg (live preview in the app).
"""

import sys

from ivory.runner import main


if __name__ == "__main__":
    sys.exit(main())
