# Auto-Rotation: Threshold-Based Account Switching

## Problem

With two Codex accounts, usage limits hit on one account while the other sits idle. Users must manually switch accounts, losing time and potentially hitting rate limits mid-session.

## Solution

Polling-based automatic account rotation. On each 5-second refresh cycle, check if the active account's 5-hour usage exceeds a configurable threshold. If so, switch to the other account automatically.

## Scope

- Only applies when exactly 2 accounts exist
- Only monitors 5-hour usage window
- Requires Codex restart on switch (~10s)
- No HTTP proxy or request-level routing

## Design

### Data Model

Two new UserDefaults-backed properties on `AppDelegate`:

- `rotationEnabled: Bool` — key `"rotationEnabled"`, default `false`
- `rotationThreshold: Int` — key `"rotationThreshold"`, default `80`

### Rotation Trigger Conditions

All must be true for automatic switch:

1. `rotationEnabled == true`
2. `accounts.count == 2`
3. `isSwitching == false` and `isRefreshing == false`
4. Active account's `fiveHourUsedPercent >= rotationThreshold`
5. Inactive account's `fiveHourUsedPercent < rotationThreshold`

Condition 5 prevents switching to an already-exhausted account.

### Execution Flow

Inserted at the end of `refreshAccounts()`, after `rebuildMenu()` on main thread:

```
if rotationEnabled && accounts.count == 2 && !isSwitching {
    if let active = accounts.first(where: { $0.isActive }),
       let inactive = accounts.first(where: { !$0.isActive }),
       let activePct = active.fiveHourUsedPercent,
       let inactivePct = inactive.fiveHourUsedPercent,
       activePct >= rotationThreshold,
       inactivePct < rotationThreshold {
        switchTo(key: inactive.key)
    }
}
```

- No alert on auto-switch (non-disruptive)
- Reuses existing `switchTo()` with switchAnimation
- After switch, `lastUsageFetch = nil` forces immediate usage fetch for new account
- If both accounts exceed threshold, no rotation (prevents infinite loop)

### UI

**Menu bar button:**
- Rotation ON: append ` ⟳` to status title. Example: `kevin · 5hr 72% ⟳`
- Rotation OFF: no change

**Menu items (inserted after usage section, before accounts):**

```
─────────────
⟳ Auto-rotation: ON          ← toggle action
  Threshold: 80%              ← cycle 60/70/80/90 on click
─────────────
```

- "Auto-rotation: OFF" when disabled
- Both items disabled when accounts < 2 or isSwitching
- Threshold cycles through `[60, 70, 80, 90]` on click

### Localization

New string keys (en + ko):

| Key | English | Korean |
|-----|---------|--------|
| `rotation_on` | Auto-rotation: ON | 자동 전환: 켜짐 |
| `rotation_off` | Auto-rotation: OFF | 자동 전환: 끔 |
| `threshold` | Threshold: %@ | 임계치: %@ |
| `status_rotation` | %@ ⟳ | %@ ⟳ |

### Files Changed

| File | Change |
|------|--------|
| `Sources/main.swift` | Add rotation state, trigger logic, menu items |
| `Resources/en.lproj/Localizable.strings` | Add 4 string keys |
| `Resources/ko.lproj/Localizable.strings` | Add 4 string keys |

## Edge Cases

- **Both accounts exhausted**: No rotation. Both exceed threshold.
- **Single account**: Rotation toggle disabled, no trigger.
- **Switch in progress**: Guarded by `isSwitching`.
- **Manual switch during rotation**: Works normally. Rotation checks run on next cycle.
- **Threshold change mid-cycle**: Takes effect on next refresh (5s).
- **App launch**: Rotation starts checking after first refresh completes.
