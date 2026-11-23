# peaktime

A macOS menu bar app that tells you when the DeepSeek API enters or leaves **peak hours** (double pricing). Everything is built from the terminal — no Xcode required.

## Implemented rules

Source: <https://api-docs.deepseek.com/quick_start/pricing/>

- **Double price:** 01:00–04:00 and 06:00–10:00 **UTC**, Monday through Friday.
- **Half price:** everything else, including weekends and Chinese public holidays.
- The rule is always evaluated in **UTC**; no time zone is hardcoded. In Tijuana that means **17:00–20:00 and 22:00–02:00** in winter (UTC−8) and **18:00–21:00 and 23:00–03:00** in summer (UTC−7), but the app works the same in any country.
- **The pricing decision does not depend on the Mac's time zone**; only the presentation does. Display code uses `TimeZone.autoupdatingCurrent`, so it adapts to the user's country and reacts immediately if the system time zone changes while the app is running (`NSSystemTimeZoneDidChange` observer).
- `Asia/Shanghai` is deliberately fixed: Chinese holidays are defined by Beijing calendar dates.
- Applies to the API only (`api.deepseek.com`); the web/app chat has no hourly double charge.

The logic lives in `Sources/PeakTimeCore`, and the Chinese holidays (2026–2027) in `ChineseHolidays.swift`. **Update that list every year** when DeepSeek/timeanddate publish the next calendar.

## Commands

```bash
./build.sh                  # build, assemble dist/peaktime.app, and sign it
swift test                  # 20 tests for dates, zones, language, transitions, timeline
open dist/peaktime.app      # launch
pkill -x peaktime           # quit
cp -R dist/peaktime.app /Applications/   # install (optional)
```

## Install

Build the app first, then copy the bundle into Applications:

```bash
./build.sh
cp -R dist/peaktime.app /Applications/
open /Applications/peaktime.app
```

The app is built locally and signed ad hoc, so it has no quarantine attribute and normally opens without a Gatekeeper warning. If you ever copied it from somewhere that added one, remove it:

```bash
xattr -dr com.apple.quarantine /Applications/peaktime.app
```

After the first launch, allow notifications in System Settings → Notifications → peaktime.

To update, quit the running app and replace the bundle with a fresh build:

```bash
pkill -x peaktime
./build.sh
rm -rf /Applications/peaktime.app
cp -R dist/peaktime.app /Applications/
```

To uninstall:

```bash
pkill -x peaktime
rm -rf /Applications/peaktime.app
defaults delete com.local.peaktime   # optional: clear the notification dedup preference
```

## Behavior

- The menu bar shows **only an icon**, no text: `chart.line.uptrend.xyaxis.circle.fill` during peak hours and `tag.circle.fill` during the discount. They render as **native template SF Symbols**, so macOS paints them black and white like the other system icons (no color backgrounds and no clipping).
- **All text follows the system language** (Spanish / English): the countdown, "Starts:", "Quit", and the notifications live in a `Localizable.xcstrings` catalog; dates use `Locale.current` (`dom, 22 nov, 17:00` in Spanish, `Sun, Nov 22 at 5:00 PM` in English). A system language change is picked up on relaunch.
- The menu is intentionally minimal: a **short countdown** (`2h 24m until discount` / `2h 24m until peak hours`), an **8-hour horizontal timeline** from now (🟢 discount, 🟠 double price), the **local time when the next pricing period starts** (`Starts: Mon 23 Nov 17:00`), and **Quit**. Nothing else. Following Apple's HIG, the three components share a 20 px horizontal inset, are aligned to the same leading edge, and are separated by **8 px of vertical space** (4 px above + 4 px below each row); a separator groups the informational items from the "Quit" action.
- The menu is **pure AppKit** (`NSStatusItem` + `NSMenu`): SwiftUI's `MenuBarExtra` discarded custom views and the bar never appeared. The bar is now an `NSMenuItem` with a native `NSView` drawn with `NSBezierPath` (220 px wide inside a 260 px view, rounded ends). Each block's width is proportional to its real duration: if the next peak is more than 8 hours away the bar is all green; as it approaches, green shrinks and orange grows (and the reverse during a peak).
- The countdown and timeline are recalculated every second. The timer is registered on `RunLoop.main` in `.common` mode (which includes `.eventTracking`), so it **keeps updating while the menu is open**. Notifications fire once per transition, deduplicated in `UserDefaults`:
  - `⏰ DeepSeek price rises in 15 min`
  - `📈 Peak pricing on DeepSeek`
  - `📉 Half price on DeepSeek`
- **Notifications only work while the app is running** (no system notifications are scheduled for when it is closed).

## Quick notification test without waiting

Advance the app's clock with an environment variable (ISO 8601, UTC):

```bash
pkill -x peaktime
defaults delete com.local.peaktime peaktime.lastNotified
env PEAKTIME_SIMULATE=2026-11-23T00:59:00Z open dist/peaktime.app
/usr/bin/log show --last 2m --info --style compact | grep 'Notification sent'
```

That value is 60 seconds before the 01:00 UTC peak: the pre-alert fires at launch and the "double price" alert one minute later. Afterwards, clear the preference and relaunch without the variable.
