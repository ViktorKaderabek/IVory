import SwiftUI

/// The screens done on the iPhone: what to do on the left, the phones showing where on the right.
struct PhoneScreen: View {
    @ObservedObject var flow: SetupFlow

    private var screen: SetupScreen { flow.screen }
    private var phoneName: String { flow.device?.name ?? "iPhone" }

    var body: some View {
        HStack(spacing: 0) {
            CenteredColumn {
                VStack(alignment: .leading, spacing: 22) {
                    SetupHeading(title: screen.title, lead: screen.lead)
                    details
                    status
                    if screen.step.confirmedByHand {
                        ConfirmBox(label: confirmLabel, isOn: flow.isConfirmed(screen.step)) {
                            flow.setConfirmed(screen.step, !flow.isConfirmed(screen.step))
                        }
                    }
                }
            }
            .padding(.leading, 44)
            .frame(width: 372)
            PhoneStage(phones: screen.phones)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var details: some View {
        switch screen {
        case .connect:
            NumberedSteps(items: [tr("Odemkni iPhone", "Unlock your iPhone"),
                                  tr("Klepni na Povolit u „Povolit připojení příslušenství?“", "Tap Allow on “Allow accessory to connect?”"),
                                  tr("Klepni na Důvěřovat u „Důvěřovat tomuto počítači?“ a zadej kód",
                                     "Tap Trust on “Trust This Computer?” and enter your passcode")])
        case .devmode, .devmodeMissing:
            PathList(items: [tr("Nastavení", "Settings"), tr("Soukromí a zabezpečení", "Privacy & Security"),
                             tr("Režim pro vývojáře", "Developer Mode")])
        case .devmodeRestart:
            NumberedSteps(items: [tr("Počkej, až se iPhone restartuje", "Wait for the iPhone to restart"), tr("Odemkni ho", "Unlock it")])
        case .uiauto:
            PathList(items: [tr("Nastavení", "Settings"), tr("Vývojář (úplně dole)", "Developer (at the very bottom)"),
                             tr("Povolit automatizaci UI", "Enable UI Automation")])
        case .helper:
            VStack(alignment: .leading, spacing: 14) {
                SetupPoint(symbol: "hand.tap", title: tr("Slouží jen k automatizaci", "It’s only for automation"),
                           text: tr("Díky ní IVory v Pokémon GO klepe, posouvá a čte obrazovku. Nic jiného nedělá.",
                                    "It lets IVory tap, swipe and read the screen in Pokémon GO. That’s all it does."))
                SetupPoint(symbol: "apple.logo", title: tr("Apple jinou cestu nenabízí", "Apple offers no other way"),
                           text: tr("Ovládat iPhone z Macu jde jen přes aplikaci, jako je tahle.",
                                    "An iPhone can only be controlled from a Mac through an app like this one."))
                SetupPoint(symbol: "trash", title: tr("Kdykoli ji můžeš smazat", "You can delete it any time"),
                           text: tr("Smaž ji jako každou jinou aplikaci. IVory ji při dalším Startu nainstaluje znovu.",
                                    "Remove it like any other app. If you do, IVory installs it again the next time you press Start."))
            }
        case .trustdev:
            PathList(items: [tr("Nastavení", "Settings"), tr("Obecné", "General"), tr("Správa VPN a zařízení", "VPN & Device Management"),
                             flow.appleIdShown, tr("Důvěřovat", "Trust")])
        case .ready:
            NumberedSteps(items: [tr("Otevři Pokémon GO", "Open Pokémon GO"), tr("Počkej na mapu", "Wait for the map"),
                                  tr("Během běhu na iPhone nesahej", "Don’t touch the iPhone while IVory runs")])
        case .appleid, .appleidCode, .install:
            EmptyView()
        }
    }

    private var status: StatusCard {
        if screen.step == .devmode, flow.done.contains(.devmode) {
            return StatusCard(kind: .ok, text: tr("Režim pro vývojáře je zapnutý", "Developer Mode is on"))
        }
        switch screen {
        case .connect where flow.done.contains(.connect):
            return StatusCard(kind: .ok, text: tr("\(phoneName) je připojený", "\(phoneName) is connected"),
                              detail: tr("iOS \(flow.device?.os ?? "") · s IVory funguje", "iOS \(flow.device?.os ?? "") · works with IVory"))
        case .connect:
            return StatusCard(kind: .waiting, text: tr("Hledám iPhone…", "Looking for your iPhone…"),
                              detail: tr("Čerstvě připojený iPhone se někdy ozve až napodruhé.",
                                         "A freshly connected iPhone sometimes answers only on the second try."))
        case .devmode:
            return StatusCard(kind: .waiting, text: tr("Čekám na Režim pro vývojáře…", "Waiting for Developer Mode…"),
                              detail: tr("Až bude zapnutý, poznám to sám.", "I’ll notice on my own once it’s on."))
        case .devmodeMissing:
            return StatusCard(kind: .info, text: tr("Volba už tam je", "The option is there now"),
                              detail: tr("Úplně zavři Nastavení na iPhonu, znovu ho otevři a sjeď na konec Soukromí a zabezpečení.",
                                         "Close Settings on your iPhone completely, open it again and scroll to the bottom of Privacy & Security."))
        case .devmodeRestart:
            return StatusCard(kind: .waiting, text: tr("iPhone se restartuje", "Your iPhone is restarting"),
                              detail: tr("Trvá to asi minutu. Klidně odejdi, až se vrátí, poznám to sám.",
                                         "This takes about a minute. You can step away, I’ll notice when it’s back."))
        case .uiauto, .trustdev:
            return StatusCard(kind: .manual, text: tr("Tohle IVory z Macu ověřit neumí", "IVory can’t check this from the Mac"),
                              detail: tr("Když to vynecháš, běh se zastaví a nabídne ti tohoto průvodce.",
                                         "If you skip it, the run stops and offers you this guide."))
        case .helper:
            return StatusCard(kind: .ok, text: tr("Nainstalováno v \(phoneName)", "Installed on \(phoneName)"))
        default:
            return StatusCard(kind: .ok, text: tr("Všechno je nastavené", "Everything is set up"),
                              detail: tr("Tenhle průvodce už neuvidíš.", "You won’t see this guide again."))
        }
    }

    private var confirmLabel: String {
        screen == .uiauto ? tr("Automatizaci UI mám zapnutou", "I’ve turned on UI Automation")
            : tr("Klepl jsem na Důvěřovat", "I’ve tapped Trust")
    }
}

extension SetupScreen {
    var title: String {
        switch self {
        case .connect: return tr("Připoj iPhone", "Connect your iPhone")
        case .devmode, .devmodeMissing, .devmodeRestart: return tr("Zapni Režim pro vývojáře", "Turn on Developer Mode")
        case .uiauto: return tr("Zapni Automatizaci UI", "Turn on UI Automation")
        case .appleid, .appleidCode: return tr("Přihlas se Apple ID", "Sign in with your Apple ID")
        case .install: return tr("Připravuju IVory", "Setting up IVory")
        case .helper: return tr("Nová aplikace v iPhonu", "A new app on your iPhone")
        case .trustdev: return tr("Důvěřuj v iPhonu svému Apple ID", "Trust your Apple ID on the iPhone")
        case .ready: return tr("Otevři Pokémon GO", "Open Pokémon GO")
        }
    }

    var lead: String {
        switch self {
        case .connect:
            return tr("Připoj iPhone k Macu kabelem a odemkni ho. Dotazy vyskočí na iPhonu, ne tady.",
                      "Plug your iPhone into this Mac with a cable and unlock it. The questions pop up on the iPhone, not here.")
        case .devmode, .devmodeMissing:
            return tr("Přepni ho a klepni na Zapnout. iPhone se pak sám restartuje.",
                      "Switch it on and tap Turn On. Your iPhone then restarts by itself.")
        case .devmodeRestart:
            return tr("iPhone se restartuje, aby Režim pro vývojáře zapnul.", "Your iPhone restarts to switch Developer Mode on.")
        case .uiauto:
            return tr("Vývojář je úplně dole v Nastavení, pod Aplikacemi. Objeví se až po zapnutí Režimu pro vývojáře.",
                      "Developer is at the very bottom of Settings, below Apps. It shows up only after Developer Mode is on.")
        case .appleid, .appleidCode:
            return tr("Stačí obyčejné Apple ID, placený vývojářský účet nepotřebuješ. Použij Apple ID, kterým je přihlášený tvůj iPhone.",
                      "A free Apple ID is enough. You don’t need a paid developer account. Use the Apple ID your iPhone is signed in with.")
        case .install:
            return tr("Asi 250 MB, pár minut. Proběhne jen jednou.", "About 250 MB, a few minutes. This happens only once.")
        case .helper:
            return tr("IVory nainstalovalo malou pomocnou aplikaci. Najdeš ji v Knihovně aplikací. Vlastní obrazovku nemá.",
                      "IVory installed a small helper app. You’ll find it in the App Library. It has no screen of its own.")
        case .trustdev:
            return tr("iPhone pomocnou aplikaci neotevře, dokud nebudeš důvěřovat vývojáři. Tím vývojářem je tvoje vlastní Apple ID.",
                      "Your iPhone won’t open the helper app until you trust the developer, which is your own Apple ID.")
        case .ready:
            return tr("Otevři hru na iPhonu a nech ji na mapě. Pak tady zmáčkni Start.",
                      "Open the game on your iPhone and leave it on the map screen. Then press Start here.")
        }
    }

    /// The phones the screen shows, numbered in order when there are two.
    var phones: [PhonePic] {
        switch self {
        case .connect:
            return [PhonePic(art: .allowAccessory, caption: tr("Klepni na Povolit", "Tap Allow")),
                    PhonePic(art: .trustComputer, caption: tr("Důvěřovat a zadej kód", "Tap Trust, enter passcode"))]
        case .devmode, .devmodeMissing:
            return [PhonePic(art: .privacy, caption: tr("Klepni na Režim pro vývojáře", "Tap Developer Mode")),
                    PhonePic(art: .devmodeTurnOn, caption: tr("Přepni a klepni na Zapnout", "Switch it on, tap Turn On"))]
        case .devmodeRestart:
            return [PhonePic(art: .restart, caption: tr("Počkej a odemkni", "Wait, then unlock it"))]
        case .uiauto:
            return [PhonePic(art: .settingsDeveloper, caption: tr("Sjeď dolů, klepni na Vývojář", "Scroll down, tap Developer")),
                    PhonePic(art: .uiAutomation, caption: tr("Zapni Automatizaci UI", "Switch on UI Automation"))]
        case .helper:
            return [PhonePic(art: .helperApp, caption: tr("V Knihovně aplikací", "In your App Library"))]
        case .trustdev:
            return [PhonePic(art: .trustDeveloper, caption: tr("Klepni na Důvěřovat", "Tap Trust")),
                    PhonePic(art: .trustDialog, caption: tr("Potvrď Důvěřovat", "Confirm with Trust"))]
        case .ready:
            return [PhonePic(art: .openPogo, caption: tr("Otevři Pokémon GO", "Open Pokémon GO"))]
        case .appleid, .appleidCode, .install:
            return []
        }
    }
}
