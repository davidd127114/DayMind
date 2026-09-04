# Setting up DayMind — step by step for beginners

You need a Mac. Xcode (Apple's app-building program) only runs on macOS. If you do not own a Mac,
borrow one for an hour — everything below takes about 30 minutes the first time.

## Part 1 — Install Xcode (once)

1. On the Mac, open the **App Store**.
2. Search for **Xcode** and click **Get**, then **Install**. It is free and large (about 15 GB); let it finish.
3. Open Xcode once. If it asks to install "additional components", click **Install**.
4. In Xcode's menu bar choose **Xcode → Settings → Components** and make sure an **iOS 26** simulator is installed (download it if it shows a cloud icon).

Xcode **26 or newer** is required. Check with **Xcode → About Xcode**.

## Part 2 — Get the project onto the Mac

Option A (easiest): open **Terminal** (Applications → Utilities → Terminal) and paste:

```
cd ~/Desktop
git clone https://github.com/davidd127114/DayMind.git
```

Option B: on GitHub open the repository page, click the green **Code** button → **Download ZIP**, then unzip it onto the Desktop.

You now have a folder called `DayMind` on the Desktop.

## Part 3 — Open the project

The repository already contains `DayMind.xcodeproj` (the build server regenerates it from `project.yml` after every successful build).

1. In the `DayMind` folder, double-click **DayMind.xcodeproj**. Xcode opens.
2. Wait for the status bar at the top to stop saying "Resolving packages" / "Indexing".

If `DayMind.xcodeproj` is missing (for example you checked out a very fresh commit), create it:

```
cd ~/Desktop/DayMind
brew install xcodegen      # installs the generator; if "brew" is not found, install Homebrew from https://brew.sh first
xcodegen generate
```

## Part 4 — Run in the iPhone simulator

1. At the top of the Xcode window there is a device selector next to the "DayMind" scheme. Click it and pick **iPhone 17** (or any iPhone simulator running iOS 26).
2. Press the **▶︎ Run** button (or **⌘R**).
3. The first build takes a few minutes. The simulator opens and DayMind launches with sample data (the DayMind scheme sets `DAYMIND_SEED_SAMPLE_DATA=1`).
4. Try it: tap **Talk**, tap the **keyboard** icon, type `Remind me tomorrow at 3 PM to call Michael` and press send.

What works in the simulator: everything except the microphone (use the keyboard button) and Apple Intelligence
(the simulator has the on-device model only if the Mac itself runs macOS 26 with Apple Intelligence enabled;
otherwise DayMind shows "Offline mode — built-in rules" and still works).

## Part 5 — Install on your iPhone

You need: the iPhone, its cable, and to be signed into Xcode with your Apple ID.

1. **Sign in to Xcode**: **Xcode → Settings → Accounts → +** → **Apple ID**, sign in with the Apple ID you use on the iPhone. A free account is enough for installing on your own phone.
2. In the project navigator (left column) click the blue **DayMind** project icon at the very top.
3. Under **TARGETS** select **DayMind**, then the **Signing & Capabilities** tab.
4. Tick **Automatically manage signing** and choose your name under **Team**.
5. Change **Bundle Identifier** to something unique to you, for example `com.yourname.DayMind` (Apple requires bundle identifiers to be unique per developer).
6. **If your Apple ID is a free account (not the paid $99/year program):** Xcode will show a red error about *iCloud* / *Push Notifications*. Fix it by removing those capabilities for now:
   * still in Signing & Capabilities, find the **iCloud** section and click the small **x** (trash) icon to remove it;
   * also remove **Push Notifications** if listed;
   * in the left column open **DayMind → DayMind.entitlements** and confirm only harmless entries remain (or none).
   Everything except iCloud sync keeps working. Paid accounts can leave these in place.
7. Repeat steps 3–5 for the **DayMindControls** target (its bundle identifier must be your app identifier followed by `.Controls`, for example `com.yourname.DayMind.Controls`).
8. Plug in the iPhone. Unlock it. If it asks **Trust This Computer?** tap **Trust**.
9. On the iPhone: **Settings → Privacy & Security → Developer Mode → on** (the phone restarts). This is required for apps installed from Xcode.
10. In Xcode's device selector choose your iPhone (it appears by name at the top of the list).
11. Press **▶︎ Run**. The first time, the iPhone shows "Untrusted Developer". On the iPhone go to **Settings → General → VPN & Device Management**, tap your Apple ID, tap **Trust**. Press Run again.
12. DayMind launches. Grant **Microphone**, **Speech Recognition** and **Notifications** when asked (each prompt explains why).

With a free Apple ID the installed app expires after **7 days**; just press Run again to refresh it.
Paid accounts get one year.

## Part 6 — Turn on Apple Intelligence (for voice understanding)

1. iPhone **Settings → Apple Intelligence & Siri** → turn **Apple Intelligence** on (iPhone 15 Pro or newer, iOS 26).
2. Leave the phone on Wi-Fi and charging until the model has downloaded (Settings shows progress).
3. In DayMind → **Settings** (gear icon) the **Apple Intelligence** row should say **Ready**. Tap **Check again** if it does not.

Without Apple Intelligence DayMind says so plainly and uses its offline rules and forms instead.

## Part 7 — Action Button, Siri and Control Center

* **Action Button** (iPhone 15 Pro and newer): iPhone Settings → Action Button → swipe to **Controls** → choose **Talk to DayMind**. Or choose **Shortcut** and pick **Talk to DayMind**.
* **Control Center**: open Control Center, long-press an empty area → **Add a Control** → search **DayMind** → **Talk to DayMind**.
* **Siri**: say "Talk to DayMind", "Add a reminder in DayMind", "Save a memory in DayMind", "DayMind briefing", or "What's next in DayMind".
* **Widget**: long-press the Home Screen → **Edit** → **Add Widget** → **DayMind**.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Signing for DayMind requires a development team" | Part 5, steps 1–4. |
| Red errors mentioning iCloud/aps-environment | Part 5, step 6 (free account). |
| "Could not launch — Developer Mode disabled" | Part 5, step 9. |
| App builds but Xcode says "Untrusted Developer" | Part 5, step 11. |
| Microphone button says permission is off | iPhone Settings → Privacy & Security → Microphone → DayMind on. |
| Apple Intelligence shows "Unavailable" | Part 6; the message in DayMind tells you the exact reason. |
| Build fails after you pulled new code | In Xcode: **Product → Clean Build Folder** (⇧⌘K), then Run again. If `project.yml` changed, run `xcodegen generate`. |
