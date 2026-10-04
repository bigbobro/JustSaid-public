<div align="center">

<img src="https://github.com/user-attachments/assets/b8b5f33c-ca2e-4f9e-9200-c3114b83d1db" width="96" height="96" alt="JustSaid icon">

# JustSaid

**What was just said, right here.**

An open-source meeting notes app for macOS. It transcribes on your Mac as people talk, turns the discussion into tables, timelines and key points while the meeting is still going, and writes the minutes afterwards with your own model.

[Download](https://github.com/bigbobro/JustSaid-public/releases/latest) · [Changelog](https://github.com/bigbobro/JustSaid-public/blob/main/CHANGELOG.md) · [Report an issue](https://github.com/bigbobro/JustSaid-public/issues) · [简体中文](https://github.com/bigbobro/JustSaid-public/blob/main/README.md)

[![Release](https://img.shields.io/github/v/release/bigbobro/JustSaid-public)](https://github.com/bigbobro/JustSaid-public/releases/latest)
![Platform](https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20Silicon-lightgrey)
[![License](https://img.shields.io/badge/license-MIT-blue)](https://github.com/bigbobro/JustSaid-public/blob/main/LICENSE)

</div>

<div align="center">

https://github.com/user-attachments/assets/356ccce0-4baf-4b5b-b275-606df49b80fd

</div>

> **Language note.** The app's interface is in Simplified Chinese. Meetings can be in Chinese or English: live transcription has Auto, Chinese and English modes.

## What it does

- **Live transcription on your Mac.** Your microphone and the system audio are transcribed side by side with Qwen3-ASR running locally. Live transcription never uploads audio.
- **Notes that organise themselves.** The discussion builds into a living document grouped by topic. When the content fits, a topic gets a table, a timeline, key numbers or a hierarchy.
- **Covered when someone calls your name.** If someone says your name, a floating window alerts you and shows what the conversation is about.
- **Promises don't get lost.** Commitments and to-dos mentioned in the meeting are captured with owner and deadline, then land in My To-dos, where you can sort them on an Eisenhower matrix.
- **Reminds you when a call starts.** When a meeting app starts a call, a prompt appears at the top of the screen; one click starts recording. Recordings started this way capture only that meeting app's audio by default.
- **Minutes on one page.** After the meeting, the full recording goes to your own speech-recognition service for a high-quality pass, then your model writes the minutes and action items. Bring your own API key, or use your ChatGPT subscription.

<table>
  <tr>
    <td width="50%"><img src="https://github.com/user-attachments/assets/d57cbb16-f876-46bc-9fac-be88fc745f57" alt="Live organising: a table and a timeline appear before the meeting ends"><br><sub>The table is ready before the meeting ends</sub></td>
    <td width="50%"><img src="https://github.com/user-attachments/assets/bd9b1e70-db98-4448-bff5-a5cd729cdd58" alt="Name-call alert: a floating window says someone called you and shows the current topic"><br><sub>Called on while distracted? The floating window catches you up</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="https://github.com/user-attachments/assets/60573a32-3b91-4a55-8390-4879e33f73b1" alt="Different meetings organised as tables, timelines, numbers and hierarchies"><br><sub>Each meeting takes the shape of its discussion</sub></td>
    <td width="50%"><img src="https://github.com/user-attachments/assets/cc1e3034-e482-4b18-a1da-ebf3cece8715" alt="My To-dos: commitments from meetings sorted on a four-quadrant matrix"><br><sub>Commitments sorted by urgency and importance</sub></td>
  </tr>
</table>

## Install

Requires an Apple Silicon Mac running macOS 15 or later.

1. Download the latest `JustSaid-<version>-b<build>-arm64.dmg` from [Releases](https://github.com/bigbobro/JustSaid-public/releases/latest).
2. Open the DMG and drag `JustSaid.app` into Applications.
3. JustSaid is self-signed and not notarized by Apple, so macOS blocks the first launch. Double-click JustSaid in Applications once and click Done in the warning, then go to System Settings → Privacy & Security and click Open Anyway under Security. You don't need to turn off Gatekeeper or run any commands.
4. On your first recording, allow microphone access and Screen & System Audio Recording when macOS asks. On first launch the app offers to download the local speech models (Qwen3-ASR and Silero VAD); it only goes online after you confirm.

<details>
<summary>Verify the download (optional)</summary>

In Terminal, in the folder with the DMG:

```sh
shasum -a 256 JustSaid-*.dmg
```

The output should match the `.dmg.sha256` file on the same Release page. `VERSION.txt` at the root of the DMG names the source commit the build came from; `source_sha` in `PUBLIC_EXPORT_MANIFEST.json` under the matching version tag in this repository should be the same. If all three match, the build came from the source published here.

</details>

## Setup

No cloud accounts or keys are bundled. Live transcription runs on local models and works right after install. Post-meeting transcription, live summaries and minutes use your own services, configured per role in Settings (`⌘,`) → 模型与服务 (Models & Services):

| Role | What you need |
| --- | --- |
| Live transcription | Nothing; local Qwen3-ASR by default |
| Post-meeting transcription | Credentials for Volcengine Doubao recording-file recognition, plus your own Cloudflare R2 bucket for temporary audio transfer |
| Fast and slow live summaries | An OpenAI-compatible chat model service (base URL, model name, API key), or sign in with your ChatGPT subscription |
| Minutes | Same as above; all three can share one channel or each use their own channel, model and reasoning level |

**Using your ChatGPT subscription:** in 模型与服务, click 新建渠道 (New Channel), choose ChatGPT 计划用量 (ChatGPT plan usage) as the provider, then click Continue with ChatGPT to sign in in your browser and pick a model for each role. Summaries and minutes count against your ChatGPT plan; post-meeting transcription still uses the recognition service above.

Step-by-step guides (in Chinese) for Doubao recording-file recognition and Cloudflare R2 ship in the `docs/` folder at the root of the DMG. Keys are stored only in your Mac's keychain; give each credential the minimum permissions the app needs.

## Where your data goes

| Step | Where | Notes |
| --- | --- | --- |
| Recording and live transcription | Your Mac | Qwen3-ASR runs locally; live audio is never uploaded |
| Echo cancellation | Your Mac | Applied live and again after the meeting; the original recording is kept |
| Meeting files | Your Mac, `~/JustSaid/meetings` | Audio, transcripts, minutes and notes, one folder per meeting; back up or delete freely |
| Live summaries and minutes | Your model service or ChatGPT | Transcript text is sent |
| Post-meeting transcription | Your R2 bucket and recognition service | The recording is uploaded temporarily; the transfer copy is deleted when recognition finishes, and a failed deletion is reported |
| API keys and ChatGPT sign-in | Your Mac's keychain | Stored separately |
| Update checks | This repository's public update feed | No meeting content or system information is sent |

Recordings started from a meeting prompt capture only that meeting app's system audio by default (for a meeting in a browser, the whole browser). If per-app capture fails, the app falls back to all system audio and tells you. Recordings you start manually capture all system audio. Each service's data retention follows its own terms and your account settings.

<details>
<summary>More features</summary>

- **Name-call alerts.** Add your name or nicknames in Settings → 点名提醒 (Name alerts); alerts work only while recording. They reuse live transcription, so they lag a few seconds and can miss a name. The floating display can dock to an edge, float as a small window, or stay off; the strong alert shows the name with a 知道了 (Got it) button even when the floating display is off. The 点名 button in the left sidebar pauses or resumes alerts.
- **Notes and highlights.** Add your own notes next to the transcript, or mark the current moment with a shortcut.
- **Off-the-record.** During a recording, click 闲聊 (Small talk) in the toolbar or press `⌥⌘X` to start, and again to stop. That stretch is still recorded and transcribed but left out of the minutes. You can also exclude passages later in the full transcript.
- **Speaker naming.** After post-meeting transcription, the app suggests who is who from the conversation (introductions, people being addressed by name), with the quote as evidence. Names change only when you accept.
- **Three meeting tabs.** 这场会 (This meeting) switches between the structure view and the formal minutes; 完整转写 (Full transcript) is for checking speakers; 会中记录 (Live record) keeps the live notes history next to your own notes.
- **Meeting library.** Chronological, with full-text search, client and project grouping, and meeting package export.
- **Import recordings.** Drop existing audio or video files (mp3, m4a, wav and more) on the home screen's import box to go straight to post-meeting transcription and minutes.
- **My To-dos.** Add items by hand or confirm candidates from a meeting; filter by smart views (today, overdue, incomplete) or by client and project, and switch between a list and the four-quadrant matrix.
- **Glossary.** Keep names and their variants for better transcription and minutes. New terms found while writing minutes wait in a review box until you merge, add or ignore them.

</details>

## Updates

Choose 检查更新… (Check for Updates…) in the JustSaid menu, or turn on automatic checks in Settings → 通用 (General) → 应用更新 (App updates). You decide when to install: install and relaunch now, or install the next time you quit the app (closing the main window keeps it running in the background). While recording, post-meeting processing, importing or model setup is in progress, the updater asks you to try again afterwards. Version 1.0.3 and earlier need one manual install of an updater-enabled version from Releases.

## Known limitations

- **The keychain asks again after each update.** After updating, macOS may ask for your login keychain password before JustSaid can read your saved API keys or ChatGPT sign-in. Allow it; choosing Always Allow does not carry over to the next update. If you clicked Deny by mistake, save the key again or restart JustSaid and allow access; your saved keys are kept.
- **Not notarized by Apple.** The first launch needs the Privacy & Security step above.
- **Apple Silicon and macOS 15 or later only.**
- **Interface in Chinese only.** See the language note above.
- **Name-call alerts lag.** They depend on live transcription, usually a few seconds behind, and can miss a name.

## Build from source

This repository uses Swift Package Manager. On an Apple Silicon Mac with macOS 15 or later and the Xcode command line tools:

```sh
swift package resolve
swift build --build-system native --product JustSaid
```

This produces an unpackaged executable; the DMG on Releases is the packaged, signed build.

<details>
<summary>Dependencies and repository scope</summary>

Pinned versions of sherpa-onnx, Sparkle and WebRTC Audio Processing. SwiftPM downloads a roughly 1.25 MB arm64 static XCFramework from the separate `deps-webrtc-apm-2.1` Release and checks its pinned SHA-256; to install the app, still download the app's DMG.

This repository holds product source selected and exported from the development repository: the app and its two libraries. Verification fixtures, internal research notes and real meeting material are not included. Every export writes `PUBLIC_EXPORT_MANIFEST.json`, recording the source commit and file list; the export boundary is described in `docs/publication/PUBLIC_SCOPE.md`. Please don't submit recordings, credentials, signing material or any meeting data to this repository.

</details>

## Feedback

Report problems and suggestions in [Issues](https://github.com/bigbobro/JustSaid-public/issues), with the version and build number shown at the bottom of Settings. Don't include API keys, access keys or full recordings.

## Acknowledgements

Thanks to the [Linux.do](https://linux.do) community for the discussions, feedback and support.

Thanks also to the open-source projects JustSaid builds on, including Qwen3-ASR, sherpa-onnx, Silero VAD, Sparkle and WebRTC Audio Processing.

## License

Source code is released under the MIT license; see [LICENSE](https://github.com/bigbobro/JustSaid-public/blob/main/LICENSE). Licenses for third-party components and local models are in `Support/ThirdPartyNotices.txt` and `Support/ThirdPartyLicenses/`.
