# Upgrade notes, 2026-09-29

The goal was to build, analyze and test on today's toolchains with the fewest risky changes. The machine was macserver,
with Flutter 3.47.4 / Dart 3.13.3, Xcode 27.0, CocoaPods 1.17.0 and uv 0.12.11 (`~/.local/bin/uv`).

## How this was chosen

This came out of a two-candidate arena. All runners were opus. (a) Minimal path: the smallest change set that
makes every command pass. (b) Full path: every dependency on its latest major, with deprecated APIs migrated.
Both got all five commands passing. The opus judge and I both picked (a) as the base, because (b) moves
livekit-agents 1.3 -> 1.8, google-genai 1.x -> 2.x, protobuf/transformers/huggingface-hub majors, camera 0.12,
record 7 and geolocator 14. None of those can be checked without a phone or a live LiveKit room with real keys.

Grafted from (b) into (a):
- The `lib/main.dart` deprecation fixes: 32 `withOpacity` -> `withValues(alpha:)`, `desiredAccuracy` ->
  `locationSettings: LocationSettings(...)`, `SemanticsService.announce` -> `sendAnnouncement(view, ...)`,
  and the unused `dart:typed_data` import removed. All of them compile against the old plugin versions:
  geolocator 13.0.4 already has `locationSettings`, and the rest are Flutter SDK APIs. `flutter analyze` is
  now clean. The one behaviour difference is that a screen-reader announcement is skipped when the widget is
  unmounted, where the old code called it anyway.
- The splash-screen `Future.delayed` became a `Timer` that `dispose()` cancels. This fixes the widget-test
  failure at its root, so (a)'s "pump 3 s after unmount" workaround is gone.
- `flutter_lints` ^3.0.0 -> ^6.0.0 (dev only; lints 3.0.0 -> 6.1.0). It still reports no issues.
- `opencv-python>=4.8.0,<5` in pyproject.toml. The lock already has 4.13, so nothing installs differently. (b)
  confirmed in a scratch venv that opencv 5.0 removes `cv2.HOGDescriptor`, which `obstacle.py` uses for its
  default person detector. The cap stops a future `uv lock --upgrade` from breaking it silently.
- (b)'s extra tests, merged into (a)'s suite (see "Tests").

Rejected from (b) (deferred, see below): every other version bump, all of `agent.py`, the `backboard_store.py`
change, `requires-python >=3.12` and `.python-version`.

## Version changes

### Flutter / Dart

| Item | Old | New |
|---|---|---|
| `environment.sdk` in pubspec.yaml | `>=3.2.0 <4.0.0` | unchanged |
| `livekit_client` constraint | `^2.0.0` | `^2.10.0` |
| `flutter_lints` (dev) constraint | `^3.0.0` | `^6.0.0` |
| All other direct constraints | | unchanged |

Resolved versions in pubspec.lock (old -> new):

| Package | Old | New | Why it moved |
|---|---|---|---|
| livekit_client | 2.6.2 | 2.11.0 | required fix (see below) |
| flutter_webrtc | 1.3.0 | 1.6.0 | pulled by livekit_client |
| dart_webrtc | 1.7.0 | 1.8.2 | pulled by livekit_client |
| webrtc_interface | 1.4.0 | 1.5.1 | pulled by livekit_client |
| dart_jsonwebtoken | 3.3.1 | 3.4.1 | pulled by livekit_client |
| uuid | 4.5.2 | 4.6.0 | pulled by livekit_client |
| asn1lib | (none) | 1.6.5 | new transitive of dart_jsonwebtoken 3.4.1 |
| adaptive_number, ed25519_edwards, js | 1.0.0, 0.3.1, 0.7.2 | removed | dropped by dart_jsonwebtoken 3.4.1 |
| characters | 1.4.0 | 1.4.1 | pinned by the Flutter 3.47 SDK |
| matcher | 0.12.17 | 0.12.20 | pinned by the Flutter 3.47 SDK |
| material_color_utilities | 0.11.1 | 0.13.0 | pinned by the Flutter 3.47 SDK |
| meta | 1.17.0 | 1.19.0 | pinned by the Flutter 3.47 SDK |
| test_api | 0.7.7 | 0.7.12 | pinned by the Flutter 3.47 SDK |
| vector_math | 2.2.0 | 2.4.3 | pinned by the Flutter 3.47 SDK |
| flutter_lints | 3.0.2 | 6.0.0 | graft from (b) |
| lints | 3.0.0 | 6.1.0 | pulled by flutter_lints |
| lock `sdks.dart` | `>=3.10.3 <4.0.0` | `>=3.11.0-0 <4.0.0` | |

Everything else in the lock is unchanged (71 packages have newer, incompatible majors; not taken).

### iOS (all written by the Flutter tool during `flutter build ios`, none by hand)

- Deployment target 13.0 -> 15.0: `IPHONEOS_DEPLOYMENT_TARGET` in all three configs of `project.pbxproj`,
  the commented `platform :ios` line in `Podfile`, and `MinimumOSVersion` removed from `Flutter/AppFrameworkInfo.plist`.
