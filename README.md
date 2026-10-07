<p align="center">
  <a href="https://github.com/ViktorKaderabek/IVory/releases/latest">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="docs/banner-light.svg">
      <img alt="IVory: a Mac app that cleans up your Pokémon GO inventory" src="docs/banner-light.svg" width="100%">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://github.com/ViktorKaderabek/IVory/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/ViktorKaderabek/IVory?label=release&color=796cbf"></a>
  <a href="https://github.com/ViktorKaderabek/IVory/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/ViktorKaderabek/IVory/total?color=5d5294"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555555">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-app-F05138?logo=swift&logoColor=white">
  <img alt="Python 3" src="https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white">
  <img alt="Appium XCUITest" src="https://img.shields.io/badge/Appium-XCUITest-662D91?logo=appium&logoColor=white">
  <a href="LICENSE.md"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-2f8f5b"></a>
</p>

<p align="center">
  <b>Tidy up your Pokémon GO storage from your Mac.</b><br>
  IVory drives the game on a USB-connected iPhone. It tags worse duplicates and weak Pokémon for transfer, sorts the whole
  storage into IV tags, tags good PvP candidates, your raid attackers and your PvP teams, and renames your best Pokémon.
  It never transfers anything by itself.
</p>

<p align="center">
  <a href="https://github.com/ViktorKaderabek/IVory/releases/latest/download/IVory.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/download-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="docs/download-light.svg">
      <img alt="Download IVory for Mac" src="docs/download-light.svg" width="456">
    </picture>
  </a>
</p>

<p align="center">
  <a href="#installation">Installation</a>
  &nbsp;·&nbsp; <a href="#risks-and-responsibility">Risks</a>
  &nbsp;·&nbsp; <a href="#what-it-does">Features</a>
  &nbsp;·&nbsp; <a href="#the-app">The app</a>
  &nbsp;·&nbsp; <a href="#how-fast-is-it">Speed</a>
  &nbsp;·&nbsp; <a href="#how-it-works">How it works</a>
  &nbsp;·&nbsp; <a href="#troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-run-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-run-light.svg">
    <img alt="A whole run in IVory, sped up: Start is pressed, the six steps run one after another while the live card shows the Pokémon being read, and the run ends with a summary" src="docs/app-run-light.svg" width="100%">
  </picture><br>
  <sub>A whole run, sped up: press <b>Start</b>, IVory reads every Pokémon and works through the steps. The live card shows who it is reading right now.</sub>
</p>

## Risks and responsibility

> [!CAUTION]
> **Using IVory can get your Pokémon GO account banned.** Automating the game breaks the Pokémon GO Terms of Service. Niantic can suspend or permanently ban accounts that use automation.

By using IVory you confirm that:

- you understand your account can be suspended or permanently banned,
- you use IVory at your own risk and you alone are responsible for your account,
- the authors are not liable for any loss, including lost accounts, Pokémon or items.

IVory never transfers Pokémon. It only adds tags and nicknames, and it cancels every confirmation dialog. Mistakes are still possible, so check the tags before you transfer anything yourself.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/safety-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/safety-light.svg">
    <img alt="Safety net: TRANSFER, YES, CONFIRM, TRADE, BUY, PURCHASE and RELEASE are never tapped, nor anything in their row; confirmation dialogs are always cancelled" src="docs/safety-light.svg" width="100%">
  </picture>
</p>

The app asks you to confirm this on first launch.

<sub>IVory is not affiliated with, endorsed or sponsored by Niantic, Inc., The Pokémon Company or Nintendo. Pokémon and Pokémon GO are trademarks of their respective owners.</sub>

## What it does

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/steps-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/steps-light.svg">
    <img alt="Six steps: Duplicates, IV tags, PvP tags, Rename, Battle tags, Weak Pokémon. Combine them as you like; they always run in this order" src="docs/steps-light.svg" width="100%">
  </picture>
</p>

IVory runs up to six steps. Combine them as you like; they always run in this order:

