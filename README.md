# fritzing-bin

Build [Fritzing](https://github.com/fritzing/fritzing-app) from its source code with GitHub Actions.
You get a Fritzing build for Windows, macOS or Linux. You do not pay for it.

This project is not part of the Fritzing project. It does not change the Fritzing source code.

> [!NOTE]
> The official builds cost money at [fritzing.org](https://fritzing.org). This money helps the Fritzing team.
> If you use Fritzing frequently, buy the official build.

## Make a build

1. Fork this repository.
2. In your fork, open the **Actions** tab. Enable the workflows.
3. Select the **fritzing** workflow. Then select **Run workflow**.
4. Select the platform.
5. Optional: type a Fritzing version. If you leave this field empty, you get the latest stable version.
6. Select **Run workflow**.
7. Wait for the build to finish. This takes approximately 30 to 60 minutes.
8. Open the run. Download your build from the **Artifacts** section.

To make a newer build, do steps 3 to 8 again.

## Platforms

| Platform | File | Start Fritzing |
|---|---|---|
| Windows (64-bit) | folder | Run `Fritzing.exe`. |
| macOS (Apple Silicon) | `.zip` | Unzip. Right-click `Fritzing.app` and select **Open**. |
| macOS (Intel) | `.zip` | Unzip. Right-click `Fritzing.app` and select **Open**. |
| Linux (x64) | `.tar.gz` | Extract. Run `./Fritzing`. |
| Linux (ARM64) | `.tar.gz` | Extract. Run `./Fritzing`. |

You can also select **All macOS**, **All Linux** or **Everything**.

On macOS, you must use right-click and **Open** the first time. Apple did not check this build.

On Linux, the computer must have glibc 2.35 or newer (Ubuntu 22.04 or newer, for example).

These platforms are not available:

- **32-bit Windows.** Fritzing needs Qt 6. Qt 6 does not support 32-bit Windows.
- **Windows on ARM.** The ngspice simulator library is not available for this platform. Use the Windows (64-bit) build. It runs on ARM computers through emulation.

## Versions

| You type | You get |
|---|---|
| (nothing) | The latest stable version, for example `1.0.7` |
| `1.0.7` | That stable version |
| `develop` | The latest development code. It can be unstable. |
| other | A different branch or tag of fritzing-app |

## Build on your computer

You can also run the scripts on your computer. You must install Qt 6 (6.5.3 to 6.10), CMake, Git and a C++ compiler.

- Windows, in a Visual Studio x64 developer prompt: `pwsh build.ps1`
- Linux: `bash build.sh linux`
- macOS: `bash build.sh macos`

To select a version, add it at the end. For example: `bash build.sh linux 1.0.7`.
The result goes into the `github` folder.

## Licenses

This is not legal advice.

- **Fritzing** source code uses [GPL v3](https://github.com/fritzing/fritzing-app/blob/develop/LICENSE.GPL3). You can build it and use it.
- **Fritzing parts and documentation** use [CC BY-SA 3.0](https://github.com/fritzing/fritzing-app/blob/develop/LICENSE.CC-BY-SA).
- **The scripts in this repository** use the [MIT license](LICENSE).

Each build contains the license files and a `SOURCE.txt` file. `SOURCE.txt` shows where the source code is.

If you share a build with other persons, you must obey the GPL:

- Include the license files.
- Tell them where the source code is.
- If you change the source code, publish your changes.

For these reasons, this repository does not publish builds. Each person makes their own build in their own fork.

If you change Fritzing, do not use the name "Fritzing" for your version.

## Thanks

This project uses the idea of [mmozeiko/aseprite-bin](https://github.com/mmozeiko/aseprite-bin).
