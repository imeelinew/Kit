# Agent rules

- Do not run, launch, restart, or terminate the app unless the user explicitly requests that exact action. The user owns the active Xcode run session.
- Builds are allowed when the user explicitly requests them or when they are solely needed to diagnose and fix compilation errors. Do not invoke `swift build`, project run scripts, or other launch automation unless the user explicitly requests it; use an isolated DerivedData directory for diagnostic `xcodebuild` runs.
- Do not modify Xcode scheme settings on your own (including reverting or regenerating `*.xcscheme`).
- Treat `Kit.xcodeproj` as the source of truth. Do not generate or regenerate the Xcode project; edit only the required project file entries when the user requests a source change.
- Do not add test targets, test files, or test schemes. This project does not use automated tests.
