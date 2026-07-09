# DockMinimize

DockMinimize is an ultra-lightweight, production-grade background utility for macOS that enhances your native Dock by providing fast minimize/restore, and native window matrix previews when clicking on Dock's application icons.

Built using Swift and Apple's modern `ScreenCaptureKit` API, DockMinimize operates completely as a background agent (`LSUIElement`). It leaves no footprint in your Dock or your `Cmd + Tab` app switcher, keeping your workspace completely clean.

---

## Features

* **Minimize / Restore** applications by clicking on Dock's application icons. If an application has more than one window open, it will show a window matrix preview when clicked on in the Dock. If you don't select any window, it will minimize all of them.
* **0.0% Idle CPU:** Contains no background polling loops. It sleeps completely until called upon by system event taps, preserving your MacBook's battery life.
* **Minimal Memory Footprint:** Consumes only ~15MB–25MB of RAM by leveraging highly optimized, downscaled volatile memory caching.
* **Native & Fast:** Optimized directly for Apple Silicon and Intel architectures. 
* **Stealth Architecture:** Runs silently as a background system assistant without cluttered windows or UI overhead.

---

## 📂 Project Structure

```text
DockMinimize/
├── package.sh          # All-in-one automation script (Clean ➔ Compile ➔ Sign ➔ Install)
├── README.md           # This instruction manual
├── .gitignore          # Keeps build outputs out of version control
├── src/
│   └── main.swift      # Thread-safe, event-driven core application Swift source code
└── resources/
    ├── Info.plist      # Application manifest declaring background agent state
    └── AppIcon.icns    # Multi-resolution macOS native app icon asset
```
---

## Requirements to build

```code
xcode-select --install
```

## Build and install

```code
git clone https://github.com/jplassnibatt/DockMinimize.git
cd DockMinimize
./package.sh         # This will install the application in the Applications folder
```

## Required Permissions
`Accessibility` and `ScreenCapture` (for miniatures).

## Start it
Double click on the `DockMinimize.app` in the `Applications` folder. Grant permissions when asked. It will run silently in the background. 

## Launch at Startup
To launch DockMinimize at startup, you can add it to the `System Settings > Login Items > Open at Login` list.

## Kill application
If you need to kill the application, you can run the following command:
```code
killall DockMinimize
```

## Uninstall
```code
rm -rf /Applications/DockMinimize.app
or
Remove it from your Applications folder.
```
---

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

* [Swift](https://swift.org/)
* [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)

