# Support matrix: Apple MapKit build (last updated 2026-11-21)

## Parked N250 bench

The manual checklist for app **1.0 (1)** with the **`legacy55`** status profile records **52/52 items tried, not 52 passes**. These observations apply to the tested cluster and setup, not to other profiles or road use. Source: the owner's manual-checklist report; the exported report is **not stored in this repository**, so this table cannot be re-checked from the repository alone.

| Area | Observation and limit |
| --- | --- |
| iPhone Bluetooth and status | The iPhone connected to the N250 and sent test cues. Battery appeared; signal values 0, 2, and 4 worked in the test, but 7 did not. These were test values, not measurements of iPhone reception. |
| Basic navigation | Start, turns, U-turn, straight at **1.5 km**, metre and kilometre units, destination reached, and stop clearing were observed. Cluster timeout after disconnection remains unverified. |
| Close turn and ETA/ETD | The close-turn cue did **not** blink. The ETA/ETD toggle attempt showed **12.6 km only**; it did not demonstrate time switching. |
| GPS and rerouting probes | GPS status 3 also showed **NO GPS**. In a later parked test, solid icon 66 explicitly showed **REROUTING** and a circular bar, plus a bar on the RPM side. Live rerouting on the bike remains untested. The unlisted 77, 83, and 87 probes showed no direction. |
| Roundabouts and other icons | The checklist log records counterclockwise circulation for 78 and clockwise for 85. The export does not establish exact exit-angle calibration. Most listed arrows appeared as expected; 84 and 89 did not show the expected ferry indicators. |
| Calls | Synthetic incoming, number, and answered states were observed; the outgoing probe showed nothing. A real incoming call appeared, and accept/reject with the cluster's Mode button was observed. That is not evidence that the app can answer calls or access caller names. |
| Real vs. synthetic alerts | Real missed-call, SMS, and WhatsApp indicators worked. The latest synthetic alert attempts reported missing channels (0310 and 0410), so those attempts did not write. Earlier writes were acknowledged but no alert was observed on the display. A write acknowledgement alone does not prove display. |

## Earlier owner observations (2026-11-12 and 2026-11-13)

Kept as recorded at the time. Where the parked bench above differs, the bench is newer.

| Area | Status | Evidence |
| --- | --- | --- |
| Install on owner's iPhone | Installed 2026-11-12 (iPhone17,3, iOS 27.0.1, free Personal Team signing, expires after 7 days). First launch pending the owner trusting the developer certificate | task-progress.md |
| iPhone ↔ N250 Bluetooth link | **Unverified** (owner reports N160/NS200 work; not this N250, not from iPhone) | task 20 / task 9 |
| N250 status profile | Likely **legacy55** (owner: network bars appeared; phone has legacy55 saved). Battery display not yet confirmed. Signal bars are a fixed placeholder (4) - iOS gives apps no signal strength | task-09-15-procedures.md |
| Turn arrows on N250 (parked) | Owner-observed 2026-11-12: test arrows display correctly | task-09-15-procedures.md |
| Roundabout display | Owner bench 2026-11-12: value = angle on a fixed picture, 1/8 turn per step. Glyph 85 sweeps clockwise 1 sharp left → 7 sharp right; glyph 78 anticlockwise 1 right → 6 sharp left. Clockwise (India) roundabouts use 85. App sends the value for Google's exit direction; unknown/undrawable directions clear the dashboard. Diagnostics samples to be confirmed on the bike | task-09-15-procedures.md |
| Stop frame clears N250 display; cluster timeout after disconnect | **Unverified** | task 9 |
| Live Apple guidance on the road | **Not yet ridden** - on-device route request, locked-screen location and real GPS untested | task 15/17 |
| Console bench results | Owner 2026-11-13: GPS flag 0 shows **NO GPS**; GPS flag 2 shows the arrow only; frame types 2 and 3 and the text field show nothing. Missed-call (0310), SMS and WhatsApp (0410) packets are acknowledged but **not displayed** | owner report 2026-11-13 |

## Software checks and open device questions

Unit tests, simulator runs, and route replays do not establish real-device background reliability or road safety.

Latest test run (2026-11-21): 170 core tests and 140 app unit tests passed. All 18 simulator UI tests passed, two of them (`testCustomStatusControlsEnableWithToggle`, `testSaveUseAndDeleteFavourite`) only on a rerun after a switch tap did not register; the live Apple route test was skipped.

