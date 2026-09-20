# SENSEI V1

A personal, local-first iPhone AI app built with SwiftUI and Apple's Foundation Models framework.

## V1 features

- On-device AI through `SystemLanguageModel`
- No paid model API
- No API key
- Dark/red native interface
- Local conversation history
- Recent conversation context is restored into later answers after relaunch
- Local AI availability indicator
- GitHub Actions workflow for an unsigned IPA

## Requirements

- iPhone/iPad that supports Apple Intelligence
- Apple Intelligence enabled
- iOS 26 or newer
- For local Xcode builds: a compatible Mac + Xcode 26 or newer

## Build with Xcode

1. Install XcodeGen:
   `brew install xcodegen`
2. In this folder run:
   `xcodegen generate`
3. Open `Sensei.xcodeproj`
4. Select your signing team if you want to install directly from Xcode.
5. Select your iPhone and Run.

## Build an unsigned IPA with GitHub Actions

1. Open this repository's **Actions** tab.
2. Run **Build SENSEI unsigned IPA**.
3. Download the `SENSEI-V1-unsigned` artifact when the build finishes.
4. Sign/install the IPA using a signing method you are authorized to use.

## Important

The AI itself does not require a paid API. Apple Intelligence availability is controlled by the device, operating system, region, language, and Apple Intelligence settings.

V1 memory uses locally saved conversation history and supplies a bounded recent window to the on-device model. A separate structured long-term memory system can be added later.
