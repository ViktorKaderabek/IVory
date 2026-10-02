# PoGo Inventory Manager

Mac aplikace, která za tebe uklidí box v Pokémon GO na iPhonu:

1. **Duplicity:** projde uložené hledání (třeba `duplicit`), stejné Pokémony pozná podle obrázku, u každého změří IV z appraisalu a horším kusům dá tag **Removable**. Nejlepšího nechá.
2. **IV tagy:** projde celý box a každého Pokémona zařadí podle IV do tvých tagů (`100% Perfect`, `95-99% Insane`, … `70-0% Garbage`).

Nic nepřevádí profesorovi. Jen taguje, převod uděláš sám ve hře (hledání `#Removable` → vybrat vše → Transfer).

> ⚠️ Automatizace porušuje podmínky použití Pokémon GO. Používáš na vlastní riziko. Projekt není nijak spojen s Niantic ani The Pokémon Company.

## Jak to funguje

- iPhone se ovládá přes **Appium + WebDriverAgent** (stejná technika jako automatické testy iOS aplikací).
- Obraz chodí jako video stream (~15 snímků/s), text čte **Apple Vision** (OCR) přímo na Macu.
- IV se čtou z barů appraisalu po pixelech. Červeno-růžový bar = 15, jinak se měří délka oranžové výplně.
- Skript pozná ~15 obrazovek hry, takže se odkudkoliv vrátí do boxu. Když se něco pokazí (popup, pád hry, spadlé spojení), vzpamatuje se a pokračuje.
- **Pojistka:** před každým klepnutím zkontroluje, že poblíž není `TRANSFER`, `EVOLVE`, `POWER UP` ani `YES`. Potvrzovací dialogy vždy zruší (`CANCEL` / `NO`).

## Co potřebuješ

- Mac s macOS 14 nebo novějším
- **Xcode** (App Store) a v něm přihlášené Apple ID (Xcode → Settings → Accounts). Stačí bezplatný účet, podpis WebDriverAgentu ale vydrží jen 7 dní.
- **Homebrew** a **Node.js**: `brew install node`
- iPhone připojený kabelem, odemčený, s **Režimem pro vývojáře** (Nastavení → Soukromí a zabezpečení) a důvěrou k počítači
- Ve hře uložené hledání (výchozí název `duplicit`), například:
  ```
  count & !legendary & !ultra beasts
  ```
  Další výjimky můžeš připsat (`& !shiny & !lucky & !costume & !megaevolve …`). Skript porovnává jen to, co hledání ukáže.

Appium, jeho iOS driver a Python knihovny si spouštěč při prvním startu nainstaluje sám (do `~/.pogo/venv`).

## Instalace

```bash
git clone https://github.com/ViktorKaderabek/pogo-inventory-manager.git
cd pogo-inventory-manager
bash app/build_app.sh --install
```

Aplikace se objeví v `~/Applications/PoGo Inventory Manager.app` (bez `--install` zůstane v `dist/`).

## Použití

**Aplikace:** jedna obrazovka, jedno velké tlačítko.

1. Vyber, co udělat: *Duplicity + IV tagy*, *Jen duplicity*, nebo *Jen IV tagy*.
2. Klikni na **Spustit** (nebo Enter). Nahoře uvidíš, co se právě děje, pod tím dlaždice se změřenými a otagovanými kusy a postup obou fází. Podrobný výpis je schovaný pod *Podrobnosti*.
3. **Zastavit** běh korektně ukončí a výsledky se uloží. Složka s výsledky je pod ikonou složky vpravo nahoře.

**Nastavení** (ozubené kolečko vpravo nahoře) vyjede z boku: uložené hledání, tag pro horší kusy, kolik nejlepších nechat, IV tagy s hranicemi v procentech a iPhone (UDID, Apple Team ID). Ukládá se samo.

**Terminál** (bez aplikace):

```bash
bash scripts/run.sh             # obě části
bash scripts/run.sh --no-iv     # jen duplicity
bash scripts/run.sh --only-iv   # jen IV tagy
bash scripts/run.sh --fresh     # IV změřit znovu (nepoužít paměť)
```

Nebo dvojklik na `Start.command`.

## Nastavení (`~/.pogo/config.json`)

| Klíč | Výchozí | Význam |
|---|---|---|
| `udid` | prázdné | iPhone; prázdné = první připojený |
| `team_id` | prázdné | Apple Team ID pro podpis WebDriverAgentu; prázdné = z certifikátu „Apple Development“ |
| `saved_search` | `duplicit` | název uloženého hledání ve hře |
| `remove_tag` | `Removable` | tag pro horší duplicity (když neexistuje, založí se) |
| `keep_best` | `1` | kolik nejlepších z každé várky nechat |
| `iv_tags` | 7 tagů | `[{"min": 95, "name": "95-99% Insane"}, …]`: Pokémon dostane první tag, jehož hranici splní (součet IV / 45) |
| `recheck_tagged` | `false` | `false` = kdo už má jeden IV tag, toho přeskočí |
| `iv_cache_hours` | `6` | jak dlouho platí změřená IV (rychlý opakovaný běh) |
| `max_groups` | `0` | max. počet várek duplicit (0 = všechny) |

## Kde co je

| Cesta | Obsah |
|---|---|
| `~/.pogo/config.json` | nastavení z aplikace |
| `~/.pogo/pamet.json` | změřená IV (pár hodin) a komu už byl dán tag Removable. **Nemaž**, dokud máš v boxu otagované kusy: podle něj je skript znovu nevybírá (klepnutí by tag odškrtlo). |
| `~/.pogo/venv` | Python prostředí |
| `~/Desktop/pogo_runs/<datum_čas>/` | výsledky běhu: `log.txt`, `result.json`, `result_iv_tagy.json`, `iv/` (výřezy barů), `chyba_XX/` (snímky, když se něco pokazilo) |

## Struktura projektu

```
app/        Mac aplikace (SwiftUI) + build skript a ikona
core/       bot v Pythonu (pogo_bot.py) a jeho závislosti
scripts/    run.sh: připraví prostředí, spustí Appium a bota
tests/      simulátory telefonu a testy (viz tests/README.md)
Start.command  spuštění dvojklikem bez aplikace
```

## Řešení problémů

- **„Nevidím připojený iPhone“:** odemkni ho, připoj kabelem, potvrď *Důvěřovat*. Zapni Režim pro vývojáře.
- **WebDriverAgent se nepodepíše:** zkontroluj Team ID v nastavení. Bezplatný podpis platí 7 dní, pak se WDA musí podepsat znovu (Appium to zkusí sám při startu).
- **Skript se zasekne nebo klikne vedle:** ve složce `chyba_XX` posledního běhu jsou snímky posledních kroků i s vyznačeným klepnutím.
- **Hra v jiném jazyce:** texty z UI hry jsou v `core/pogo_bot.py` ve slovníku `L`.
