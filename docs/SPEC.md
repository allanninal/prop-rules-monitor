# Prop Rules Monitor: specification

An indicator that measures an account against a prop-firm style rule set that the user types in. It only measures and warns:
it never opens, closes or changes a trade, so it works without automated trading enabled. Engine:
`mql5/Include/PropRulesMonitor/MonEngine.mqh` (MT4: `mql4/Include/PropRulesMonitor/MonEngine.mqh`).

## Daily loss limit
- Day-start reference at the reset instant: the balance, the equity, or the higher of the two.
- Limit: a percentage of the account size, or of that reference.
- Floor = reference - limit. A breach is equity at or below the floor (open trades count).
- The reset is a time of day (an hour 0-23) in a chosen zone: broker server time, Central Europe, UTC, New York, London or UTC+3.
  The broker's own clock is detected (Auto), or chosen: New York close (UTC+2/+3 with US daylight saving), EET (UTC+2/+3 with
  European daylight saving) or a fixed offset. Daylight saving uses built-in rules: US from the second Sunday of March 07:00
  UTC to the first Sunday of November 06:00 UTC; EU from the last Sunday of March to the last Sunday of October, 01:00 UTC.
- When the indicator was not running through the reset, the day start is rebuilt: the current balance minus every deal since the
  reset. The panel then says "rebuilt" (equity at a reset that was missed cannot be known).
- At the reset crossing, money already closed after the reset instant (a late first tick, stops filled in a gap) is taken out
  of the new day start and of yesterday's end-of-day balance.

## Max loss
- Account size: the input, or the first deposit in the history.
- Static: floor = account size - max%.
- Trailing: floor = the highest equity, closed balance or end-of-day balance - max% of the account size; optionally it stops
  rising once it reaches the account size.
- Two-stage: the first max% until the closed balance has gained a given %, then a smaller fixed %.
- Share of the budget used: 0 with the full amount of room, 100 at the floor.

## Account
- Equity, profit against the account size, profit target in % (optional), trading days (days with at least one new trade) against
  a minimum (optional), closed P&L since the reset.

## Alerts
- A warning once per day (daily) or per episode (max loss) when a given % of a limit is used, and a breach alert; pop-up and
  push. Nothing is sent in the Strategy Tester.

## Stored values
Terminal global variables `PRG.<login>.MON.<field>` keep the day start and the peaks across restarts, re-attaches and timeframe
changes.
