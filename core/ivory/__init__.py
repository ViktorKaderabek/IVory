"""The IVory bot: drives Pokémon GO on an iPhone to tag duplicates, sort the storage into IV tags,
give PvP league tags, rename Pokémon and sweep the weak ones.

core/pogo_bot.py is the entry point; runner.main() does the work. The modules below are layered –
each one only imports from the ones above it.

Settings and plumbing
  config        every setting, and the game's UI strings (overridden by ~/.pogo/config.json)
  errors        the exceptions that steer a run (a step failed / go back to the top / stop)
  output        the log, the events the app draws its progress from, Czech/English wording
  timing        where a run spends its time (the ⏱ breakdown in the log)
  settings      applies ~/.pogo/config.json over the defaults
  calibration   what the bot learns about the phone and keeps between runs

Looking at the screen
  vision        text recognition (Apple Vision) and one screen frame
  bars          the three IV bars in the appraisal, measured from the pixels
  grid          the storage grid: cells, sprites, names, groups of the same species
  pixels        the checks that look at colors instead of text
  read_detail   what the Pokémon detail screen and the appraisal say
  read_box      what the storage says: counts, the Search field, sorting, multi-select
  read_dialog   the dialogs the bot has to recognize so it can answer them
  screens       which of those screens the bot is looking at

Driving the phone
  stream        the iPhone screen as an MJPEG video stream
  device        the Bot: frames, taps, drags, typing, and the safety check before every touch
  session       connecting to the iPhone (Appium / WebDriverAgent) and restarting the game
  detail        opening a Pokémon and reading its IVs from the appraisal
  scroll        reading the grid and scrolling it
  search        the Search field: which search is applied, and typing in the one that's needed
  navigate      getting to the storage from anywhere in the game

Keeping what was read
  records       one Pokémon's record, the duplicate decisions, the memory file
  report        the summary written into the results folder
  monrec        species, level and name-template values of a Pokémon that was read

Tags in the game
  ivtags        tag names: which IV tag an IV belongs in, and the chips a Pokémon wears
  taglist       the in-game tag picker: finding a tag's row, checking and unchecking it
  tagcreate     checking a tag, and creating it when the game doesn't have it yet
  tagcheck      before a run: every tag the chosen steps need must exist

Reading the whole storage
  scanstate     one pass over a list in progress: what is read and what is still to do
  gridscan      the list read by scrolling, stitched together without duplicate rows
  locate        finding an entry of that list on the screen again
  nextmon       moving to the next Pokémon inside the appraisal (the ▶ arrow)
  ivscan        the IV and tags of every Pokémon in the list
  batch         bulk tagging through an in-game CP search and multi-select
  batch_passes  running the bulk taggings a step planned
  memory_box    reusing the previous run's memory, and writing it back
  inventory     making sure the whole storage is read (memory + whatever is missing)
  classic_tags  slow mode: the tag picker on one Pokémon at a time
  classic       slow mode: going through the storage screen by screen

The steps of a run
  step_dupes    duplicates -> the transfer tag on the worse ones
  step_tags     IV tags, PvP league tags, Battle tags, the weak-Pokémon sweep
  step_rename   names built from the template
  phases        one run, phase by phase, with the retries
  runner        the command line
"""
