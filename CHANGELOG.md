# Changelog

## 1.1.6

- Restored Horde destination loading by reading the English faction return from `UnitFactionGroup("player")`, so requests like `UC`, `Stonard`, and `TB` no longer fall back to unknown destinations.
- Added French destination aliases like `Fossoyeuse`, `Pierreche`, `Pitons du Tonnerre`, `Hurlevent`, `Forgefer`, and `Lune d'Argent`.
- Extended exact and fuzzy destination matching beyond 2-word aliases so multi-word French names resolve correctly.
- Added regression coverage for mixed phrases like `WTB portal to UC from ogrim`, `LF stonard tp plz`, and French Horde portal requests.

## 1.1.5

- Fixed Horde destination loading by reading `UnitFactionGroup("player")` correctly instead of pulling a nil faction value from the wrong return slot.
- Restored shorthand Horde requests like `WTB PORT UC` so they resolve to `Undercity` instead of falling back to the missing-destination whisper.
- Added matcher coverage for the uppercase `WTB PORT UC` regression so future request-filter changes keep Undercity aliases working on Horde mages.

## 1.1.4

- Added CurseForge packaging metadata with an explicit `PortalInviterByIllusion` package target.
- Excluded the legacy `PortalInviter.toc` from packaged builds so CurseForge sees a single addon TOC.

## 1.1.3

- Accepted portal requests from all chat channels instead of only General for channel chat.
- Added regression coverage for `wtb portal to shatt`, `lf mage port stonard`, and channel support checks.

## 1.1.2

- Simplified the README while keeping the addon behavior, options, and commands documented.
- Added clearer fork attribution, original project link, and license note for distribution review.

## 1.1.1

- Fixed addon startup on Classic Lua by reducing matcher upvalues.
- Restored slash commands and minimap button initialization.

## 1.0.0

- Rebranded the fork as Portal Inviter by Illusion.
- Added MIT license and fork attribution.
- Switched saved variables to `PortalInviterByIllusionDB` with migration from `PortalInviterDB` when available.
- Expanded portal request matching for shorthand, typos, and friendly phrasing.
- Added configurable friendly customer whispers.
- Resolved portal cast buttons from spell IDs for localized clients.
- Added known-spell checks before suggesting a portal cast button.
- Expanded matcher fixtures.
