# Pulsar Vector

Pulsar Vector is an unofficial SwiftUI iPhone app that brings turn-by-turn guidance to the 2026 Bajaj Pulsar N250’s existing instrument cluster. MapKit plans the route, the local Swift guidance engine tracks progress, and CoreBluetooth sends dashboard updates over Bluetooth Low Energy (BLE).

**Development status:** this is a development build, not a road-validated release. Parked bench checks and the owner's ride feedback have shaped roundabout exits, spoken directions, and dashboard updates, but they do not establish end-to-end navigation reliability. Don't rely on this build as your sole navigation aid. See the [support matrix](docs/support-matrix.md) for feature-by-feature evidence and limits.

## Try it in the simulator

Use macOS with Xcode 26 or later, an installed iOS simulator runtime, and XcodeGen. From the repository root:

```sh
brew install xcodegen
xcodegen generate
open PulsarVector.xcodeproj
```

1. Select the **PulsarVector** scheme and an iPhone simulator, then run the app.
2. Open **Ride settings → Advanced** and enable **Simulation mode** before starting a ride. Use **Show Diagnostics tab** in the same section to reveal the bench tools.
3. Return to the destination picker, expand **Coordinates or plus code**, and enter `12.9716, 77.5946`. Use the entered destination, confirm it, then tap **Start**.
4. Watch the turn card and distance update on the synthetic route. Tap **End ride** to return to the picker.

Simulation needs no bike, API key, or live route request. It demonstrates the app flow, not physical dashboard behavior. See the [setup guide](docs/setup.md) for Xcode setup and iPhone signing.

## Before and after a ride

- **Pre-Ride Ready:** While parked, check **Route**, **Position**, **Bike**, and **Helmet audio** in the route preview. **Start** checks your current position in live mode. Bike connection and spoken directions do not block starting.
- **Route alternatives:** In a live preview, tap **See routes on the map**. Tap a route line or its time-and-distance label to select it, then return to **Ride** and tap **Start**.
- **Siri Home or Work preview:** Save **Home** or **Work** under **Ride settings → Places**. Try “Preview my route home in Pulsar Vector” or “Preview my route to work in Pulsar Vector.” Siri opens the app for a preview; tap **Start** separately. Siri invocation has not been validated on a physical iPhone.
- **History and GPS Recaps:** Open **History → GPS Recaps** and turn on **Record GPS tracks** before starting a new ride. It is off by default, separate from **Keep ride history**, and never backfills earlier rides. Recaps stay on this phone and show only GPS fixes the app accepted during recording; gaps are left unconnected. Open a recap to **Export GPX** or **Delete recap**. Export includes precise recorded coordinates, timestamps, and GPS accuracy; deleting the recap does not remove exported copies. See the [support matrix](docs/support-matrix.md) for recording caps.

## How it works

The rebrand keeps existing `n250ride://` links working. The repository URL, source paths, and internal identifiers are unchanged, including the `N250Ride` target and `N250Ride.app` build product.

| Layer | Design |
| --- | --- |
| [SwiftUI app and platform adapters](N250Ride/) | MapKit supplies route candidates and Core Location supplies position samples. The adapters turn those results into plain Swift values that can also come from test doubles. A new route is prepared before it replaces the active one. |
| [RideCore](Packages/RideCore/) | A standalone Swift package snaps position to route geometry, tracks progress, detects off-route movement, and produces typed navigation snapshots. An injected clock supports repeatable fixture replay and stale-state tests. |
| [Cluster protocol](docs/protocol/) | RideCore encodes guidance and status frames and schedules writes. The CoreBluetooth adapter handles the physical link; the parked console and manual checklist let a tester compare write outcomes with what the cluster actually shows. |
| [Share extension](N250RideShare/) and [Live Activity](N250RideWidgets/) | The share extension imports destinations. The widget extension presents current guidance on supported Lock Screen and Dynamic Island surfaces. |

Live routing uses **MapKit’s car profile**, not a motorcycle-specific profile. The optional Google adapter is excluded from the default build; see [feasibility](docs/feasibility.md) and the [cost model](docs/cost-model.md).

## Current limits

- Locked-screen and background operation on a physical device remain unverified. Declared background modes and simulator behavior are not proof of reliability on the road.
- Road reliability is not validated and six-hour endurance has not been verified. Do bike checks while parked.
- Cluster timeout after disconnection remains unverified on the N250. Status packet profiles require separate parked validation.
- Real helmet or earphone voice output and sharing from another app's Share sheet still need device testing.
- ETA is Apple's route time scaled by remaining distance. Traffic is not refreshed until a reroute.
- Maneuver classification uses English instructions, with a more conservative geometry fallback for other languages.
- iOS does not let this app answer phone calls or read caller names.

## Tests and documentation

```sh
scripts/test.sh core  # Standalone RideCore tests
scripts/test.sh app   # App and UI tests on an iPhone simulator
```

The core suite covers packet encoding, write scheduling, route guidance, and session behavior. The [simulator UI tests](N250RideUITests/SimulationUITests.swift) cover destination entry, confirmation, start, and stop. Neither suite validates road safety or physical-cluster compatibility.

[Setup and device installation](docs/setup.md) · [Support matrix](docs/support-matrix.md) · [Troubleshooting](docs/troubleshooting.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