| Step | What happens |
|---|---|
| 🗂️ **Duplicates** | Types your search (default `count & !legendary & !ultra beasts`) into the storage, groups identical Pokémon by their picture, reads the IVs of each one from the appraisal and tags the worse ones **`Removable`**. The best one stays untouched. |
| 🏷️ **IV tags** | Goes through the whole storage and puts every Pokémon into an IV tag: `100% Perfect`, `95-99% Insane`, … `70-0% Garbage`. An IV tag that no longer fits is removed. |
| 🏆 **PvP tags** | Pokémon with a good IV rank for a league get `Great League`, `Ultra League` or `Master League` (rank limits 100 / 100 / 50 by default). |
| ✏️ **Rename** | Pokémon in an IV range (85–100 % by default) get a name built from your template, e.g. `91 Bax M30` = 91 % IV, final evolution Baxcalibur, rank 30 in Master League. Custom nicknames are left alone. |
| ⚔️ **Battle tags** | Your best raid attackers (6 per attack type by default) get `Raid`, and the PvP team you pick on the PvP teams screen gets `GL Team`, `UL Team` or `ML Team`. In the game, `#Raid&@steel` then finds your steel attackers. The tag comes off Pokémon that are no longer picked. |
| 🧹 **Weak Pokémon** | Everyone under an IV threshold (70 % by default) gets the same `Removable` tag, so you can transfer them in one go. Safeguards keep the rarer ones: legendary, mythical, Ultra Beasts, regional forms, the best of each species and anything with a PvP or Battle tag. The bot can't tell shadow, lucky or Dynamax apart, so for those you tag them in the game yourself and name that tag in the settings. The tag is only added, never taken off. |

Tags that are missing in the game are created at the start, in the color you picked (the game offers 8 colors).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/anatomy-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/anatomy-light.svg">
    <img alt="One Pokémon, start to finish: IVs 14/13/14 read from the appraisal, 91 % computed, PvP ranks G12 U5 M30, tags and the name 91 Bax M30 written" src="docs/anatomy-light.svg" width="100%">
  </picture>
</p>

> [!IMPORTANT]
> IVory **never transfers anything**. It only tags and renames. The transfer is up to you:
> search `#Removable` in the game → select all → Transfer.

## The app

Six screens in one window, switched from the sidebar. The card at the bottom of the sidebar shows the iPhone and the run on every screen, with **Start** and **Stop** always within reach.

### Storage

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-storage-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-storage-light.svg">
    <img alt="Storage: Pokédex 318 of 951 species, average IV 87 %, 8 hundos, the IV distribution by IV tag and the best Pokémon for each PvP league" src="docs/app-storage-light.svg" width="100%">
  </picture>
</p>

What IVory knows about your storage after a run: Pokédex, average IV, hundos, how your Pokémon spread over the IV tags, and the closest to the best possible IVs for each league. Every Pokémon opens with its picture from the game, its IVs, CP and ranks in all three leagues.

### Raids

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-raids-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-raids-light.svg">
    <img alt="Raids: the current bosses, the best six attackers from your storage against Reshiram and the win chance for 1 to 6 players" src="docs/app-raids-light.svg" width="100%">
  </picture>
</p>

