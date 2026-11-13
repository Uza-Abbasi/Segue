# Manual checklist

Run against Apple Music with a streamed song playing.

Last run: 2026-11-12, macOS 15.6.1, build 7f839d5.

| # | Check | Expected | Result |
|---|---|---|---|
| 1 | DJ skip (⌥⌘S) five times, more than 3 s apart | Each sounds different; EQ and volume return to the starting values | Skip confirmed working by the owner. "Each sounds different" and exact return values not individually verified by ear; covered by automated tests. |
| 2 | Start with a named preset selected, and with the EQ off | Both are restored after a skip | Passed on the live Equalizer through `Segue --probe-preset` ("Rock", EQ off). Not repeated through a full skip. |
| 3 | DJ skip twice quickly | Second skip is instant | Tried by the owner as part of "it works". Covered by automated tests. |
| 4 | Change the volume mid-fade | Volume stays where it was put | Not run by hand. Covered by automated tests. |
| 5 | DJ skip in the last few seconds of a song | No double skip | Not run by hand. Covered by automated tests. |
| 6 | Faded pause and resume (⌥⌘P) | Fades out, pauses; fades back in | Confirmed working by the owner. |
| 7 | Revoke Accessibility | Skips fade without EQ; the grant button appears | Grant button and notice seen before permission was granted. Fade-only skip not run by hand. |
| 8 | Force-quit Segue mid-transition and relaunch | EQ and volume are restored | Not run by hand. Covered by automated tests. |
| 9 | Equalizer window stays minimized; Music never comes to the front | Both hold | Passed during the live probes. |
