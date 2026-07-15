# Dual-Window Auto-Fallback Design

**Date:** 2026-07-15
**Status:** Approved

## Problem

Auto-rotation (`checkAutoRotation`) currently switches accounts based only on the
**5-hour** usage window. The **weekly** window is displayed in the menu but never
triggers a fallback. Users hitting the weekly cap get no automatic switch. The
single `rotationThreshold` (used %) does not match the menu UI, which shows
**remaining %**.

## Goals

1. Auto-fallback triggered by **either** the 5-hour or the weekly window.
2. Separate, configurable thresholds per window.
3. Threshold expressed as **remaining %** (matches menu display).
4. When both accounts are exhausted, do not switch; surface a warning.

## Non-Goals

- Support for more than 2 accounts (keep existing 2-account constraint).
- Popup/notification on exhaustion (menu + tooltip only, to avoid repeat popups).
- Migration of the old `rotationThreshold` value (new defaults apply).

## Settings (UserDefaults)

| Key | Meaning | Default | Cycle steps |
|-----|---------|---------|-------------|
| `rotationThreshold5h` | 5-hour switch trigger, remaining % | 20 | 10, 20, 30, 40 |
| `rotationThresholdWeekly` | weekly switch trigger, remaining % | 20 | 10, 20, 30, 40 |

The old `rotationThreshold` key (used %) is retired. `rotationEnabled` unchanged.

## Decision Logic

Percentages are stored as **used %**; remaining = `100 - used`. A window is
"over limit" when its remaining is at or below its threshold, and only when the
value is known (nil = unknown = not over, to avoid false triggers on missing data).

```
isOverLimit(fiveHourUsed, weeklyUsed, thr5h, thrWeekly):
    (fiveHourUsed known AND 100 - fiveHourUsed <= thr5h) OR
    (weeklyUsed   known AND 100 - weeklyUsed   <= thrWeekly)

decideRotation(activeOver, inactiveOver, inactiveKey):
    if not activeOver        -> none
    if inactiveOver          -> allExhausted   (warn, no switch)
    else                     -> switchTo(inactiveKey)
```

Preconditions (unchanged): `rotationEnabled`, exactly 2 accounts, `!isSwitching`.

`decideRotation` and `isOverLimit` are pure top-level functions so they can be
driven from both the UI (`checkAutoRotation`) and a testable CLI subcommand.

## UI (rebuildMenu)

- Replace the single threshold menu item with two: `5시간 전환 ≤ X%` and
  `주간 전환 ≤ Y%`, each cycling its value on click.
- When both accounts are exhausted (`allLimitsReached`), show a warning item
  (`⚠ 모든 계정 한도 임박`) under the usage header and reflect it in the status-bar
  tooltip.
- New localized strings (en/ko): `threshold_5h`, `threshold_weekly`,
  `all_limits_reached`.

## CLI

Extend `rotation`:

- `rotation status` prints `rotation:on|off thr5h:<n> thrWeekly:<n>`.
- `rotation threshold5h <10|20|30|40>` / `rotation thresholdWeekly <...>`.
- `rotation decide <a5> <aWk> <i5> <iWk>` — each arg a used % or `-` for unknown;
  prints `none` | `switch` | `all-exhausted` using the stored thresholds. Enables
  offline shell testing of the pure decision logic.

## Testing

`tests/rotation_fallback_test.sh` drives `rotation decide` across cases:
5h-only trigger, weekly-only trigger, both-exhausted, unknown windows, healthy.
Existing `build.sh` + test suite must stay green.
