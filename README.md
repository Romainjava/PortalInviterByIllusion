# Portal Inviter by Illusion

Portal Inviter by Illusion is a Mage utility addon for WoW TBC Anniversary. It automatically invites players who ask for portals in supported chat channels, then helps you manage the request with a small portal queue, friendly whispers, sound cues, and income tracking.

This project is a maintained fork of PortalInviter by m1kas, licensed under the MIT License. The fork is maintained by Illusion aka Romainjava.

## Why This Fork Exists

Portal selling is fast and competitive. Players ask for portals with shorthand, typos, mixed phrasing, and incomplete messages. This fork focuses on catching more of those real-world requests while keeping the addon friendly, readable, and lightweight.

The main goals are:

- Keep the simple Portal Inviter workflow.
- Improve shorthand, typo, and fuzzy matching.
- Make customer whispers feel less robotic.
- Support localized clients by resolving portal spells from spell IDs.
- Keep the project public and contribution-friendly on GitHub.

## Features

- Auto-invites players requesting Mage portals.
- Watches Say, Yell, General, Whispers, and Battle.net Whispers.
- Keeps Trade chat scanning disabled to prioritize buyers in your area.
- Detects common shorthand such as `shat`, `uc`, `tb`, `sm`, `og`, `prt`, and `tele`.
- Handles many typos and fuzzy destination spellings.
- Supports faction-specific destinations for Horde and Alliance.
- Ignores seller chatter such as `WTS` and `LFW`.
- Ignores requests while you are queued for BG, Arena, or LFG.
- Prevents repeat invites with a built-in cooldown.
- Adds a draggable minimap button with quick toggles.
- Plays invite alerts and destination sounds through the Master sound channel.
- Marks you with a star after a buyer joins.
- Adds a portal queue with clickable cast buttons when the portal spell is known.
- Resolves cast buttons from spell IDs, then uses the localized spell name returned by the WoW client.
- Sends configurable friendly whispers after join, when destination is missing, or when the target is already grouped.
- Announces portal casts to party or raid.
- Tracks portal trade income and displays it in an income window.
- Includes debug tools, self-tests, and message-check commands.
- Supports auto-mode where invites are only enabled while you are in a capital city.

## Slash Commands

The main command is `/port`. The alias `/pibi` is also registered for Portal Inviter by Illusion.

`/port on` or `/port off`

Enables or disables automatic invites.

`/port sound on` or `/port sound off`

Enables or disables sound alerts.

`/port status`

Displays the current addon status.

`/port auto on` or `/port auto off`

Enables or disables capital-city-only mode.

`/port check <message>`

Tests a single message against the matcher and explains the result.

`/port test`

Runs the bundled matcher fixtures.

`/port income`

Opens the income window.

`/port tutorial`

Opens the in-game guide.

## Tips

You will usually get the best results in busy areas where Say, Yell, and General are active. These channels are layer-specific, so results can vary by layer.

Competition is normal. If the game reports that the target is already in a group, another Mage may have invited first, or the player may already be questing with someone. The optional already-grouped whisper can help recover some of those cases.

Use `/port check <message>` when a request does not behave as expected. It shows whether the matcher accepted the message, which destination was detected, and why.

## Installation

Install the addon folder into your WoW AddOns directory, then reload the game.

For CurseForge packaging, the folder may be named after the project slug. Sound paths are resolved dynamically from the loaded addon folder name.

The fork stores settings in `PortalInviterByIllusionDB`. If an old `PortalInviterDB` saved variable is present, it is used once as the initial data source so existing settings and income history can carry over.

## Credits

- Original addon: PortalInviter by m1kas.
- Fork and ongoing maintenance: Illusion aka Romainjava.
- Original CurseForge Project ID: 1517650.

## License

Portal Inviter by Illusion is distributed under the MIT License. See `LICENSE` and `NOTICE`.

## AI Disclosure

AI assistance is used to help with implementation, documentation, and maintenance. Changes are reviewed by the maintainer before release.

This project is not affiliated with Blizzard Entertainment, CurseForge, or Overwolf.
