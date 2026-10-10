# ThreeCrownsGuild

Online-lista och gemensam chatt (`/tcg`) över flera guilds på samma realm.
Fungerar i WoW Forever (Interface `16xxx`) och TBC Anniversary (`20xxx`). Classic Era, Wrath,
Cataclysm, MoP och Retail stöds inte. Alla deltagare behöver samma version.

**TBC:** klienten tillåter inte addonmeddelanden till kanaler och bara spelarinput för
kanalchatt, så addonet använder vanliga meddelanden med prefixet `GF1#` i den dolda
transportkanalen (kanalen döljs; en kanalmedlem utan addonet kan se meddelandena).
Chatt och LFM skickas när du skriver eller klickar. Närvaro skickas som ett kanalmeddelande
vid tangenttryck eller klick (ungefär var fjärde minut) och som viskningar när du står still.
Den som kommer online får direkta svar av de andra. Inaktuella spelare tas bort efter tio
minuter. TBC-delen är ännu inte fullt verifierad i spelet.

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

Skriv som vanligt i guildchatten (`/g`). Addonet delar dina egna meddelanden med
de anslutna guildarnas addon-användare. Synkningen är på som standard. Stäng av
med `/tc sync off` och slå på igen med `/tc sync on`; valet sparas för kontot.
Avstängningen stoppar automatisk vidarebefordran av dina egna guildmeddelanden.
Du kan fortfarande läsa delade meddelanden och skriva manuellt med `/tc text`.
Officerchatt, viskningar och meddelanden från spelare utan addonet skickas inte vidare.
Alla deltagare behöver version 0.2.0 eller senare för guildsynkningen.

`/tc` och `/tcg` fungerar likadant. Den vanliga guildchatten visar meddelanden
från din egen guild; andra guildars meddelanden visas med guildtagg och spelarnamn i chattfönstret
och i addonets fönster. De skickas inte vidare till serverns guildchatt.

| | |
|---|---|
| `/tc sync on\|off` | slå på/stäng av automatisk synkning av egna guildmeddelanden |
| `/tcg` | öppna/stäng fönstret |
| `/tcg text` | skriv till alla guilds (visas som `[TAG] Namn: text`) |
| `/tcg tag on\|off` | visa guild-tagg i chatten |
| `/tcg echo on\|off` | visa `/tcg` även i vanliga chattfönstret |
| `/tcg surname on\|off` | visa/dölj efternamn (visas som standard) |
| `/tcg lfm` | öppna LFM-dialogen (samma som knappen **LFM** i fönstret) |
| `/tcg lfm Dungeon` | skicka direkt med automatiskt upptäckta roller |
| `/tcg lfm on\|off` | visa/dölj LFM-notiser från andra guilds |
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

## LFM (letar fler till gruppen)

Tryck på **LFM** i fönstret (eller `/tcg lfm`). Dialogen fylls i med vilka roller gruppen saknar
(en 5-mannagrupp: 1 tank, 1 healer, 3 DPS) och kan ändras genom att klicka på rollknapparna.
Ange dungeon och skicka: alla guilds får en notis mitt på skärmen, `Namn1, Namn2 are looking for
Healer + 2 DPS` med dungeon och guild-tagg. Notisen visas även i chatten med klickbart namn.
Roller tas från gruppens tilldelade roller om klienten har dem, annars gissas de (Priest = healer,
övriga DPS), så kontrollera dialogen. Högst ett utskick per 30 sekunder.

