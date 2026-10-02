# Testy a simulátory

Testy běží bez telefonu: jádro (`core/pogo_bot.py`) dostává místo iPhonu „falešný telefon“,
který vrací skutečné screenshoty ze hry a podle klepnutí přepíná obrazovky.

| Soubor | Co testuje |
|---|---|
| `test_screens2.py` | rozpoznání obrazovek na všech uložených screenshotech |
| `test_logic.py` | pojistku proti TRANSFER/EVOLVE, mřížku boxu, skupiny podle obrázku |
| `test_bars.py` | čtení IV z barů appraisalu (proti ručně ověřeným hodnotám) |
| `sim.py` | navigace do boxu z 12 různých obrazovek, měření a tagování |
| `sim2.py` | syntetický box se 39 Pokémony, scrollování, velká skupina, výpadky |
| `sim3.py` | založení chybějícího tagu (Add New Tag → Enter tag name → Done) |
| `sim4.py` | obě části: duplicity → Removable, celý box → IV tagy, s výpadky |

Screenshoty ze hry **nejsou součástí repozitáře** (je na nich jméno trenéra a poloha).
Testy je berou ze složky s výsledky běhů (`~/Desktop/pogo_runs`), jinou složku nastavíš
proměnnou `POGO_SCREENS`. Názvy souborů odpovídají běhům z října 2026, na jiném
počítači je potřeba vlastní sada screenshotů.

```bash
cd tests
~/.pogo/venv/bin/python sim4.py verbose
~/.pogo/venv/bin/python -c "import sim2; sim2.run(1, 0.02, 0.04)"
```
