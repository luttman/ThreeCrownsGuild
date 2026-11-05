# ThreeCrownsGuild

An online member list and shared chat (`/tcg`) across multiple guilds on the same realm.
Compare stats and see players from your own guild on the map with `/tc` guild tools.
Supports WoW Forever (Interface `16xxx`) and TBC Anniversary (`20xxx`). Classic Era, Wrath,
Cataclysm, MoP, and Retail are not supported. All participants need the same version.

Shared chat and LFM use regular messages in the hidden transport channel. The addon encodes
these messages on Forever to preserve links and non-ASCII text. Players in the channel can see
the raw messages if they use a client without the addon. Chat and LFM send when you type or click.
The addon uses direct addon whispers to announce presence while you are idle and answer roster
requests. Inactive players are removed after ten minutes.

## Installation

Copy or link the folder to `Interface\AddOns\ThreeCrownsGuild`. The folder name must match the `.toc` file.

When upgrading, close WoW and replace the old addon folder. To keep your history, nicknames, and settings
when migrating from GuildFriends, copy `WTF\Account\<account>\SavedVariables\GuildFriends.lua` to
`ThreeCrownsGuild.lua` in the same SavedVariables folder before starting WoW. The saved variable name
`GuildFriendsDB` is retained so the addon can read your existing data.

## Setup

An officer must add the same configuration to **Guild Info** in every participating guild
(open the guild window with `J`):

```text
TCGc:channelname:password
TCGp:Guild One:G1
TCGp:Guild Two:G2
```

Each `TCGp` line contains an exact guild name and its tag. Include one line per guild, including your own.
The `TCG` prefix avoids conflicts with GreenWall. Older `GFc:`/`GFp:` and `MGc:`/`MGp:` prefixes also work.

## Shared chat

Write in guild chat (`/g`) as usual. The addon shares your own messages with addon users in the
connected guilds. Synchronization is enabled by default. Disable it with `/tcg sync off` and enable
it again with `/tcg sync on`. The addon saves this setting for your account.
Disabling synchronization stops automatic forwarding of your own guild messages. You can still
read shared messages and send messages manually with `/tcg text`.
Officer chat, regular whispers, and messages from players without the addon are not forwarded.
All participants need version 0.2.0 or later for guild chat synchronization.

Regular guild chat shows messages from your own guild.
Messages from other guilds appear with a guild tag and player name in the chat window and the
addon window. They are not forwarded into the server's guild chat.

| Command | Action |
|---|---|
| `/tcg help` | Show chat commands |
| `/tcg sync on\|off` | Enable or disable automatic forwarding of your own guild messages |
| `/tcg` | Open or close the addon window |
| `/tcg text` | Send a message to all connected guilds (displayed as `[TAG] Name: text`) |
| `/tcg tag on\|off` | Show or hide guild tags in chat |
| `/tcg echo on\|off` | Show or hide shared chat in the regular chat window |
| `/tcg surname on\|off` | Show or hide surnames (shown by default) |

The addon window shows all online members of your own guild. For other guilds, it shows players
running the addon. Click a player name to whisper, or click a guild row to collapse it.
Chat history is saved, up to 200 messages.

Right-click a player and select **Set nickname** to assign a local nickname. It appears as
`FirstName(nickname):` in chat and `FirstName(nickname)` in the member list, even when surnames
are enabled. Clear the nickname to remove it. With `/tcg surname off`, players without a nickname
are shown by first name only. These settings are saved for your account and apply only to the addon.

## Guild tools

| Command | Action |
|---|---|
| `/tc help` | Show guild tool commands |
| `/tc` or `/tc stats` | Open the guild leaderboard. Click a column heading to sort. |
| `/tc deaths` | Show the death breakdown by location and cause |
| `/tc race` | Compare when players reached levels 10, 20, 30, 40, 50, and 60 and how much play time it took |
| `/tc share on\|off` | Start or stop sharing your character's stats with your guild |
| `/tc show` or `/tc hide` | Start or stop sharing your outdoor position with your guild |
| `/tc pins on\|off` | Show or hide class-colored guild dots on your world map and minimap |
| `/tc lfm` | Open the LFM dialog, also available through the **LFM** button |
| `/tc lfm Dungeon` | Send an LFM notification using automatically detected roles |
| `/tc lfm on\|off` | Show or hide LFM notifications from other guilds |
| `/tc who` | Refresh the online member list |
| `/tc status` or `/tc roster` | Show diagnostic information |

The leaderboard reads the game's character statistics for quests completed, creatures killed,
dungeons and raids entered, auctions posted and purchased, and deaths. It also shows the most gold
your character has ever owned and the last total WoW reports through `/played`. A dash marks values
the client doesn't provide.

The level race records milestones as you reach them with the addon enabled. Each column sorts by
the play time it took to reach that level. Race results use the same sharing setting as guild stats.

Stat sharing is on by default, and position sharing is off by default. Each character can change
both settings separately. Guildmates need the addon to see your position or stats. The addon keeps
the latest shared stats for offline guildmates.
When you turn stat sharing off, guildmates remove your entry when they receive the update. Map dots
expire after 30 seconds without an update. The minimap shows only dots within its current view radius.

## Publishing to GitHub and CurseForge

GitHub Actions checks the Lua code on pushes and pull requests. A version tag such as `v0.1.0`
builds a ZIP containing the `ThreeCrownsGuild` folder, sets the addon version from the tag,
and publishes a GitHub Release. Test files and workflows are excluded from the ZIP.
Packaging uses the [BigWigs packager](https://github.com/BigWigsMods/packager).

To enable CurseForge uploads, complete this setup once:

1. Create a World of Warcraft project in [CurseForge Authors](https://authors.curseforge.com/).
2. Open the GitHub repository's **Settings → Secrets and variables → Actions**.
3. Set the repository variable `CF_PROJECT_ID` to your project's numeric ID.
4. Create a [CurseForge upload API token](https://www.curseforge.com/account/api-tokens)
   and save it as the repository secret `CF_API_KEY`. Never put the token in the source code.

Without `CF_PROJECT_ID`, only the GitHub release is published, and the workflow reports a warning.
If a project ID is configured, an API token is also required. CurseForge may need to approve
both the project and uploaded files before they become available.

To publish a new version from the project folder, use a new version number each time:

```sh
git add .
git commit -m "Prepare release v0.1.1"
git push origin main
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

A regular push updates the code on GitHub. Pushing a version tag starts automatic publishing
to CurseForge when the settings above are configured.

## LFM (looking for more)

Click **LFM** in the addon window or use `/tc lfm`. The dialog fills in the roles your group
is missing, based on a five-player party: one tank, one healer, and three DPS. Click the role
buttons to adjust the selection.

Enter a dungeon and send the notification. All connected guilds receive a notification in the
middle of the screen, such as `Name1, Name2 are looking for Healer + 2 DPS`, with the dungeon
and guild tag. The notification also appears in chat with a clickable player name.

Roles come from assigned group roles when the client provides them. Otherwise, the addon
estimates them (Priest = healer, other classes = DPS), so check the dialog before sending.
You can send at most one notification every 30 seconds.
