# ThreeCrownsGuild

Online-lista och gemensam chatt (`/tcg`) över flera guilds på samma realm.

## Installera
Kopiera/länka mappen till `Interface\AddOns\ThreeCrownsGuild` (mappnamnet måste matcha `.toc`).

Vid uppgradering: stäng WoW och byt ut den gamla addon-mappen. För att behålla historik, smeknamn och inställningar, kopiera `WTF\Account\<konto>\SavedVariables\GuildFriends.lua` till `ThreeCrownsGuild.lua` i samma SavedVariables-mapp innan du startar WoW. Variabelnamnet `GuildFriendsDB` behålls för att kunna läsa den sparade datan.

## Setup (officerare, samma text i ALLA guilds → Guild Info, tangent `J`)
```
TCGc:kanalnamn:lösenord
TCGp:Guild Ett:G1
TCGp:Guild Två:G2
```
`TCGp` = exakt guild-namn + tagg, en rad per guild (inkl. din egen). Prefixet är `TCG`, så det krockar inte med GreenWall. Äldre `GFc:`/`GFp:` och `MGc:`/`MGp:` fungerar också.

## Användning
| | |
|---|---|
| `/tcg` | öppna/stäng fönstret |
| `/tcg text` | skriv till alla guilds (visas som `[TCG] [TAG] Namn: text`) |
| `/tcg tag on\|off` | visa guild-tagg i chatten |
| `/tcg echo on\|off` | visa `/tcg` även i vanliga chattfönstret |
| `/tcg surname on\|off` | visa/dölj efternamn (visas som standard) |
| `/tcg who` | uppdatera online-listan |
| `/tcg status` | felsökning |

Fönstret: egen guild visar hela guild-rostern (online), övriga guilds visar de som kör addonet. Klicka på ett namn för att viskning, klicka på en guild-rad för att fälla ihop den. Historik (200 rader) sparas.

Högerklicka på en spelare och välj **Set nickname** för ett lokalt smeknamn. Det visas som `Förnamn(nick):` i chatten och `Förnamn(nick)` i listan, även när efternamn är på. Töm smeknamnet för att ta bort det. `/tcg surname off` visar bara förnamn utan smeknamn. Inställningen sparas för kontot och gäller bara addonet.

## Publicera på GitHub och CurseForge

GitHub Actions kontrollerar Lua-koden vid push och pull requests. En versionstagg
som `v0.1.0` bygger en ZIP med mappen `ThreeCrownsGuild`, sätter addonets version
från taggen och publicerar en GitHub Release. Testfiler och workflow följer inte
med i ZIP-filen. Paketeringen använder [BigWigs packager](https://github.com/BigWigsMods/packager).

För att även uppdatera CurseForge, gör detta en gång:

1. Skapa ett World of Warcraft-projekt i [CurseForge Authors](https://authors.curseforge.com/).
2. Öppna GitHub-repots **Settings → Secrets and variables → Actions**.
3. Lägg projektets numeriska ID i repository-variabeln `CF_PROJECT_ID`.
4. Skapa en [CurseForge upload API-token](https://www.curseforge.com/account/api-tokens)
   och spara den som repository-hemligheten `CF_API_KEY`. Lägg aldrig token i koden.

Utan `CF_PROJECT_ID` publiceras endast GitHub-versionen och workflow visar en
varning. Om projekt-ID anges krävs också en API-token. CurseForge kan behöva
godkänna projektet och uppladdade filer innan de blir tillgängliga.

Publicera en ny version från projektmappen (byt versionsnummer varje gång):

```sh
git add .
git commit -m "Prepare release v0.1.1"
git push origin main
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

En vanlig push uppdaterar koden på GitHub. Versionstaggen startar publiceringen
till CurseForge automatiskt när inställningarna ovan finns.
