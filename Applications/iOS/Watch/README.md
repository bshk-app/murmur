# Murmator on Apple Watch

A companion app (`app.bshk.murmur.ios.watchkitapp`) that records a voice note on the
wrist and hands the file to the iPhone. It never recognises anything itself: the
recognisers need models far larger than the watch holds, so the watch target links
AVFoundation and WatchConnectivity only, and none of the `Engine` packages.

## The path a recording takes

1. `WatchRecorder` records into the watch's temporary folder as AAC, 16 kHz mono,
   32 kbps. That is the format the phone resamples to anyway, and a minute of it
   crosses the Bluetooth link in seconds. The file is named
   `Apple Watch <date> <time>.m4a`, which becomes the note's title on the phone.
2. Stopping moves the finished file into `Documents/Outbox` and calls `transferFile`.
   Recording happens outside the outbox on purpose: only a file that reached the
   outbox is complete, so a resend can never pick up a half-written one.
3. `WatchSessionBridge` on the phone receives it. The system deletes the delivered
   file the moment the delegate returns, so the move into `Application Support/
   MurMur/WatchInbox` happens synchronously, before anything else.
4. `AppModel.receiveWatchRecordings()` drains that folder through the existing audio
   import: `AudioImportJob.receive` copies the audio into the note library and only
   then deletes the staged file. A crash in between leaves the file for the next
   sweep rather than losing the recording.
5. `WatchImportPolicy` (in `MurmurCore`, unit-tested) decides which recording starts.
   The first one starts, the rest join its queue.

The watch deletes its outbox copy only when the system confirms the transfer. Files
left there after a failed transfer or a kill are queued again on the next launch and
whenever the phone comes back in range.

## Starting without opening the app

Finding the app before speaking costs more than reaching for the phone, so there
are two ways past it, both ending in the same request flag:

- **A complication** on the watch face. Tapping it opens the app at
  `murmur://record`, and `RecordView` starts recording on arrival. It opens the
  app rather than running an embedded button, because a quick tap on a small
  complication is exactly the case where watchOS launches the app instead of the
  button, and a quick tap is what this exists for.
- **The Action Button and Shortcuts**, through `StartWatchRecordingIntent`. Bind
  it in the Shortcuts app on the phone.

A request raised while a recording is already running is consumed and ignored, so
it cannot fire days later.

## The answer coming back

When the phone finishes transcribing a watch recording it sends the text back
with `transferUserInfo`, queued rather than pushed as state so a later recording
cannot erase an answer still in flight. The watch stores it on disk before showing
it: delivery can happen while the app is not running, and watchOS may end that
process before anyone looks.

The wrist tap on arrival only plays while the app is in front. That is a bonus,
not the delivery: the transcript is kept either way, and the phone's own
notification covers the case where the watch app is closed.

## What the phone shows

A recording that arrives while the app is not in front raises one local notification;
a burst of them replaces a single banner rather than stacking. Transcription starts by
itself when the app next becomes active. The import card carries a "From Apple Watch"
tag, and a recording that cannot start yet stays on the Notes banner.

## Decisions worth knowing

- **Starting unloads the warm models.** Auto-start goes through the same
  `AppModel.startAudioImport` a tap does, which releases memory first. Returning to
  the app with a watch recording waiting costs the next dictation a model load.
- **Dictation wins.** While the keyboard session is active, or while the phone has no
  memory to release, the recording waits and shows its banner instead of interrupting.
- **A deliberate pause stays paused.** Leaving the app pauses an import the same way a
  tap does, so the job records which of the two happened (`autoStart`) and only the
  system's pause resumes on its own.
- **The language comes from the phone.** The watch displays it and warns when the
  phone has no models for it, but never chooses it.
- **No App Group, no entitlements.** WatchConnectivity needs neither.

## Building

The watch app builds as a dependency of `MurMurMobile`, so
`bash Applications/iOS/build.sh CODE_SIGNING_ALLOWED=NO` covers it.

A machine whose watchOS simulator runtime is older than its watchOS SDK cannot compile
the watch asset catalogue at all: `actool` fails with "No simulator runtime version
from [...] available to use with watchsimulator SDK version [...]". Install the
matching platform first:

```bash
xcodebuild -downloadPlatform watchOS
```

Installing on a device needs Xcode with the development account for team `Q8H6GWJ658`
and `-allowProvisioningUpdates`, which creates the App ID for the new bundle
identifier. Maestro cannot drive a watchOS simulator, so there is no flow coverage.

## Not verified

Nothing below can be checked without an iPhone and a paired watch, and none of it is
claimed to work:

- WatchConnectivity delivery latency, and the background launch of the phone app,
  including after the user force-quits it
- delivery and notification while the phone is locked
- recording continuing with the wrist down under `UIBackgroundModes: [audio]`
- a call or Siri finalising the partial recording
- transfers surviving a watch reboot
- recognition quality of 16 kHz AAC through the accurate recogniser
- battery cost
