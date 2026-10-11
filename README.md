# ThreeCrownsGuild

An online member list and shared chat (`/tcg`) across multiple guilds on the same realm.
Supports WoW Forever (Interface `16xxx`) and TBC Anniversary (`20xxx`). Classic Era, Wrath,
Cataclysm, MoP, and Retail are not supported. All participants need the same version.

**TBC:** the client does not allow addon messages to channels, and channel chat requires
player input. The addon therefore uses regular messages prefixed with `GF1#` in a hidden
transport channel. The addon hides this channel; members without the addon can see its messages.
Chat and LFM messages are sent when you type or click. Presence is sent as a channel message
on a keypress or click (roughly every four minutes), and through addon whispers while you are idle.
Players coming online receive direct replies from other participants. Inactive players are removed
after ten minutes. TBC support has not yet been fully verified in the game.

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

## Usage

Write in guild chat (`/g`) as usual. The addon shares your own messages with addon users in the
connected guilds. Synchronization is enabled by default. Disable it with `/tc sync off` and enable
it again with `/tc sync on`; the setting is saved for your account.
Disabling synchronization stops automatic forwarding of your own guild messages. You can still
read shared messages and send messages manually with `/tc text`.
Officer chat, regular whispers, and messages from players without the addon are not forwarded.
All participants need version 0.2.0 or later for guild chat synchronization.

`/tc` and `/tcg` work the same way. Regular guild chat shows messages from your own guild.
Messages from other guilds appear with a guild tag and player name in the chat window and the
addon window. They are not forwarded into the server's guild chat.

| Command | Action |
|---|---|
| `/tc sync on\|off` | Enable or disable automatic forwarding of your own guild messages |
| `/tcg` | Open or close the addon window |
| `/tcg text` | Send a message to all connected guilds (displayed as `[TAG] Name: text`) |
| `/tcg tag on\|off` | Show or hide guild tags in chat |
| `/tcg echo on\|off` | Show or hide shared chat in the regular chat window |
| `/tcg surname on\|off` | Show or hide surnames (shown by default) |
| `/tcg lfm` | Open the LFM dialog, also available through the **LFM** button |
| `/tcg lfm Dungeon` | Send an LFM notification directly using automatically detected roles |
| `/tcg lfm on\|off` | Show or hide LFM notifications from other guilds |
| `/tcg who` | Refresh the online member list |
| `/tcg status` | Show diagnostic information |

The addon window shows all online members of your own guild. For other guilds, it shows players
running the addon. Click a player name to whisper, or click a guild row to collapse it.
Chat history is saved, up to 200 messages.

Right-click a player and select **Set nickname** to assign a local nickname. It appears as
`FirstName(nickname):` in chat and `FirstName(nickname)` in the member list, even when surnames
are enabled. Clear the nickname to remove it. With `/tcg surname off`, players without a nickname
are shown by first name only. These settings are saved for your account and apply only to the addon.

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

Click **LFM** in the addon window or use `/tcg lfm`. The dialog fills in the roles your group
is missing, based on a five-player party: one tank, one healer, and three DPS. Click the role
buttons to adjust the selection.

Enter a dungeon and send the notification. All connected guilds receive a notification in the
middle of the screen, such as `Name1, Name2 are looking for Healer + 2 DPS`, with the dungeon
and guild tag. The notification also appears in chat with a clickable player name.

Roles come from assigned group roles when the client provides them. Otherwise, the addon
estimates them (Priest = healer, other classes = DPS), so check the dialog before sending.
You can send at most one notification every 30 seconds.