The current raid bosses (from [ScrapedDuck](https://github.com/bigfoott/ScrapedDuck), refreshed once a day) with the six strongest Pokémon from your storage against each one, why each of them works (`Steel 1.6× vs Fairy`), the weather that boosts the boss, and an estimated win chance for 1–6 players.

Under each raid party is the in-game search that finds it among your `Raid`-tagged attackers (`#Raid&@poison,@steel`), with a Copy button. With IVory open, a new raid boss you have a strong party for (or no counters at all) gets a notification; turn it off in Settings → Notifications.

### PvP teams

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-pvp-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-pvp-light.svg">
    <img alt="PvP teams: one team per league with lead, switch and closer, and how the Great League team does against the most played Pokémon" src="docs/app-pvp-light.svg" width="100%">
  </picture>
</p>

All three leagues at a glance (who is in the team, what it still needs), then 3–4 different combinations for the chosen league, because no team beats everything. Pick one and it gets the league's tag in the game. For the picked team you see each member's role (lead, switch, closer), PvPoke score, IV rank, how its CP sits against the league's cap and what powering it up costs, plus a table of how every member does against the league's 10 most played Pokémon (win, close, loss) and which opponents nobody answers.

### Power-ups

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-powerups-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-powerups-light.svg">
    <img alt="Power-ups: the best value first (Azumarill from L44 to L46 for 9,000 stardust), then the power-ups for your PvP teams and for raids" src="docs/app-powerups-light.svg" width="100%">
  </picture>
</p>

Where stardust makes the most difference. A plan of 20 raid power-ups to level 40, best value first: each step is the one that makes your best six of an attack type gain the most per stardust, and it counts the earlier steps as done, so a second Kyurem is measured against the first one already at L40. At most two of the same species, so one species doesn't crowd out every other type. Next to it the members of your tagged PvP teams that are still under the league's cap, cheapest first. Every row opens into the strength (or CP) it gains and the cost step by step, with the stardust, candy and XL candy from the game master.

Raids, PvP teams and Power-ups are estimates from public data, not battle simulations. The bot doesn't read moves, so IVory assumes each species' best moves (check them in the game); it doesn't count shadow or purified attackers, dodging, friendship bonuses or a shadow boss's enrage.

### Settings

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/app-settings-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/app-settings-light.svg">
    <img alt="Settings: language, updates, run results, the iPhone, notifications, advanced options and About" src="docs/app-settings-light.svg" width="100%">
  </picture>
</p>

How each step works (tags, ranges, the name template) is set on **Run**, right next to the step. Settings keeps the rest: language, updates, run results, the iPhone, notifications, advanced options and the risk notice. Everything saves by itself.

Light and dark appearance follow macOS. The app is in English or Czech: it follows your system language and you can switch it any time in Settings, even while sorting.

## How fast is it

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/speed-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/speed-light.svg">
    <img alt="Measured on a real first run with 425 Pokémon: 8.4 s per Pokémon for all four steps, 2.8 s without renaming, 10 s per rename" src="docs/speed-light.svg" width="100%">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/second-run-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/second-run-light.svg">
    <img alt="The second run of the same 425 Pokémon takes 8 minutes instead of 59:51, about 1.1 s per Pokémon and 7.5 times faster, because the bot only reads the Pokémon that are new or have changed" src="docs/second-run-light.svg" width="100%">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/vs-hand-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/vs-hand-light.svg">
    <img alt="IVory compared with checking IVs by hand: about 8 times faster, more than 2 hours saved per 425 Pokémon" src="docs/vs-hand-light.svg" width="100%">
  </picture>
</p>

Renaming takes most of the time on the first run because the game needs a few taps and the keyboard for every name.
Without renaming, a storage of 425 Pokémon is done in about 20 minutes. The second run is much faster: about 8 minutes for the same storage.
What the bot read stays in its memory and is matched to the storage by CP and name, so it only reads the Pokémon that are
new or have changed. The log ends each reading with a ⏱ line that says how long one Pokémon took and where that time went.

## Requirements

| | |
|---|---|
| 💻 **Mac** | macOS 14 Sonoma or later, Apple Silicon or Intel |
| 📱 **iPhone** | **iOS 17.4 or newer**, connected by cable, unlocked and trusted, with **Developer Mode** on and **UI Automation** enabled (see [iPhone setup](#iphone-setup-one-time)) |
| 🍎 **Apple ID** | Any Apple ID, free. IVory signs the helper app that controls the iPhone with it — Apple only allows control of devices belonging to the signing account. |
| 🌐 **Internet** | For the first start, which downloads about 250 MB of tools, once a week for the game data (about 22 MB), and once a day for the raid boss list (a few kB) |

**You don't need Xcode.** Everything else (Node.js, Appium, Python with OpenCV and Apple Vision, and WebDriverAgent itself) **is set up by IVory** on the first start. No Homebrew, no Terminal, no 15 GB download from the App Store.

## Installation

### Download (recommended)

1. Download **[IVory.dmg](https://github.com/ViktorKaderabek/IVory/releases/latest/download/IVory.dmg)** from the [latest release](https://github.com/ViktorKaderabek/IVory/releases/latest).
2. Open it and drag **IVory** into **Applications**.
3. Open IVory from Applications.
   IVory isn't notarized by Apple, so the first time macOS says it can't verify the app.
   Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to IVory.
   You only need to do this once.

   <details>
   <summary>Or from Terminal</summary>

   ```bash
   xattr -dr com.apple.quarantine /Applications/IVory.app
   ```

   </details>
4. Read the risk notice and confirm all three points (only the first time).
5. The **setup guide** opens by itself and takes you through seven steps: connecting the iPhone, Developer Mode,
   UI Automation, your Apple ID, installing, trusting the developer and the first **Start**
   (see [iPhone setup](#iphone-setup-one-time)). It downloads the tools in the background while you go through the
   first steps, and shows each of them:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/setup-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/setup-light.svg">
    <img alt="First start: Node.js 24, Appium 3 with the XCUITest driver, Python 3.12, the Python libraries and WebDriverAgent are set up by IVory itself" src="docs/setup-light.svg" width="100%">
  </picture>
</p>

<details>
<summary><b>What exactly gets installed, and where</b></summary>
<br>

| | What IVory installs | Where |
|---|---|---|
| 1 | Node.js 24 (official build from nodejs.org), only if you don't have Node 20+ already | `~/.pogo/runtime/node` |
| 2 | Appium 3 and its XCUITest driver | `~/.pogo/runtime/node`, `~/.appium` |
| 3 | Python 3.12 ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | `~/.pogo/runtime/python` |
| 4 | Python libraries: Appium client, pymobiledevice3, OpenCV, NumPy, Pillow, PyObjC (Apple Vision) | `~/.pogo/venv` |
| 5 | WebDriverAgent, signed for your iPhone with your Apple ID | `~/.pogo/runtime`, and the iPhone |

Node.js and Python are pinned to exact versions and checked against SHA-256 checksums, Appium and the XCUITest driver are pinned to exact versions, and the Python libraries come from PyPI (`core/requirements.txt`). It takes a few minutes, needs no password and is skipped on later starts.
WebDriverAgent ships with IVory already built, so nothing is compiled on your Mac. IVory only signs it for your iPhone — a development signature is tied to the exact device, so it can't be made in advance — and installs it. That takes a few seconds.

</details>

### Updates

IVory checks for a new version when it starts and then once a day. When there is one, a card shows up in the sidebar:

1. **What's new** opens the release notes, **Download** fetches the new version in the background. You can keep working.
2. The download is checked against the SHA-256 checksum GitHub publishes with the release, and the new app's code
   signature has to cover every file in it. A release without a checksum, or from anywhere but this repository, isn't installed.
3. **Restart** swaps the app for the new one and opens it again. Your settings and measured IVs stay.

IVory never updates by itself and you can't restart while it's sorting: the card waits until the run ends.
The × hides it until the next start. You can also check by hand or turn the automatic check off in **Settings → General**.

### Build from source

<details>
<summary>Clone, build and install the app yourself</summary>
<br>

```bash
git clone https://github.com/ViktorKaderabek/IVory.git
cd IVory
bash scripts/build_wda_runtime.sh   # prebuilt WebDriverAgent + altsign-cli → runtime/
bash app/build_app.sh --install     # → ~/Applications/IVory.app
```

Building the app needs Xcode (it compiles Swift) — *using* it doesn't. `build_wda_runtime.sh` also builds
altsign-cli from [`vendor/`](vendor/README.md), with OpenSSL linked in statically (it downloads the OpenSSL source
once and checks its SHA-256), so the app needs no Homebrew.

Without `--install` the app stays in `dist/`. To build the installer DMG yourself:

```bash
bash scripts/build_dmg.sh           # → dist/IVory.dmg
```

</details>

## iPhone setup (one time)

The setup guide in the app does all of this with you, shows the iPhone screens with what to tap, and waits by itself
for whatever IVory can check (the phone connecting, Developer Mode, the restart), then lights up **Continue**. By hand it is:

1. Connect the iPhone by cable, unlock it, allow the accessory and confirm **Trust This Computer**.
2. Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode (the iPhone restarts; afterwards confirm
   **Turn On**). If you don't see it, the guide's **I don't see this option** makes the switch appear.
3. Turn on **Settings → Developer → Enable UI Automation**.
4. Sign in with your **Apple ID** and, when Apple asks, the six-digit code from your iPhone. IVory signs WebDriverAgent
   with it. The sign-in lasts about a year, the signature 7 days — IVory renews the signature by itself.
5. IVory installs WebDriverAgent on the iPhone (the app with a blank icon called *WebDriverAgentRunner*).
6. Trust the developer: Settings → General → VPN & Device Management → your Apple ID → **Trust**.
7. Open Pokémon GO and press **Start**.

The guide stays until a run has actually connected to the iPhone; a first run that can't connect brings it back.
Later, when a run can't control the iPhone (the helper app deleted, the phone erased, another iPhone), IVory asks
whether to go through the guide again — it skips what still works. **Settings → iPhone → Run setup again** does the same
any time.

### Your Apple ID

- The password is typed into IVory and handed straight to the bundled `altsign-cli`, which signs in with Apple itself
  (`gsa.apple.com`, the same sign-in Xcode uses, so the password isn't even sent in readable form). It is never saved,
  logged or passed on the command line. The six-digit code comes from Apple, which is how you know it's really Apple.
- What stays on the Mac is the session and the signing certificate's private key, which `altsign-cli` keeps in
  `~/Library/Application Support/altsign/` (readable by your user only, not backed up); the session lasts about a year.
  **Settings → iPhone → Sign out** deletes both.
- Signing creates one free development certificate on your account, named *IVory*. A free Apple ID may have only one.
  IVory replaces its own when it needs to, but **never revokes a certificate another program made**, so whatever Xcode,
  AltStore or Sideloadly signed with your Apple ID keeps working. If such a certificate takes the only place, IVory says
  so: revoke it in that program (in Xcode: Settings → Accounts → Manage Certificates) or use another Apple ID.
- `altsign-cli`'s source is part of this repository ([`vendor/`](vendor/README.md)), unchanged from
  [upstream](https://github.com/xhzq233/altsign-cli) and reviewed line by line, with IVory's changes in one patch:
  the certificate rule above, the keychain list put back after signing, nothing written to the macOS system log
  and no Apple ID, account number or key in its output, password-derived keys wiped from memory, and a session file
  without machine identifiers that stays out of Time Machine backups. The app is built from exactly this code.
- The only servers that see your account are Apple's: `gsa.apple.com` and `developerservices2.apple.com`. The machine
  data Apple asks for during the sign-in comes from macOS itself, not from a third-party server.
- Before IVory gives the password to `altsign-cli`, it checks that the app's own code signature still covers every file
  in it. A changed IVory.app refuses to sign in. Download IVory only from this repository's
  [Releases](https://github.com/ViktorKaderabek/IVory/releases).

## Usage

### The app

1. On **Run**, switch the steps on or off. At least one step has to stay on. Open a step to change how it works.
2. Open Pokémon GO on the iPhone and press **Start** (or hit Enter). Don't touch the phone while IVory is running.
   Every step shows how far it is, and the live card shows the Pokémon being read right now, with its IVs and the tag it gets.
3. **Stop** ends the run cleanly and saves the results. **Results folder** in the sidebar opens them.

<details>
<summary><b>Step settings</b>: open a step on Run</summary>
<br>

- **Duplicates**: the search typed into the game, the tag for worse duplicates and its color, how many of the best to keep.
- **IV tags**: thresholds in percent, name and color of every tag (click the dot to pick a color).
- **PvP tags**: per league: on/off, rank limit and tag color.
- **Rename**: IV range (dual slider), name template (editor with pieces and preview), overwrite custom nicknames, skip `Removable`, only Pokémon with a given tag.
- **Battle tags**: the `Raid` tag and how many attackers per type, the three team tags.
- **Weak Pokémon**: the IV threshold and which safeguards keep a Pokémon.

</details>

<details>
<summary><b>Settings</b></summary>
<br>

- **General**: Čeština / English, the installed version, **Check now** and **Check for updates automatically**, and how much space the run results in `~/Desktop/pogo_runs` take, with **Delete** (the bot's memory, the Pokémon photos and the run history stay).
- **iPhone**: the device with **Find**, the Apple ID with **Sign in** / **Sign out** (and until when the sign-in lasts), and **Run setup again**.
- **Notifications**: new raid bosses.
- **Advanced**: how many duplicate groups to check, the settings file, reset to defaults.
- **About**: version, license, the risk notice, when you confirmed it and **Revoke** (the notice shows up again on the next start).

Everything is saved automatically to `~/.pogo/config.json`.

</details>

### Terminal

```bash
bash scripts/run.sh                                   # duplicates + IV tags
bash scripts/run.sh --steps duplicates,iv,pvp,rename,battle,weak  # any combination of steps
bash scripts/run.sh --steps iv,pvp                    # only IV and PvP tags
bash scripts/run.sh --fresh                           # measure IVs again (ignore the cache)
```

Or double-click `Start.command`. The script sets up the same tools as the app on its first run.
If you haven't confirmed the risk notice in the app yet, the script shows it and asks you to type `I agree`,
and if no Apple ID is set up yet it asks for one so it can sign WebDriverAgent.

## How it works

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/how-it-works-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/how-it-works-light.svg">
    <img alt="IVory.app starts pogo_bot.py, which sends taps, swipes and typing through the Appium server and WebDriverAgent to the iPhone; the iPhone streams MJPEG video back to the bot, and the bot sends events to the app" src="docs/how-it-works-light.svg" width="100%">
  </picture>
</p>

- The iPhone is controlled through **Appium + WebDriverAgent** (XCUITest), the same tooling used for automated iOS app tests.
- **No Xcode.** WebDriverAgent comes prebuilt, is signed with your Apple ID by `altsign-cli`, and is installed and started by [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) over a userspace tunnel (no admin password). Appium is handed the finished address, so it never reaches for `xcodebuild`. That tunnel is why iOS 17.4 is the minimum.
- The screen arrives as a video stream (~15 fps) and text is read with **Apple Vision** OCR right on the Mac.
- IVs are read pixel by pixel from the appraisal bars.
- **Fast mode** (default) reads the storage only once, for all steps. In the appraisal it jumps to the next Pokémon with the ▶ arrow and keeps everything in memory; duplicates, IV tags, PvP tags and renaming are all decided from that one read.
- **Batch tagging through search:** for each tag IVory types the CPs of the Pokémon that need it into the storage search (`cp2260,cp2268,cp1705`). The game then shows just those Pokémon on a screen or two, so IVory selects them all and tags them at once instead of scrolling through the whole storage. Renaming uses the same trick.
- Species, level, CP after evolution and PvP ranks are computed from CP, HP and IVs using public game data: species stats from the [PvPoke](https://github.com/pvpoke/pvpoke) game master and CP multipliers from [PokeMiners](https://github.com/PokeMiners/game_masters). IVory doesn't ship this data. It downloads it before the first run and refreshes it once a week, so new Pokémon work without an IVory update.
- **Raids, PvP teams and Power-ups** add the PvPoke league rankings and, from the PokeMiners game master, the raid stats of the moves, the type chart and the weather boosts (downloaded with the rest of the game data). Raid counters are ranked by DPS³ × TDO, the usual raid measure. The win chance compares the damage N players with such a party deal before the raid timer runs out with the boss's HP; the bosses' HP, CP multiplier and timer per tier aren't in the game master, so IVory uses the values the community measured.
- The bot recognizes about 15 game screens, so it finds its way back to the storage from anywhere and recovers from popups, game crashes and dropped connections.
- **Safety net:** before every tap it checks that `TRANSFER`, `EVOLVE`, `POWER UP` or `YES` is not nearby, and it always cancels confirmation dialogs (`CANCEL` / `NO`).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/batch-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/batch-light.svg">
    <img alt="Batch tagging through search: IVory types cp2260,cp2268,cp1705, the game shows just those three Pokémon, IVory selects them all and tags them at once" src="docs/batch-light.svg" width="100%">
  </picture>
</p>

<details>
<summary><b>How IV %, PvP rank and the name pieces are calculated</b></summary>

- **IV %** = (attack + defense + HP) / 45, rounded. The range 85–100 % therefore starts at an IV sum of 39.
- **PvP rank** = position of the Pokémon's IV combination among all 4,096 for the league (1 = best), at the highest level that stays under the CP cap (1,500 Great, 2,500 Ultra, none for Master), for its final evolution (with branching evolutions, the best branch).
- **Name pieces:** IV % (`91`), IV values (`14/13/14`), level (`L15`), species (`Baxcalibur`), short species (first 6 letters), final evolution (first 3 letters, `Bax`), CP after evolution, max CP at level 50, league ranks (`G12`, `U5`, `M30`), custom text, and separators (space, `-`, `|`). Names longer than 12 characters are cut.
- **Custom nickname** = a name that is neither the species name nor a name IVory gave earlier. Such Pokémon are skipped unless you turn on *Overwrite custom nicknames too*.
- **Refused names:** the game's word filter sometimes refuses a name, even one shaped like the others ("This name contains inappropriate text"). IVory then cancels the dialog, leaves the old name, tells you to rename that Pokémon yourself and doesn't try that name again.

</details>

## Configuration

`~/.pogo/config.json`: the app writes it, the bot reads it.

<details>
<summary><b>All keys and their defaults</b></summary>
<br>

| Key | Default | Meaning |
|---|---|---|
| `language` | system | language of the app and the log: `en` or `cs` |
| `check_updates` | `true` | check for a new version on start and once a day |
| `udid` | empty | iPhone UDID; empty = the first connected device |
| `apple_id` | empty | the Apple ID WebDriverAgent is signed with. The password is never stored here: `altsign-cli` keeps the session itself. |
| `search_query` | `count & !legendary & !ultra beasts` | what the bot types into the storage search |
| `remove_tag` | `Removable` | tag for worse duplicates |
| `remove_tag_color` | `red` | color used when the tag is created: `blue`, `green`, `purple`, `yellow`, `red`, `orange`, `gray`, `black` |
| `keep_best` | `1` | how many of the best Pokémon to keep in each group of identical ones |
| `iv_tags` | 7 tags | `[{"min": 95, "name": "95-99% Insane", "color": "orange"}, …]`: a Pokémon gets the first tag whose threshold it reaches |
| `recheck_tagged` | `false` | slow mode only: `false` = skip Pokémon that already have an IV tag |
| `max_groups` | `0` | how many duplicate groups to process (0 = all) |
| `steps` | duplicates + IV | `{"duplicates": true, "iv": true, "pvp": false, "rename": false}` |
| `pvp` | 3 leagues | `{"great": {"name": "Great League", "enabled": true, "max_rank": 100, "color": "blue"}, "ultra": …, "master": …}` |
| `rename` | 85–100 % | `min`, `max`, `template` (pieces such as `{"k": "iv"}`, `{"k": "space"}`, `{"k": "text", "v": "TOP"}`), `overwrite_custom`, `skip_removable`, `only_tag` |
| `fast_mode` | `true` | `false` = the old slow mode that opens every Pokémon separately |
| `battle` | Raid + 3 team tags | `raid` (`enabled`, `name`, `color`, `per_type`), `great` / `ultra` / `master` (`enabled`, `name`, `color`, `team` = the PvPoke ids of the picked team), `notify_bosses`, and `tags`: the Pokémon picked for each tag by CP and IVs, written by the app when a run starts |
| `weak` | under 70 %, all safeguards on | `max_iv`, `keep_legendary`, `keep_mythical`, `keep_ultra_beast`, `keep_regional`, `keep_best`, `keep_battle`, `keep_tag` (a tag of your own that protects a Pokémon) |
| `consent_version`, `consent_at`, `app_version` | – | written when you confirm the risk notice (in the app or in Terminal). Revoke it in Settings → About. |

</details>

## Files

<details>
<summary><b>Everything IVory writes to your Mac</b></summary>
<br>

| Path | Contents |
|---|---|
| `~/.pogo/config.json` | settings from the app |
| `~/.pogo/pamet.json` | measured IVs (kept for a few hours) and which Pokémon already got `Removable`. **Don't delete it** while tagged Pokémon are still in your storage: the bot uses it to avoid selecting them again, because a tap would untick the tag. |
| `~/.pogo/last_box.json` | the storage from the last measurement (species, IVs, league ranks). The app uses it for the number of Pokémon in the rename range and for the name previews. |
| `~/.pogo/cards/` | a picture of each Pokémon for the Storage screen: the whole phone screen with its appraisal (`883_14-13-14.jpg`, 540 px wide, about 60 kB, including the speech bubble that says where and when it was caught) and a square of the Pokémon (`…_icon.jpg`). Pictures of Pokémon that leave the memory get deleted. |
| `~/.pogo/runs.json` | the run history for the Storage screen (start, duration, Pokémon checked, recovered errors). It survives deleting the run results. |
| `~/.pogo/pokedata.json` | game data (species stats, evolutions, CP multipliers, and for Raids, PvP teams and Power-ups the moves, type chart, weather and league rankings) from PvPoke and PokeMiners, refreshed once a week |
| `~/.pogo/raids.json` | the current raid bosses from ScrapedDuck for the Raids screen, refreshed once a day |
| `~/.pogo/runtime` | Node.js, Appium and Python downloaded on the first start |
| `~/.pogo/venv` | Python environment with the bot's libraries |
| `~/Library/Caches/IVory` | a downloaded update until it's installed, and the raid bosses' pictures (`raids/`) |
| `~/Desktop/pogo_runs/<date_time>/` | results of a run: `log.txt`, `result.json`, `result_iv_tagy.json`, `iv/` (crops of the IV bars) and `chyba_XX/` (screens from the moment something went wrong) |

</details>

## Project layout

<details>
<summary><b>Where things live in this repository</b></summary>
<br>

```
app/                 Mac app (SwiftUI), build script, icon
app/dmg/             background and window layout of the installer DMG
core/pogo_bot.py     the bot's entry point
core/ivory/          the bot, in small layered modules (the map is in core/ivory/__init__.py)
core/pokecalc.py     CP and PvP math
core/pokedata.py     downloads the game data (PvPoke, PokeMiners) into ~/.pogo/pokedata.json
scripts/run.sh       sets up the tools on the first start, starts Appium and the bot
scripts/build_dmg.sh builds dist/IVory.dmg
scripts/build_runtime.sh    builds a self-contained Node/Appium/Python runtime into build/
tests/               phone simulators and tests (see tests/README.md)
docs/                images for this README
Start.command        double-click launcher without the app
```

</details>

## Releasing a new version

<details>
<summary><b>Three steps to publish a release</b></summary>
<br>

1. Raise `CFBundleShortVersionString` (and `CFBundleVersion`) in `app/Info.plist`, e.g. `1.2.0`.
2. Build the installer: `bash scripts/build_dmg.sh` → `dist/IVory.dmg`.
3. Publish it as the latest release with the tag `v` + the same version. The file has to be named `IVory.dmg`:

   ```bash
   gh release create v1.2.0 dist/IVory.dmg --title "IVory 1.2.0" --notes-file notes.md
   ```

Apps from 1.1.0 on find the release by themselves and offer the update.

</details>

## Tests

The bot can be tested without a phone. `tests/sim_synthetic.py` draws all game screens itself and runs 32 scenarios: fast and slow mode, PvP tags, renaming, tagging through CP search, game crashes, a list that scrolls further than the finger like on a real iPhone, duplicated list cells and more.

```bash
cd tests
~/.pogo/venv/bin/python sim_synthetic.py            # all scenarios
~/.pogo/venv/bin/python sim_synthetic.py verbose    # one scenario with the bot's log
```

## Troubleshooting

<details>
<summary><b>“IVory can't be opened” / “Apple could not verify…”</b></summary>

System Settings → Privacy & Security → **Open Anyway** (see [Installation](#download-recommended)).
</details>

<details>
<summary><b>“This iPhone needs iOS 17.4 or newer”</b></summary>

IVory starts WebDriverAgent over a userspace tunnel, which iOS 17.0–17.3 can't serve. Update the iPhone in
Settings → General → Software Update.
</details>

<details>
<summary><b>The first start fails while downloading</b></summary>

Check the internet connection and press Start again. Finished parts are kept, so it continues where it stopped.
</details>

<details>
<summary><b>“No iPhone found”</b></summary>

Unlock the phone, connect it by cable and confirm *Trust*. Turn on Developer Mode.
</details>

<details>
<summary><b>“Not authorized for performing UI testing actions”</b></summary>

On the iPhone, turn on Settings → Developer → *Enable UI Automation*. IVory restarts WebDriverAgent once by itself before giving up.
</details>

<details>
<summary><b>WebDriverAgent can't be signed</b></summary>

Open Settings → iPhone and press **Sign in** again (it opens the guide on the Apple ID step): the Apple session expired (it lasts about a year). The signature itself lasts 7 days and IVory renews it by itself. On the iPhone, trust the developer under Settings → General → VPN & Device Management.
</details>

<details>
<summary><b>The bot gets stuck or taps the wrong spot</b></summary>

The `chyba_XX` folder of the last run has screenshots of the last steps with the tap marked.
</details>

<details>
<summary><b>Game in another language</b></summary>

The game's UI strings live in the `L` dictionary in `core/ivory/config.py`.
</details>

## Uninstall

Drag IVory from Applications to the Trash, then remove what it installed:

```bash
rm -rf ~/.pogo ~/.appium
```

Results of your runs stay in `~/Desktop/pogo_runs` until you delete them (**Settings → General → Run results → Delete** does it before you uninstall).
If you already used Appium before IVory, keep `~/.appium`.

## License

IVory is free for **noncommercial use** under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). © 2026 Viktor Kadeřábek.

- ✅ You can use it for yourself, study the code, change it and share it, as long as you keep the license and the copyright notice.
- ❌ You can't sell it, offer it as a paid service or use it in a commercial product.

Want to use IVory commercially? [Open an issue](https://github.com/ViktorKaderabek/IVory/issues) and ask.

Contributions are welcome. By opening a pull request you agree that your contribution is released under the same license
and that the author may also license it under other terms.
