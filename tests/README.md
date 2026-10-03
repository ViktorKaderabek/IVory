# Tests and simulators

The tests run without a phone: instead of an iPhone, the bot (`core/ivory`, started by `core/pogo_bot.py`)
gets a "fake phone" that returns game screens and switches between them according to the taps.
The older simulators use real game screenshots; `sim_synthetic.py` draws every screen itself.

| File | What it tests |
|---|---|
| `test_screens.py` | screen recognition on all saved screenshots |
| `test_logic.py` | the safety guard against TRANSFER/EVOLVE, the storage grid, groups by sprite |
| `test_bars.py` | reading IVs from the appraisal bars (against hand-checked values) |
| `sim_navigation.py` | getting into the storage from 12 different screens, measuring and tagging |
| `sim_box.py` | a synthetic storage with 39 Pokémon: scrolling, a large group, glitches |
| `sim_new_tag.py` | creating a missing tag (Add New Tag → Enter tag name → Done) |
| `sim_full_run.py` | both parts: duplicates → Removable, then the whole storage → IV tags, optionally with glitches |
| `sim_synthetic.py` | **no screenshots needed**: draws every screen itself (see below) |
| `sim_synthetic_screens.py` | how the bot classifies each screen drawn by `sim_synthetic.py` |

`support.py` is shared setup: it puts `core/` on the import path and exposes the whole bot package
as one namespace, `S`, so the simulators can read and patch any setting or function in one place.

## The synthetic simulator

`sim_synthetic.py` covers the whole run: typing the search, checking and creating tags in their colors
(in several forms of the new-tag dialog), duplicates, IV tags including removing ones that don't fit,
PvP tags, renaming, and closing the storage by swiping down. It evaluates searches like the game does:
`cpN`, a comma = or, `&` = and, `!` = not. During a search the header shows the result count "🔍(n)".

| Scenario | What it simulates |
|---|---|
| `basic` | the default phone, all four steps |
| `keyboard_auto` | the keyboard opens by itself in the new-tag dialog |
| `enter_creates_tag` | Enter in the new-tag dialog creates the tag right away |
| `colors_in_two_rows` | the tag colors are laid out in two rows |
| `new_tag_auto_checked` | a newly created tag gets checked by itself |
| `only_iv_tags` | only the IV tag step |
| `pvp_and_rename` | only the PvP and renaming steps |
| `slow_mode` | the bot's slow mode |
| `no_next_in_appraisal` | the appraisal cannot move on to the next Pokémon (▶ / swipe) |
| `swipe_closes_appraisal` | there is no ▶ arrow and a swipe closes the appraisal |
| `glitches` | random drops to the map and game restarts |
| `only_duplicates` | tags through a CP search combined with the duplicates search |
| `no_select_all` | bigger storage, no SELECT ALL in the search results |
| `real_phone` | behaves like a real iPhone: the list moves 1.6× further than the finger, a bigger storage with legendaries, the CP in the appraisal is sometimes unreadable, the ▶ arrow is missing on the last Pokémon |
| `real_phone_all_steps` | all four steps on the big storage, like a real iPhone |
| `duplicated_list` | inserts duplicated cells and a cell with a nonsense CP into the scanned list |
| `multiselect_overshoots` | scrolling in the multi-Pokémon selection goes further than it should |
| `cp_missing_in_batch` | a Pokémon with a misread CP is missing from a batch; the bot skips it and tags the rest |
| `search_finds_nothing` | a Pokémon with a misread CP: its search finds nothing; the bot skips it and tags the rest |
| `already_tagged` | after DONE the tag picker stays open and the check marks are drawn late; on the repeated batch the bot must not uncheck the tag |
| `rerun` | runs the bot twice with the same memory and adds a newly caught Eevee between the runs; the second run reads only that one |
| `rerun_real_phone` | the same as `rerun`, on a phone that behaves like a real iPhone |
| `rerun_long_names` | also renames every Pokémon to a long name ("MAX 3351 L15") that OCR, as on the iPhone, merges with the neighboring cell into one text; the second run must still recognize them from memory and read at most 4 Pokémon |
| `settings_changed` | the IV tag limits and the name template change between two runs |
| `mixed_tags` | some Pokémon already have the Master League tag, so the selection shows "Mixed" and the bot cannot see the chip |
| `twins_same_cp` | two Kyogre with the same CP that the search shows in the opposite order to the full list; the bot checks CP, name and HP on the detail screen and each gets a name computed from its own IVs |

## Running

`sim_synthetic.py` runs on any Mac, no screenshots needed (the bot reads text with Apple Vision, and the simulator
draws it with the system Arial font). The Python from `build/runtime` is enough (see `scripts/build_runtime.sh`),
or use `~/.pogo/venv/bin/python`:

```bash
cd tests
../build/runtime/python/bin/python3 sim_synthetic.py                    # all scenarios
../build/runtime/python/bin/python3 sim_synthetic.py verbose            # one scenario with the bot's log
../build/runtime/python/bin/python3 sim_synthetic.py real_phone rerun   # only the named scenarios
../build/runtime/python/bin/python3 sim_synthetic_screens.py            # how each drawn screen is classified
```

## Screenshot-based tests

The other tests and simulators need your own screenshots. Game screenshots are **not part of the repository**
(they show the trainer name and location). The tests read them from the folder with the run results
(`~/Desktop/pogo_runs`); set `POGO_SCREENS` to use another folder. The file names refer to the author's runs
from October 2026, so on another computer you need your own set of screenshots with matching names.

These older tests are kept for reference and are not maintained: they predate step selection, so their full
runs stop with an error (their run arguments have no `steps`), and `test_logic.py` calls `read_bar`, which the
bot no longer has (it is `read_bars` now). `sim_synthetic.py` is the supported test suite.

```bash
cd tests
~/.pogo/venv/bin/python sim_full_run.py verbose
~/.pogo/venv/bin/python -c "import sim_box; sim_box.run(1, 0.02, 0.04)"
```
