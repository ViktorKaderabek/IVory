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
| `sim5.py` | **bez screenshotů** – všechny obrazovky si kreslí sám: napsání hledání, kontrola a zakládání tagů v barvách (několik podob dialogu), duplicity, IV tagy včetně odebrání nesedících, PvP tagy, přejmenování, zavření inventáře tahem dolů. Scénář `realny_telefon` se chová jako skutečný iPhone (seznam ujede 1,6× dál než prst, větší box s legendami, CP v appraisalu občas nečitelné, na posledním Pokémonovi šipka ▶ chybí), `zdvojeny_seznam` vloží do seznamu zdvojené buňky, `multiselect_ujede` posouvá výběr více Pokémonů o kus dál, než má, `realny_vse` dělá všechny čtyři kroky na velkém boxu jako skutečný iPhone, `jen_duplicity` taguje přes hledání podle CP spojené s hledáním duplicit, `cp_v_davce_chybi` a `hledani_nic_nenajde` mají kus se špatně přečteným CP (v dávce chybí / hledání nenajde nic – bot ho přeskočí a zbytek otaguje), `tag_uz_maji` po DONE nechá výběr tagů viset a fajfky kreslí se zpožděním (při opakované dávce nesmí bot tag odškrtnout), `opakovany_beh` a `opakovany_beh_realny` pustí bota dvakrát se stejnou pamětí a mezi běhy přidají nově chycenou Eevee (druhý běh čte jen ji), `opakovany_beh_dlouha_jmena` navíc přejmenuje všechny kusy na dlouhá jména („MAX 3351 L15“), která OCR jako na iPhonu slévá se sousední buňkou do jednoho textu – druhý běh je přesto musí poznat z paměti a přečíst nejvýš 4 kusy. `dvojcata_stejne_cp` má dva Kyogre se stejným CP, které hledání ukáže v opačném pořadí než celý seznam – bot si v detailu ověří CP, jméno a HP a každý dostane jméno spočítané ze svých IV. Hledání vyhodnocuje jako hra: `cpN`, čárka = nebo, `&` = a zároveň, `!` = ne. V hlavičce ukazuje při hledání počet výsledků „🔍(n)“ |
| `sim5_screens.py` | jak bot pozná každou obrazovku ze `sim5.py` |

Screenshoty ze hry **nejsou součástí repozitáře** (je na nich jméno trenéra a poloha).
Testy je berou ze složky s výsledky běhů (`~/Desktop/pogo_runs`), jinou složku nastavíš
proměnnou `POGO_SCREENS`. Názvy souborů odpovídají běhům z října 2026, na jiném
počítači je potřeba vlastní sada screenshotů.

`sim5.py` jede kdekoliv (stačí Python z `build/runtime`, viz `scripts/build_runtime.sh`):

```bash
cd tests
../build/runtime/python/bin/python3 sim5.py            # všechny scénáře
../build/runtime/python/bin/python3 sim5.py verbose    # jeden scénář s výpisem bota
```

Starší simulátory potřebují screenshoty:

```bash
cd tests
~/.pogo/venv/bin/python sim4.py verbose
~/.pogo/venv/bin/python -c "import sim2; sim2.run(1, 0.02, 0.04)"
```
