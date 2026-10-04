# OrbitMaze

![Apple Watch](https://img.shields.io/badge/Apple_Watch-watchOS_11%2B-black?logo=apple) ![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift) ![Xcode 16+](https://img.shields.io/badge/Xcode-16%2B-blue) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A tilt maze that lives on your Apple Watch. You roll a ball from the outer ring to the glowing hub by tilting your wrist, and every level deals a fresh random maze. Later levels add rings, longer paths, and more wrong turns. It's watch-only, so your phone stays in your pocket.

## How to play

Tilt your wrist and the ball rolls. Around 15° of tilt is full speed on the middle setting.

Each level opens with a half-second "hold still." Whatever position your wrist is in at that moment counts as flat, so get comfortable *before* the countdown starts. Don't lay the watch on a table to calibrate.

Tapping the screen never pauses. That's deliberate, because taps keep the display awake (more below). To pause, hit the pause button at the top. The menu gives you Resume, Recalibrate, and Quit.

If the ball rolls away from your tilt, flip the invert switch on the home screen.

Finish under par for 3 stars. Par scales with each maze, and the bar gets stricter as you climb. Your best time per level and your highest level stay saved on the watch.

## Run it on your watch

You need a Mac with Xcode 16 or newer and an Apple Watch paired to an iPhone.

```sh
brew install xcodegen
xcodegen
```

That builds the Xcode project from `project.yml`. Then:

1. Open `OrbitMaze.xcodeproj`.
2. Pick the `OrbitMaze` target, open Signing & Capabilities, and choose your team.
3. Bundle ids belong to one account each, so put your own in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`, something like `com.yourname.orbitmaze`) and run `xcodegen` again.
4. Plug in the paired iPhone, pick your watch as the run destination, and hit Run.

A free Apple ID signs the app for 7 days. When it expires, run it from Xcode again.

## One thing about the screen

The watch decides when its screen sleeps and no app can overrule it. Two things matter. Set Wake Duration to 70 seconds (on the watch: Settings › Display & Brightness › Wake Duration). And know that only taps and crown turns reset that timer. Tilting doesn't count.

So the game works around it. About 55 seconds into a level the watch buzzes once. Tap the screen when you feel it. If the screen still sleeps, raise your wrist and hit Resume. The maze, ball, and timer come back exactly where you left them after a short countdown.

Dropping your wrist sleeps the display at once, timer or not.

## What's inside

- `Core/` holds the maze generator, geometry, and ball physics. Plain Swift, no dependencies.
- `App/Logic/` holds the game state machine, tilt mapping, par and stars, plus a solver that measures each maze.
- `App/` holds the SwiftUI views, motion input, haptics, and saves.
- `Tests/` holds standalone test programs that don't need Xcode:

```sh
swiftc -O -parse-as-library Core/Geometry.swift Core/MazeGenerator.swift Tests/MazeTests.swift -o maze_tests && ./maze_tests
swiftc -O -parse-as-library Core/Geometry.swift Core/BallPhysics.swift Tests/PhysicsTests.swift -o physics_tests && ./physics_tests
swiftc -O -parse-as-library Core/Geometry.swift Core/MazeGenerator.swift Core/BallPhysics.swift App/Logic/GameModel.swift App/Logic/MazeSolver.swift Tests/PlaytestTests.swift -o playtest && ./playtest
```

You can also type-check the pure game logic with:

```sh
swiftc -parse-as-library -swift-version 6 -typecheck Core/*.swift App/Logic/*.swift
```

Want an icon? Drop a 1024×1024 PNG into `App/Assets.xcassets/AppIcon.appiconset` and point its `Contents.json` at it.
