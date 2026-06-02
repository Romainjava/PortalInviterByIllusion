# Portal Inviter by Illusion

Maintained fork of PortalInviter by m1kas for WoW TBC Anniversary.

This addon helps Mages sell portals by automatically inviting players who ask for a portal in supported chat channels.

What it does:
- watches supported channels for portal requests
- detects common shorthand, typos, and search patterns
- invites the player automatically when a request matches
- shows a small queue with the requested destination
- can send friendly whispers, play sounds, and track portal income

How it works:
1. Enable the addon with `/port on`.
2. The addon listens to Say, Yell, all chat channels, Whisper, and Battle.net Whisper.
3. When a message looks like a portal request, it invites the player.
4. When the player joins, the addon can help you identify the destination and continue the portal workflow.

Main options:
- enable or disable auto invites
- auto mode: only active in capital cities
- sound on or off
- friendly whisper messages
- queue window, minimap button, tutorial, and income window

Useful commands:
- `/port on` / `/port off`
- `/port auto`
- `/port sound on` / `/port sound off`
- `/port status`
- `/port check <message>`
- `/port income`
- `/port tutorial`

Original project:
https://legacy.curseforge.com/wow/addons/portal-inviter

License:
MIT License, following the original project license.

Main differences from the original:
- improved portal request matching and search patterns
- improved customer messages / whispers
- maintained on GitHub for easier updates and future options