- Swift Package Manager integration added to `project.pbxproj` (`FlutterGeneratedPluginSwiftPackage` local
  package reference and product dependency), a "Run Prepare Flutter Framework Script" pre-action in
  `Runner.xcscheme`, and `swiftpm/` folders under the workspace and project `xcshareddata`.
- UIScene lifecycle migration: `Info.plist` gains `UIApplicationSceneManifest` (keys reordered; the camera,
  location and microphone usage strings are kept), and `AppDelegate.swift` registers plugins in
  `didInitializeImplicitFlutterEngine` through `FlutterImplicitEngineDelegate`.
- `Podfile.lock`: every plugin that supports SwiftPM left CocoaPods. Pods left: Flutter, flutter_compass,
  flutter_tts. WebRTC-SDK 137.7151.04 now comes through SwiftPM. CocoaPods 1.16.2 -> 1.17.0.

### Python (uv)

| Item | Old | New |
|---|---|---|
| `requires-python` | `>=3.10, <3.13` | unchanged |
| `opencv-python` constraint | `>=4.8.0` | `>=4.8.0,<5` (locked version unchanged) |
| Other runtime dependencies | | unchanged, uv.lock pins untouched (livekit-agents 1.3.12, livekit 1.0.23, livekit-plugins-google 1.3.12, google-genai 1.62.0, backboard-sdk 1.4.12, opencv-python 4.13.0.92, ultralytics, onnx 1.20.1, torch 2.10.0, numpy 2.2.6 / 2.4.2) |
| Dev group | none | `pytest>=9.1.1` (adds pytest 9.1.1, pluggy 1.6.0, iniconfig 2.3.0, tomli 2.4.1 for 3.10) |
| `[tool.pytest.ini_options]` | none | `testpaths = ["tests"]`, `pythonpath = ["."]` |

`uv sync --locked` worked against the original lock, so no runtime package needed a bump.

### Other files changed

- `analysis_options.yaml`: `flutter pub get` itself added an `analyzer.exclude` block for `build/**` and the platform folders.
- `.gitignore`: added `.venv/` and `.pytest_cache/`, which `uv sync` and pytest now create in the repo.
- `lib/main.dart`: deprecation fixes and the cancellable splash timer (grafted from (b), listed above).
- `test/widget_test.dart`: also expects the "Launching..." splash, then unmounts so the timer is cancelled.
- `tests/test_navigation.py`, `tests/test_obstacle.py`, `tests/test_imports.py`: new pytest suite.

## What broke and how it was fixed

1. **livekit_client 2.6.2 does not compile on Dart 3.13.** `lib/src/participant/local.dart` reads
   `publishOptions.videoCodec` after an `await`, and Dart 3.13 no longer promotes `publishOptions` to
   non-null there ("could not be promoted due to an 'await' or 'yield'"). The failure broke `flutter test`
   and would break any build. `flutter pub upgrade livekit_client` only reached 2.6.4, which still fails. I
   tried pinned versions: 2.6.5, 2.7.0, 2.8.1 and 2.9.0 fail with the same error, and 2.10.0 is the first that
   compiles. The constraint is now `^2.10.0`, and pub resolved 2.11.0. No app code changes were needed for the
   livekit API.
2. **Widget test failed with "A Timer is still pending even after the widget tree was disposed."** The
   splash screen started a 3 s `Future.delayed` in `initState`, and the newer flutter_test fails a test that
   ends with a pending timer. The splash now keeps a `Timer` and cancels it in `dispose()`. The test unmounts
   the app at the end.
3. **35 analyzer infos** (deprecations listed above) made `flutter analyze` exit 1. They are fixed in `lib/main.dart`.
4. **iOS build:** nothing broke. The Flutter tool raised the deployment target and migrated the project on its own.
5. **Python:** nothing broke. pytest was missing, and the repo root was not on `sys.path` for tests in
   `tests/`. `testpaths` also keeps pytest away from `test_obstacle_local.py` at the root, which is a manual
   camera script.

## Deferred

- **flutter_compass and flutter_tts have no SwiftPM support**, so they stay on CocoaPods. Flutter warns
  that this will become an error. Fix it by replacing or upgrading those plugins when that happens.
- **Two navigation bugs in `navigation.py`, both pre-existing and left unfixed.** Fixing them changes app
  behaviour, which is Ben's call. Each has a strict xfail test that will start failing once it is fixed:
  1. On multi-step routes, "You have arrived" is never spoken. After the final "Now" instruction,
     `last_instruction_spoken_index` already equals the last step. Test: `test_arrival_announced_after_final_turn`.
  2. On single-step routes, "You have arrived" is spoken on the first update after the grace period, even
     ~111 m from the destination. The `if next_step_index >= len(steps):` branch (navigation.py:171) never
     checks `dist`. Test: `test_single_step_no_arrival_when_far_away`.
- **objc duplicate class warning at import** (`AVFFrameReceiver` in both PyAV and opencv-python's bundled
  libavdevice). This is pre-existing and harmless for the imports and tests.
