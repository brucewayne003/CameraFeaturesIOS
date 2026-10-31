# Diamond iOS Sample App
[![Build Status](https://ci.walmart.com/buildStatus/icon?=job/project-diamond/job/diamond-apps/job/diamond-ios-sdk/)](https://ci.walmart.com/job/project-diamond/job/diamond-apps/job/diamond-ios-sdk/)

This is the official iOS app for Project Diamond. This app is built to showcase Diamond's technology such as:
- data collection, inference, out of stock detection, modular scanning, barcode scanning, & more to come.

## Onboarding
Make sure to read over the [iOS Onboarding](https://confluence.walmart.com/pages/viewpage.action?spaceKey=BPD&title=iOS+Onboarding) guide.


## Build using Xcode

### Prerequisites

0.  Make sure you're connected to **Wec Two Factor VPN**, or some other known VPN profile that gives access to sites like Brew.  The 2 factor authentication profile won't work.
1.  Install [homebrew](https://brew.sh/) 
    - This _may_ not automatically setup your terminal shell environment to call `brew` so fix it by running:
        ```bash
        echo '# Set PATH, MANPATH, etc., for Homebrew.' >> /Users/ven/.zprofile
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> /Users/ven/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
        ```
2. Setup your Github Enterprise [SSH key](https://docs.github.com/en/enterprise-server@3.8/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
3. run `make`
    - This project has a [Makefile](https://gecgithub01.walmart.com/Project-Diamond/diamond-ios-sdk/blob/dbeb8fc164ecbe1364eb0637a39a328fb74bea0c/Makefile) which should boostrap your local env
4. run `pod install`

### Secrets

The Secrets (such as the CGS Service account) are injected into the project during CI/CD. In order to keep the them out of source control we are using Environmental Variables and git hooks. 

Overview:
- secrets are stored as environmental variables on your local machine
    - Get the secrets via PassPass from Luis
    - add the service Account email as an envar to your machine `export GCS_SERVICE_EMAIL="somesuch@email.com"`
    - add the private key `export GCS_SERVICE_KEY="Big string of text"`
- code away to your hearts content
- a `pre-push` hook will remove those secrets from the `Info.plist`
- during CI Looper will inject those secrets back into the project

**Note**: You can also populate the info.plist by running `./ci_scripts/add_secrets.sh`

### Running

By default the project builds in debug which uses a dev instance for OAuth.
- you'll need to create a [lab account](https://confluence.walmart.com/pages/viewpage.action?pageId=1499812324#iOSOnboarding-OAuthDevAccess) to login to a OAuth Dev
- Use your normal credentials if using OAuth Prod

Additionally, you'll need to add the necessary [certificates](https://confluence.walmart.com/pages/viewpage.action?pageId=1499812324#iOSOnboarding-iOSSimulator) to the simulator or test device to bypass TLS errors

### Cocoapods

This project uses Cocoapods, specifically a [private podspec](https://gecgithub01.walmart.com/Project-Diamond/cocoapods-specs/tree/main/zxing-cpp) repo, to pull dependencies we're extracting as an SDK

Setting up your local development pods helps you interfance with those SDK dependencies & later push up newer updates

- Update the [Podfile](https://gecgithub01.walmart.com/Project-Diamond/diamond-ios-sdk/blob/dbeb8fc164ecbe1364eb0637a39a328fb74bea0c/Podfile) to use local paths
```ruby
 pod 'Osiris', :path => "../to/sdk/path/Osiris.podspec"
 pod 'OsirisBarcode', :path => "../to/sdk/path/OsirisBarcode.podspec"
 pod 'OsirisCamera', :path => "../to/sdk/path/OsirisCamera.podspec"
 pod 'OsirisDigitalLocks', :path => "../to/sdk/path/OsirisDigitalLocks.podspec"
 #pod 'Osiris', "2026.09.16.3"
 #pod 'OsirisBarcode', "2026.09.16.3"
 #pod 'OsirisCamera', "2026.09.16.3"
 #pod 'OsirisDigitalLocks', "2026.09.16.3"

```
**Note**: make sure to reset these to latest tag of interest

### Try the scanner with Diamond resources

Diamond normally uses `OsirisDefaultResources` for its scanner appearance, fonts, and icons. To try the single-scan screen with resources supplied by Diamond, make the following three edits on a local demo branch. Diamond already includes Bogle fonts, marker images, and `scanbeep.wav`.

**1. Remove the optional pod.** In the [Podfile](Podfile), remove `OsirisDefaultResources` from the list of local pods. The loop should read:

```ruby
%w[Osiris OsirisBarcode OsirisCamera OsirisDigitalLocks].each do |name|
  pod name, :path => osiris_path
end
```

**2. Install Diamond's provider.** In [AppDelegate.swift](Source/System/AppDelegate.swift), replace `import OsirisDefaultResources` with `import Bogle`. Add this type at file scope:

```swift
private struct DiamondResourceProvider: OsirisResourceProvider {
    func color(named name: String) -> UIColor? {
        switch name {
        case "blue100": return .systemBlue
        case "yellow100": return .systemYellow
        default: return UIColor(named: name, in: .main, compatibleWith: nil)
        }
    }

    func image(named name: String) -> UIImage? {
        switch name {
        case "ic_flash": return UIImage(systemName: "flashlight.on.fill")
        case "ic_flash_slash": return UIImage(systemName: "flashlight.off.fill")
        default: return UIImage(named: name, in: .main, compatibleWith: nil)
        }
    }

    func registerFonts() {
        _ = UIFont.registerBogle()
        _ = UIFont.registerBogleMono()
    }

    func font(named name: String, size: CGFloat) -> UIFont? {
        UIFont(name: name, size: size)
    }
}
```

In `application(_:didFinishLaunchingWithOptions:)`, replace the call to `installForLegacyUI()` with:

```swift
let resources = DiamondResourceProvider()
resources.registerFonts()
OsirisUIResourceRegistry.provider = resources
```

**3. Set the scanner colors.** In [BarcodeSingleScanViewModel.swift](Source/UI/BarcodeSingleScan/ViewModel/BarcodeSingleScanViewModel.swift), replace `import OsirisDefaultResources` with `import UIKit`. In `fetchOsirisConfig`, replace the two declarations for `resources` and `boundingBoxConfig` with:

```swift
let scannerAppearance = OsirisScannerAppearance(reticleColor: .systemTeal, detectedReticleColor: .systemPurple)
let boundingBoxConfig: OsirisBoundingBoxConfig = boundingBoxSettings.defaultStyle == .yellow
    ? .init(borderColor: .systemYellow)
    : .init(borderColor: .white, backgroundColor: UIColor.white.withAlphaComponent(0.3), borderCornerRadius: 4)
```

In the `OsirisConfig` initializer, pass `scannerAppearance: scannerAppearance`. Keep the existing feedback configuration so Diamond supplies its own beep.

Run `pod install` from the Diamond repository root and check that `Podfile.lock` has no entry for `OsirisDefaultResources`. Run the Diamond app from `Diamond.xcworkspace` on a device. In Decoder Settings, enable the reticle and turn off multi-scan. On a successful scan, the teal aiming guide should briefly flash purple and Diamond's beep should play. To see a marker image from the app bundle, enable **Marker Style Enabled** and choose **Blue with '+' Icon**.

To return to the standard sample, undo these three demo edits and run `pod install` again.

## Release Instructions

### Standard (Non-ML) Release to TestFlight

1. Bump Osiris pod versions in `Podfile` to the new release (e.g. `2026.09.16.3`)
2. Bump `CURRENT_PROJECT_VERSION` in `Diamond.xcodeproj/project.pbxproj` (all occurrences)
3. Run `pod repo update walmart-project-diamond-cocoapods-specs && pod install`
4. Create a feature branch from `develop`, commit changes, open PR to `develop`
5. Once merged to `develop` → Looper triggers a debug AppCenter build automatically
6. Open PR from `develop` → `main` — once merged → Looper triggers TestFlight build automatically

### ML Release to TestFlight

ML versions consume the `-ml` tagged Osiris pods (e.g. `2026.09.16.3-ml`) which use the ML-enabled zxing-cpp xcframework. These are released via a `release/*` branch without merging to `main`.

1. Confirm the ML pods are published:
   ```bash
   ls ~/.cocoapods/repos/walmart-project-diamond-cocoapods-specs/OsirisBarcode/<version>-ml/
   ```
2. Create a feature branch from `develop`:
   ```bash
   git checkout develop && git pull
   git checkout -b feature/BPD-XXXX-consume-osiris-ml
   ```
3. Update `Podfile` — set all 4 pods to `<version>-ml`
4. Add `release/*` trigger to `.looper.yml` under `branches` (if not already present):
   ```yaml
   - spec: "release/*"
     triggers:
       - push:
           call: buildAndRelease(release)
   ```
5. Bump `CURRENT_PROJECT_VERSION` in `Diamond.xcodeproj/project.pbxproj` (all occurrences)
6. Run `pod repo update walmart-project-diamond-cocoapods-specs` then `pod install`
7. Commit and push, open PR to `main` with `[BPD-XXXX]` prefix in title
8. Once merged to `main` → Looper triggers TestFlight build automatically

> **Note:** Never merge ML release branches from osiris-ios into main — the `-ml` suffix tags are consumed only via CocoaPods. The `release/*` trigger in this repo is for diamond-ios-sdk's own Looper build, not for osiris-ios pod publishing.
