# Video Script — Environment Setup (Windows)

**Audience:** newcomers to coding who want to get started with OwnTech.
**Goal:** get from "empty computer" to "blinking LED on the SPIN board" in one watch.
**Format:** screencast (Windows), presenter face/voice on the side, talking over their own install process.
**Target length:** ~3 minutes.
**Source doc:** `docs/environment_setup.md`

> Draft only — timings are rough, adjust once you record a first pass. Lines in *italics* are delivery notes, not spoken text.

---

## 0:00 – 0:20 | Intro

*On camera, energetic, short.*

> "Hey! In this video I'll walk you through setting up your computer to start coding with OwnTech — from zero to a blinking LED on your board, in about 3 minutes. All you need is a Windows PC and an internet connection. Let's go."

*Cut to desktop.*

---

## 0:20 – 0:45 | Prerequisites (fast montage)

*Screen: browser tabs opening quickly for Git, Python3, CMake downloads. Speed up / jump cuts, don't wait for installers.*

> "First, three quick installs if you don't already have them: Git, Python 3, and CMake. Links are in the description and in the docs — just run through the default installer options for each."

*On-screen text overlay: "Git · Python3 · CMake — links in description"*

> "One Windows tip: keep your project folder path short, with no spaces, not inside OneDrive, and close to your drive's root — that avoids a bunch of annoying errors later."

*On-screen text overlay: "❌ No OneDrive  ❌ No spaces  ✅ Short path near C:\ "*

---

## 0:45 – 1:10 | Create project folder + install VS Code

*Screen: create an empty folder, e.g. `C:\owntech`.*

> "Create an empty folder where you'll work — I'm using `C:\owntech`. Then download and install Visual Studio Code."

*Screen: VS Code download page, highlight the "System Installer" option.*

> "On Windows, make sure you grab the System Installer version, not the user one — it's this option right here."

*Install VS Code, sped up.*

---

## 1:10 – 1:45 | Install the PlatformIO extension

*Screen: open VS Code, click Extensions icon in the Activity Bar.*

> "Now open VS Code, go to Extensions, and search for 'PlatformIO IDE'."

*Search, click Install.*

> "Install it, and when it asks, restart VS Code."

*Screen: after restart, point at the alien head icon in the Activity Bar.*

> "Once it's back, you'll see this little alien head appear on the left — that's PlatformIO. Click it to open it."

*Pro-tip overlay (optional, quick): "Icon missing? Press F1 → type 'platformio home'"*

---

## 1:45 – 2:15 | Clone the Core repository

*Screen: PlatformIO home, Quick Access → "Clone Git Project".*

> "In PlatformIO's Quick Access panel, choose 'Clone Git Project', and paste this repository URL."

*On-screen text overlay + paste:*
```
https://github.com/owntech-foundation/Core
```

> "Pick the folder you created earlier, let it clone, and when VS Code asks to open it — say yes. Trust the authors, that's us!"

*Screen: quick glance at the bottom status bar showing branch name.*

> "Quick check: make sure you're on the `main` branch — you can see that right here in the status bar."

---

## 2:15 – 2:45 | Build and upload

*Screen: point to the checkmark (✓) build icon at the bottom status bar.*

> "Now click the checkmark icon to build the project. First build takes a few minutes — PlatformIO is downloading everything it needs, so this is a great excuse for a coffee."

*Speed up build process, show completion message.*

> "Once it's done, plug in your SPIN board with a USB-C cable — you should see its power LED light up."

*Screen: show board connected, then click the arrow (→) upload icon.*

> "Then hit the arrow icon right next to Build to upload the code to the board."

*Show upload success message, then cut to board with blinking LED.*

> "And... there it is — your first blinking LED, running code you just built yourself."

---

## 2:45 – 3:00 | Outro

*On camera.*

> "That's the whole setup — Git, Python, CMake, VS Code, PlatformIO, and your first upload. If you hit any errors along the way, check the troubleshooting section in the docs, link's below. Now go build something!"

*End screen: link to `docs/environment_setup.md` and next tutorial.*

---

## Notes for recording

- Pre-download/pre-cache installers where possible so on-screen waits can be cut hard in editing — don't rely on real-time speed-ups alone.
- Have a project folder path ready in advance (e.g. `C:\owntech`) so you're not typing it live.
- Consider muting/hiding notifications before recording (Windows Focus Assist).
- If the first PlatformIO build/upload genuinely takes several minutes, record it once in the background and just cut to the "done" state — don't force viewers to sit through the wait.
- Keep on-screen text overlays short — they're there to reinforce spoken words, not replace them.