| Area | Status | Evidence |
| --- | --- | --- |
| Packet encoding (TBT 48-byte, status 55/89-byte) | Verified against pinned Ride Relay encoder, byte-for-byte | 99 + 28 golden vectors, `scripts/test.sh core` |
| Session safety (stale/stop/reroute/reconnect clearing, old-route rejection) | Verified in unit tests on a virtual clock | RideCore tests |
| Route request limits / no auto-retry / Bluetooth cannot request routes | Verified in unit tests | RideCore tests |
| Plus-code and coordinate parsing | Verified against 420 Open Location Code reference vectors | RideCore tests |
| Diagnostics exclude keys, coordinates, road text | Verified with sentinel values | RideCore tests |
| iOS app build | Verified: simulator and generic-device (arm64, unsigned) builds succeed, Xcode 27.2, Swift 6 strict concurrency, no warnings in app code | task-11-14-app-tests.txt |
| Simulation UI flow (paste → confirm → start → stop, favourites, short-code rejection) | Covered by simulator UI tests; earlier screenshots small/large, light/dark, largest text size | [SimulationUITests](../ClusterNavUITests/SimulationUITests.swift), task-01-tests.xcresult, task-14-screens/ |
| Pre-Ride Ready | Route preview shows Route, Position, Bike, and Helmet audio. In live mode, Start checks current position; Bluetooth and spoken directions are informational, not start requirements. Not a road-readiness guarantee. | Ready panel simulator test passed |
| Google SDK adapter | Excluded from the current build (owner chose Apple MapKit 2026-11-12); code kept behind `canImport`, compiled and fixture-tested against SDK 11.3.0 before exclusion | task-11-14-app-tests.txt |
| Google eligibility (GATE-1) | **Open**: policy says commercial applications only | [Feasibility](feasibility.md) |
| Zero-spend boundary (GATE-2) | **Open**: no hard cap proven | [Cost model](cost-model.md) |
| Locked-screen background operation | **Unverified** - background modes declared (Bluetooth, location) | task 15 |
| Road use / six-hour endurance | Owner ride feedback exists. Road reliability is not validated, and six-hour endurance has not been verified. | Owner feedback |
| Caller name on dashboard | The app cannot read real caller names. A synthetic caller label displayed in the parked test; real caller-name display is not confirmed. | Parked checklist and earlier owner observations |
| Apple MapKit routing | Live provider. Terms checked (DPLA §3.3.3(F)(iii) notice shown). **Car-profile** routes only (no motorcycle profile in MapKit) | task-19-apple-terms-and-api.md |
| Guidance engine (snapping, progress, off-route/reroute throttle, GPS gaps, arrival, ETA) | Verified in unit tests and by replaying 4 real Apple Maps Bengaluru routes at 10 m spacing: all reach arrival, no false reroutes (incl. a U-turn route) | task-19-real-route-check.txt |
| Maneuver classification from Apple steps | 45/45 maneuvers on 4 real routes classified (turns, keeps, U-turns, a roundabout with direction). Uses English instruction text: other phone languages fall back to geometry with stricter suppression | task-19-real-route-check.txt |
| ETA during ride | Apple's route time scaled by remaining distance; no live traffic refresh until a reroute | GuidanceEngine |
| Place search (Apple Maps) | Verified live in simulator: "Orion Mall" → suggestions → resolved; Bengaluru landmarks checked on Mac (Cubbon Park, Orion Mall, Lalbagh, Bangalore Palace). Result shown on an Apple map (terms Att. 6 §2.4) | live-apple-route.xcresult |
| Alternative routes | Verified live: 3 Apple routes returned in ~2 s from one request; switching sends no request (unit-tested with spy) | live-apple-route.xcresult, AppModelProviderTests |
| Live guidance with moving location (simulator) | A simulated ride along an Apple route counted down from 210 m to 90 m and produced a close-turn frame below 100 m. This was frame generation, not observed cluster blinking. | ui-redesign-screens/6*, 7* |
| Custom status packet (Diagnostics) | Volume/battery/signal/raw-byte overrides encoded and sent (unit-tested); effect on N250 **not yet observed** | CustomStatusTests |
| Spoken directions | Planner unit-tested (stages ~1 km / 300 m / now, reroute, GPS lost, arrival); speech runs in simulator rides. Real helmet/earphone audio **not yet heard on device** | VoicePromptTests |
| Avoid tolls / highways | Passed to Apple Maps on every request and reroute (unit-tested forwarding) | AppModelProviderTests |
| Live Activity (Lock Screen, Dynamic Island) | Simulator observation: compact island showed arrow and distance during a moving simulated ride. Physical-device background behavior remains open. | ui-redesign-screens/8-dynamic-island.png |
| Share → ClusterNav, paste link, `n250ride://` | Link parser tested on Apple/Google/WhatsApp/geo/plus-code forms; cross-process hand-off verified (test runner wrote, app opened confirmation). Real Share sheet from Google Maps **not yet tried on device**; Google short links expanded by following their redirect | MapLinkTests, SimulationUITests |
| Home / Work / recents | One-tap Home goes straight to route options; recents deduplicated within 75 m (tested) | SavedPlacesTests, AppModelProviderTests |
| Siri Home / Work preview | Requires a saved place. Opens the app to preview only; Start is a separate tap. An unfinished ride or pending recovery can block the preview. **Siri invocation has not been validated on a physical iPhone.** | SavedPlaceShortcutTests (app behavior, not Siri invocation) |
| Bluetooth console | Parked test tool. Console writes and display observations are separate pieces of evidence; see the bench results above. | Manual checklist and console observations |
| Dashboard uses Apple notifications (ANCS) | Owner: "Share System Notifications" is on for the bike in iOS Bluetooth settings | owner report 2026-11-12 |
| Incoming call stays on the dashboard | A real call appeared, then vanished within seconds: the app's 5 s status packet says "no call". Status packets pause while iOS reports a call (CallKit, state only) and for at least 15 s from the first ring; navigation, dashboard arrows and voice continue throughout. **Not yet re-tested on the bike** | owner report 2026-11-13 |
| Ride health (phone, Live Activity) | The app suppresses guidance when the last GPS measurement is at least 5 s old or its accuracy is worse than 50 m. Physical Lock Screen behavior remains unverified. | RideHealthTests, RouteTransactionTests, AppReplayTests |
| Long-straight guidance | A synthetic 4.2 km replay produced uninterrupted guidance through the transition to a turn. A separate replay reproduced and fixed an unnecessary reroute when a fix was close to the boundary of the route-matching window. Neither replay establishes the cause of the reported road blanking. | [CoreReplayTests](../Packages/RideCore/Tests/RideCoreTests/CoreReplayTests.swift) |
| Route changes are transactional | A route is prepared without touching the active one and committed only on Start or an accepted reroute; Start checks a current fix within 100 m of the route start; previews expire after 2 min; one calculation at a time with a 30 s limit | RouteTransactionTests, AppleProviderAdapterTests |
| Manual recalculate / cancel / retry | Implemented; a failed reroute keeps the old route, which guides again only on a fresh on-route fix. While an authorised recalculation runs and the rider is off the route, the dashboard is sent icon 66 (shown as **REROUTING** on the parked bench); a recalculation requested while on the route keeps the current turn. **Not observed live on the bike.** Not available in simulation (it never contacts Apple) | RouteTransactionTests |
| Write timeouts | An acknowledged write that times out stalls the link and forces a reconnect (clear first on the new link); late answers are credited to nothing; only the latest clear can be acknowledged | LinkTests, ClearDeliveryTests |
| Voice: styles, repeat, holds | Detailed/Concise, Repeat; directions keep speaking through phone calls; other audio interruptions and a lost headset pause speech; nothing missed is replayed. **Real helmet/earphone behaviour not yet heard** | VoiceAdapterTests, VoicePolicyTests |
| Bike check wizard | Parked, ordered checks with the rider's visual answers stored per bike and tied to calibration/status profile. **Not yet run on the N250** | BikeSetupTests, testBikeCheckWaitsForTheBikeAndTheRider |
| Ride recovery | Opt-in; stores destination, stop, leg and preferences only, 24 h; resume needs a new fix after the tap, a new route and Start | RecoveryFlowTests, RecoveryTests |
| Waiting destinations | Shares and links go to a local inbox (10 items, 7 days); during a ride they queue; add as stop or replace (transactional). The Share extension hand-off itself is still a named pasteboard, **not durable** until an App Group is approved | InboxFlowTests |
| One intermediate stop | Leg one ends at the stop (session ended, dashboard cleared); Continue calculates leg two from where the rider is; skip and add are new routes committed only on success | StopFlowTests, ItineraryTests |
| Ride history | Opt-in, on this phone only: date, ride time, estimated distance; no positions or place names; 100 rides / 30 days | HistoryFlowTests, RideAccumulatorTests |
| GPS Recaps | Separate, local opt-in for new rides only; no retroactive tracks. Records only admitted GPS fixes, not the planned route; gaps are not connected and distance is estimated within segments. One file per track. Caps: the newest 100 tracks are kept (the oldest is removed when a new recording starts) and 20,000 points per track. Hitting the point cap leaves an incomplete recording. GPX exports stored coordinates without added rounding, plus timestamps and horizontal accuracy; exported copies survive local deletion. | RideTrackTests; physical-device background recording remains unverified |
| Energy saving / scheduling | Work is scheduled at real deadlines instead of every 200 ms (no wakes when idle); Energy saving reduces Lock Screen updates and map animation only. **No battery measurement yet** | RouteTransactionTests.idleAppSchedulesNoWakes |
| Roundabout exits (rework 2026-11-14) | Owner ride: exits announced as "slight left" for straight and left exits, and "Now" heard while already on large circles. Cause: Apple's roundabout step ends where the route leaves the ring, so the app measured along the ring. Now the ring is found in the route line, the exit angle is the heading change from the road in to the road out, Apple's "continue"/"turn left/right" wording wins, the exit number is spoken, and the countdown ends at the ring entry. Checked against 19 real Apple Maps roundabouts (Delhi, Chandigarh) and synthetic rings. **Not yet ridden** | RoundaboutTests |
| Voice cut off mid-instruction | Owner ride. Cause: turn prompts expired 5 s after the fix they were planned from (prompts take 2.5-7.4 s). Now a started prompt finishes unless GPS is lost, the route changes, a hold starts, the ride ends, or the next maneuver's prompt is ready (which replaces it) | VoiceCutoffTests |
