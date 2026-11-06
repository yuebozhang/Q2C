# Quick to Codex (Q2C)

**English** | [简体中文](README.zh-CN.md)

**Select content. Take a shortcut to Codex.**

Q2C is a lightweight macOS menu bar app. Select text, images, or other copyable content in the source app, press a keyboard shortcut, and choose a Codex conversation. Q2C pastes the content as is; you review and send it manually.

**One shortcut handles copying, switching apps, and pasting.**

- **Lightweight**: The download package is under 2 MB, with the app ready in your menu bar.
- **Clean interface**: Simple and ad-free.
- **Runs locally**: Q2C only observes clipboard version changes. It does not read, save, filter, or rewrite clipboard content.
- **Customizable shortcuts**: Choose the keyboard shortcut that works for you.
- **Flexible targets**: English and Chinese interfaces, up to 8 target profiles, optional labels, and a starred default target.

## Screenshots

Menu bar settings popover:

<img src="docs/images/settings-popover.png" alt="Q2C menu bar settings popover with conversation links redacted" width="600">

Settings panel:

<img src="docs/images/settings.png" alt="Q2C settings with labels, example conversation links, default stars, and delete buttons" width="600">

Target picker:

<img src="docs/images/picker.png" alt="Q2C target picker: cycle with the shortcut key and release modifiers to confirm" width="300">

Screenshots show the Chinese interface; the app also supports English.

## Download and Install

Download the preview package from [GitHub Releases](https://github.com/yuebozhang/Q2C/releases), unzip it, drag `Q2C.app` into Applications, and open it. The app appears in the menu bar without a Dock icon.

The current download supports **Apple Silicon and macOS 14 or later**. The Codex desktop app must be installed and signed in. Building from source requires Swift 6 and Xcode or Command Line Tools. There are no third-party Swift package dependencies.

The preview uses a development self-signed certificate and **has not been notarized by Apple**. On first launch, you may need to allow it in System Settings → Privacy & Security. If your organization does not permit this, build from source; you do not need to disable system security protections.

Grant Q2C Accessibility permission in System Settings → Privacy & Security → Accessibility so it can issue copy and paste events. The app does not change permissions for you.

## Quick Start

1. Open the target conversation in Codex. In its menu, choose Copy → Copy deep link. Q2C accepts links in the format `codex://threads/<conversation-UUID>`.

   <img src="docs/images/copy-deep-link.png" alt="Codex conversation menu showing Copy and Copy deep link, with unrelated information obscured" width="600">

2. Click the Q2C menu bar icon and enter the target link. The optional label on the left helps identify the profile and is not included in the pasted content.
3. Click `+` at the top right to add a profile, up to 8. Fill in any empty link before adding another profile. Click a row’s `×` to delete it after confirmation.
4. Click the star to set the default target; click it again to clear it. The starred target appears first in the picker, followed by the other profiles in settings order.
5. Select content in the source app and press the default shortcut, ⌥⌘C. Keep the modifiers held to choose a target, then release them to confirm. If you have already released the shortcut when copying finishes, Q2C uses the first valid target. Review the pasted content in Codex and send it manually.

Use EN/CN at the top to switch languages. Click the shortcut text to record a new combination, or the power icon to quit. Settings fields support ⌘A/C/X/V; ⌘W closes settings and ⌘Q quits the app.

Conversation link example (placeholder only):

```text
codex://threads/.....
```

## Privacy and Local Data

- The current transfer flow does not read clipboard content, types, or file paths. It does not save transfer history or read Codex conversations, messages, or drafts.
- The current flow makes no network requests and has no telemetry, analytics, or cloud configuration sync. The source app performs the copy, and Codex receives a native system paste. Data handling after you send in Codex follows Codex’s own rules.
- Copied content may remain on the system clipboard. Quitting Q2C does not clear it.
- Configuration is stored at `~/Library/Application Support/Q2C/config.local.json`, including target links, labels, the shortcut, and the starred target. Legacy header/footer fields are retained only for compatibility and are not used.
- Logs are stored at `~/Library/Logs/Q2C/`. They contain only workflow stages, timings, PIDs, version numbers, and failure reasons—not payloads, file names, file paths, or target links. Logs rotate at 1 MiB, keeping the current and previous files.
- Configuration and log directories use `0700` permissions; files use `0600`. Local configuration, logs, and build artifacts are excluded from Git.

## Build from Source

```sh
git clone https://github.com/yuebozhang/Q2C.git
cd Q2C
swift test
zsh scripts/build-app.sh
```

The output is `dist/Q2C.app`. The script prefers the local `Q2C Local Dev` signing identity and falls back to ad-hoc signing. Set `Q2C_CODESIGN_IDENTITY` to use another existing identity. Building does not install or launch the app, change permissions, or register global shortcuts.

## Project Documentation

- [Usage flow (Chinese)](docs/usage-flow.md)
- [Implementation notes (Chinese)](docs/implementation.md)

Q2C is independently developed and is not an official OpenAI app.

## License

Source code and original project icons are licensed under [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