- **Pydantic V2 deprecation warning** from backboard-sdk's `models.py`. This is upstream code.
- **The full upgrade from candidate (b).** It builds and passes all tests, but it needs a device and a live
  agent session to trust. The recipe, in case Ben wants it:
  - Flutter: geolocator ^14.1.1, record ^7.1.1, camera ^0.12.1, livekit_client ^2.13.0, and SDK `^3.12.0` plus
    `flutter: ">=3.44.0"` (camera 0.12 and record 7 require them). Minor bumps: http, dart_jsonwebtoken,
    path_provider, shared_preferences, image. No app code changes are needed beyond what is already grafted.
  - Python: `requires-python >=3.12` (numpy 2.5 needs it), drop the `livekit-plugins-google<1.4` pin, and take
    livekit-agents 1.8.3, google-genai 2.25, backboard-sdk 1.5.19, pillow 12.3, ultralytics 8.4.165, onnx 1.23,
    protobuf 7, transformers 5, torch 2.14.
  - `agent.py` for livekit-agents 1.8: `turn_detection=`/`allow_interruptions=` -> `turn_handling=TurnHandlingOptions(turn_detection="vad")`,
    `elevenlabs.STT(model_id=)` -> `model=`, and tools go to `Agent(tools=[...])` instead of the private `agent._tools`.
    The old forms still work in 1.8 through deprecation shims, so none of this is forced.
  - `backboard_store.py` for backboard-sdk 1.5: `llm_provider=None` -> `send_to_llm="false"`. Do **not** apply it
    on the current 1.4.12 lock, where `add_message` has no `send_to_llm` parameter. The `try/except` would
    swallow the TypeError, and memory saving would stop with only a log line.
  - The complete full-upgrade candidate, with its own UPGRADE.md, is kept outside this repo.
- **Android** was not built. It was not in the goal list, and macserver has no Java runtime; installing one
  would be system-wide.
- **Android** was not built. It was not in the goal list.

## Tests

`tests/` (pytest; `testpaths` keeps the manual camera script `test_obstacle_local.py` out):
- `test_obstacle.py`: base64 frame decoding (valid, garbage, too short), YOLOv8 output decoding against a fake `cv2.dnn.Net`, confidence/class/region filtering
  including the exact 0.2 centre-region boundary and non-square frame scaling, HOG left/right-edge filtering
  with a fake detector, a real `cv2.HOGDescriptor` run on a blank frame (guards the opencv<5 cap), the
  processor's "new obstacle" flag across clears, and the frame queue keeping only the newest two frames.
- `test_navigation.py`: haversine and bearing maths including normalisation to 0-360, bearing-to-cardinal names,
  relative direction at the 45/46 and 314/315 degree edges, Google HTML stripping, heading-relative instruction
  rewriting including the "toward" separator, and the `update_location` state machine: the grace period, silence
  far from a turn, step progression, the "Now" rewrite with a heading, stop/reset, empty routes, single-step
  arrival said once, and the two xfails above.
- `test_imports.py`: clears the API-key env vars, then imports all six agent modules.

No network calls and no real keys. Obstacle tests use synthetic frames.

## Command results (final run, in the repo after grafting)

1. `flutter pub get`: pass.
2. `flutter analyze`: "No issues found!", exit 0.
3. `flutter test`: pass, 1/1 ("App builds").
4. `flutter build ios --simulator --no-codesign`: pass, "Built build/ios/iphonesimulator/Runner.app" (Xcode
   build 61 s). No dart defines were passed; `lib/config.dart` falls back to empty defaults. Flutter warns
   that flutter_compass and flutter_tts lack SwiftPM support.
5. `~/.local/bin/uv run pytest`: 78 passed, 2 xfailed, on the uv-managed CPython 3.11.16. `uv run python -c
   "import agent, navigation, obstacle, google_maps, agent_config, backboard_store"` also succeeds. Candidate
   (a) also confirmed the suite on Homebrew Python 3.12.14.

## Rationale

- **Bump livekit_client to the latest (2.13) or run `pub upgrade --unlock-transitive`**: rejected. That moves
  43 lock entries (connectivity_plus 7.3, device_info_plus 13, win32 6, jni, and more) for no build benefit.
  `^2.10.0` moves 10.
- **Patch livekit_client locally with `dependency_overrides` or a vendored fork**: rejected. It adds more
  maintenance than a version bump.
- **Leave the 35 analyzer infos** (candidate (a)'s choice): overridden in the graft. `flutter analyze` must
  pass, and the fixes are mechanical SDK-level renames that work on the current plugin versions.
- **Opt out of Swift Package Manager** (`flutter config --no-enable-swift-package-manager`, or the pubspec
  `config` flag) to avoid the pbxproj churn: rejected. The global flag changes machine config, the pubspec flag
  is an extra change, and SwiftPM is the default Flutter is moving toward.
- **Drain the splash timer in the test only** (candidate (a)'s choice): replaced by (b)'s cancellable timer,
  which removes the cause instead of working around it in the test.
- **Bump Python deps or raise `requires-python` to allow 3.13**: rejected. The original lock installs and
  imports cleanly, so neither was needed.
- **Add `.python-version` to force Homebrew 3.12**: rejected. The default interpreter works, and 3.12 was
  checked by hand.
